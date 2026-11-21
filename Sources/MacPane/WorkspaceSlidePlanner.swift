import CoreGraphics

/// One window's path during a workspace slide.
struct WorkspaceSlideTransition: Equatable {
    let window: WindowID
    let startFrame: CGRect
    let endFrame: CGRect
    /// True for a window coming in from a hidden workspace: it has to be sized and placed at the
    /// edge before it starts moving.
    let needsInitialFrame: Bool
}

/// Plans the horizontal slide between two virtual workspaces. Windows only ever move along x.
enum WorkspaceSlidePlanner {
    static let maximumTransitionCount = 8

    static func direction(from visibleIndex: Int, to targetIndex: Int, hint: Int?) -> WorkspaceSlideDirection {
        if let hint, hint != 0 {
            return hint > 0 ? .forward : .backward
        }
        return targetIndex > visibleIndex ? .forward : .backward
    }

    /// `outgoing` are the windows showing now, with their current frames; `incoming` are the target
    /// workspace's windows with the tiles they will end in. An empty result means the slide cannot
    /// be shown without a window crossing another display.
    static func transitions(
        outgoing: [(id: WindowID, frame: CGRect)],
        incoming: [(id: WindowID, frame: CGRect)],
        screen: ScreenInfo,
        direction: WorkspaceSlideDirection,
        screens: [ScreenInfo]
    ) -> [WorkspaceSlideTransition] {
        let outgoingEdge: WorkspaceSlideEdge = direction == .forward ? .left : .right
        let incomingEdge: WorkspaceSlideEdge = direction == .forward ? .right : .left
        var transitions: [WorkspaceSlideTransition] = []
        for (id, frame) in outgoing {
            let startFrame = FramePlanner.sanitized(frame)
            let endFrame = hiddenFrame(matching: startFrame, on: screen, edge: outgoingEdge)
            guard staysOffOtherScreens(endFrame, source: screen, screens: screens) else { return [] }
            transitions.append(WorkspaceSlideTransition(
                window: id, startFrame: startFrame, endFrame: endFrame, needsInitialFrame: false
            ))
        }
        for (id, frame) in incoming {
            let endFrame = FramePlanner.sanitized(frame)
            let startFrame = hiddenFrame(matching: endFrame, on: screen, edge: incomingEdge)
            guard staysOffOtherScreens(startFrame, source: screen, screens: screens) else { return [] }
            transitions.append(WorkspaceSlideTransition(
                window: id, startFrame: startFrame, endFrame: endFrame, needsInitialFrame: true
            ))
        }
        return transitions
    }

    /// Continues a slide when another switch arrives before it finishes. Every window already
    /// moving starts from where it is right now, so the motion never stops and restarts.
    static func chainedTransitions(
        previous: [WorkspaceSlideTransition],
        currentOrigins: [WindowID: CGPoint],
        incoming: [(id: WindowID, frame: CGRect)],
        screen: ScreenInfo,
        direction: WorkspaceSlideDirection,
        screens: [ScreenInfo]
    ) -> [WorkspaceSlideTransition] {
        let outgoingEdge: WorkspaceSlideEdge = direction == .forward ? .left : .right
        let incomingEdge: WorkspaceSlideEdge = direction == .forward ? .right : .left
        let incomingFrames = Dictionary(incoming.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var transitions: [WorkspaceSlideTransition] = []
        var seen = Set<WindowID>()

        for transition in previous {
            let id = transition.window
            seen.insert(id)
            let origin = currentOrigins[id] ?? transition.endFrame.origin
            let startFrame = FramePlanner.sanitized(CGRect(origin: origin, size: transition.endFrame.size))
            if let target = incomingFrames[id] {
                transitions.append(WorkspaceSlideTransition(
                    window: id,
                    startFrame: startFrame,
                    endFrame: FramePlanner.sanitized(target),
                    needsInitialFrame: false
                ))
                continue
            }
            // A reversal can leave a window already hidden on the far side; it has nowhere to go.
            guard !isOffScreen(startFrame, on: screen) else { continue }
            let endFrame = hiddenFrame(matching: transition.endFrame, on: screen, edge: outgoingEdge)
            guard staysOffOtherScreens(endFrame, source: screen, screens: screens) else { return [] }
            transitions.append(WorkspaceSlideTransition(
                window: id, startFrame: startFrame, endFrame: endFrame, needsInitialFrame: false
            ))
        }
        for (id, frame) in incoming where !seen.contains(id) {
            let endFrame = FramePlanner.sanitized(frame)
            let startFrame = hiddenFrame(matching: endFrame, on: screen, edge: incomingEdge)
            guard staysOffOtherScreens(startFrame, source: screen, screens: screens) else { return [] }
            transitions.append(WorkspaceSlideTransition(
                window: id, startFrame: startFrame, endFrame: endFrame, needsInitialFrame: true
            ))
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

    private static func hiddenFrame(matching frame: CGRect, on screen: ScreenInfo, edge: WorkspaceSlideEdge) -> CGRect {
        let x: CGFloat
        switch edge {
        case .left:
            x = screen.frame.minX - frame.width + 1
        case .right:
            x = screen.frame.maxX - 1
        }
        return FramePlanner.sanitized(CGRect(x: x, y: frame.minY, width: frame.width, height: frame.height))
    }

    private static func isOffScreen(_ frame: CGRect, on screen: ScreenInfo) -> Bool {
        frame.maxX <= screen.frame.minX + 1 || frame.minX >= screen.frame.maxX - 1
    }

    private static func staysOffOtherScreens(_ frame: CGRect, source: ScreenInfo, screens: [ScreenInfo]) -> Bool {
        !screens.contains { $0.key != source.key && $0.frame.intersects(frame) }
    }

    /// easeOutCubic starts at full speed. A curve that starts from rest would stall the windows on
    /// every chained switch.
    private static func easedProgress(_ progress: CGFloat) -> CGFloat {
        let inverse = 1 - min(max(progress, 0), 1)
        return 1 - inverse * inverse * inverse
    }
}
