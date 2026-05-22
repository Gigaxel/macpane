import AppKit
import CoreGraphics

enum WorkspaceSlidePlanner {
    static let defaultFrameRate = 60
    static let maximumTransitionCount = 8

    static func direction(from visibleIndex: Int, to targetIndex: Int, hint: Int?) -> WorkspaceSlideDirection {
        if let hint, hint != 0 {
            return hint > 0 ? .forward : .backward
        }
        return targetIndex > visibleIndex ? .forward : .backward
    }

    static func frameRate(for screen: ScreenInfo) -> Int {
        max(
            nsScreen(for: screen)?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? defaultFrameRate,
            defaultFrameRate
        )
    }

    static func nsScreen(for screen: ScreenInfo) -> NSScreen? {
        if let displayID = screen.displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return matchingScreen
        }
        return NSScreen.screens.first { ScreenInfo.displayKey(for: $0.displayID, frame: $0.frame) == screen.key }
    }

    static func transitions(
        allWindows: [ManagedWindow],
        screen: ScreenInfo,
        visibleState: ScreenTileState?,
        targetState: ScreenTileState?,
        direction: WorkspaceSlideDirection,
        floatingWindowIDs: Set<WindowIdentity>,
        screens: [ScreenInfo],
        gapPixels: CGFloat
    ) -> [WorkspaceSlideTransition] {
        let windowsByID = Dictionary(allWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var transitions: [WorkspaceSlideTransition] = []

        if let visibleState, !visibleState.isEmpty {
            guard visibleState.windowIDs.allSatisfy({ windowsByID[$0] != nil || floatingWindowIDs.contains($0) }) else {
                return []
            }
            for id in visibleState.windowIDs {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let startFrame = sanitizedFrame(window.frame)
                let endFrame = hiddenFrame(
                    matching: startFrame,
                    on: screen,
                    edge: direction == .forward ? .left : .right
                )
                guard hiddenFrameDoesNotCoverAnotherScreen(endFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: false
                ))
            }
        }

        if let targetState, !targetState.isEmpty {
            guard targetState.windowIDs.allSatisfy({ windowsByID[$0] != nil || floatingWindowIDs.contains($0) }) else {
                return []
            }
            for (id, slot) in targetState.slotList {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let endFrame = sanitizedFrame(slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true))
                let startFrame = hiddenFrame(
                    matching: endFrame,
                    on: screen,
                    edge: direction == .forward ? .right : .left
                )
                guard hiddenFrameDoesNotCoverAnotherScreen(startFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: true
                ))
            }
        }

        return transitions
    }

    static func interpolatedOrigin(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGPoint {
        let eased = easedProgress(progress)
        return CGPoint(
            x: (start.minX + ((end.minX - start.minX) * eased)).rounded(.toNearestOrAwayFromZero),
            y: (start.minY + ((end.minY - start.minY) * eased)).rounded(.toNearestOrAwayFromZero)
        )
    }

    static func interpolatedFrame(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let origin = interpolatedOrigin(from: start, to: end, progress: progress)
        return CGRect(origin: origin, size: end.size)
    }

    /// Builds a continuation transition set after the user chains another switch mid-slide.
    /// Each window currently mid-slide gets a new transition whose `startFrame` matches the
    /// frame it is occupying right now (so motion stays continuous), and whose `endFrame`
    /// is either the new target slot position (if the window belongs there) or a hidden
    /// off-screen position on the outgoing edge of the new direction.
    static func chainedTransitions(
        previousTransitions: [WorkspaceSlideTransition],
        currentOriginsByID: [WindowIdentity: CGPoint],
        allWindows: [ManagedWindow],
        screen: ScreenInfo,
        newTargetState: ScreenTileState?,
        direction: WorkspaceSlideDirection,
        floatingWindowIDs: Set<WindowIdentity>,
        screens: [ScreenInfo],
        gapPixels: CGFloat
    ) -> [WorkspaceSlideTransition] {
        let windowsByID = Dictionary(allWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let outgoingEdge: WorkspaceSlideEdge = direction == .forward ? .left : .right
        let incomingEdge: WorkspaceSlideEdge = direction == .forward ? .right : .left
        let newTargetSlotsByID: [WindowIdentity: TileSlot] = {
            guard let newTargetState else { return [:] }
            return Dictionary(uniqueKeysWithValues: newTargetState.slotList.map { ($0.id, $0.slot) })
        }()
        if let newTargetState {
            guard newTargetState.windowIDs.allSatisfy({ windowsByID[$0] != nil || floatingWindowIDs.contains($0) }) else {
                return []
            }
        }

        var transitions: [WorkspaceSlideTransition] = []
        var seenIDs = Set<WindowIdentity>()

        // 1. Each window already participating in the previous slide gets a fresh
        //    transition starting at its live on-screen position. If the new target keeps
        //    the window visible, we route it back to the target tile; otherwise we send
        //    it off the outgoing edge of the new direction.
        for previousTransition in previousTransitions {
            let id = previousTransition.window.id
            guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
            let baseSize = previousTransition.endFrame.size
            let currentOrigin = currentOriginsByID[id] ?? previousTransition.endFrame.origin
            let startFrame = sanitizedFrame(CGRect(origin: currentOrigin, size: baseSize))
            // Reference for hidden-frame y: any frame from the previous transition has the
            // correct on-screen y (slides only move along x).
            let yReference = previousTransition.endFrame
            if let slot = newTargetSlotsByID[id] {
                let endFrame = sanitizedFrame(slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true))
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: false
                ))
            } else {
                let endFrame = hiddenFrame(matching: yReference, on: screen, edge: outgoingEdge)
                // Skip windows whose live frame already sits entirely off the source
                // screen. Direction reversals can leave old non-target windows hidden
                // on the opposite side from the new outgoing edge.
                if isFrameOffScreen(startFrame, on: screen) {
                    seenIDs.insert(id)
                    continue
                }
                guard hiddenFrameDoesNotCoverAnotherScreen(endFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: false
                ))
            }
            seenIDs.insert(id)
        }

        // 2. Windows joining from the new target workspace that weren't in the prior
        //    slide — slide them in from the incoming edge of the new direction.
        if let newTargetState {
            for (id, slot) in newTargetState.slotList {
                guard !seenIDs.contains(id) else { continue }
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let endFrame = sanitizedFrame(slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true))
                let startFrame = hiddenFrame(matching: endFrame, on: screen, edge: incomingEdge)
                guard hiddenFrameDoesNotCoverAnotherScreen(startFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: true
                ))
                seenIDs.insert(id)
            }
        }

        return transitions
    }

    static func sanitizedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }

    private static func hiddenFrame(
        matching frame: CGRect,
        on screen: ScreenInfo,
        edge: WorkspaceSlideEdge
    ) -> CGRect {
        let x: CGFloat
        switch edge {
        case .left:
            x = screen.frame.minX - frame.width + 1
        case .right:
            x = screen.frame.maxX - 1
        }
        return sanitizedFrame(CGRect(
            x: x,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        ))
    }

    private static func isFrameOffScreen(_ frame: CGRect, on screen: ScreenInfo, edge: WorkspaceSlideEdge) -> Bool {
        switch edge {
        case .left:
            return frame.maxX <= screen.frame.minX + 1
        case .right:
            return frame.minX >= screen.frame.maxX - 1
        }
    }

    private static func isFrameOffScreen(_ frame: CGRect, on screen: ScreenInfo) -> Bool {
        isFrameOffScreen(frame, on: screen, edge: .left)
            || isFrameOffScreen(frame, on: screen, edge: .right)
    }

    private static func hiddenFrameDoesNotCoverAnotherScreen(
        _ frame: CGRect,
        source: ScreenInfo,
        screens: [ScreenInfo]
    ) -> Bool {
        !screens.contains { screen in
            screen.key != source.key && screen.frame.intersects(frame)
        }
    }

    private static func easedProgress(_ progress: CGFloat) -> CGFloat {
        // easeOutCubic: starts at velocity 3, decelerates to 0. The nonzero starting
        // velocity is critical for chained slide reseats — smoothstep would momentarily
        // stop the windows at every reseat, producing visible micro-stutter when the
        // user hammers cmd+option+ctrl+h/l.
        let progress = min(max(progress, 0), 1)
        let inverse = 1 - progress
        return 1 - inverse * inverse * inverse
    }
}
