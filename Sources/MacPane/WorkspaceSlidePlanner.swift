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

    static func interpolatedFrame(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let progress = easedProgress(progress)
        return sanitizedFrame(CGRect(
            x: start.minX + ((end.minX - start.minX) * progress),
            y: start.minY + ((end.minY - start.minY) * progress),
            width: start.width + ((end.width - start.width) * progress),
            height: start.height + ((end.height - start.height) * progress)
        ))
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
        let progress = min(max(progress, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
}
