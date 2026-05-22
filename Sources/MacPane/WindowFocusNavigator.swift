import CoreGraphics

enum WindowFocusNavigator {
    static func resolvedHotKeyFocusedID(
        in windows: [ManagedWindow],
        preferredFocusedID: WindowIdentity?,
        lastKnownFocusedID: WindowIdentity?,
        preferredActiveStateKey: String?,
        cursorActiveStateKey: String?,
        screenStates: [String: ScreenTileState],
        floatingWindowIDs: Set<WindowIdentity>,
        cursor: CGPoint
    ) -> WindowIdentity? {
        let visibleIDs = Set(windows.map(\.id))
        if let preferredFocusedID, visibleIDs.contains(preferredFocusedID) {
            return preferredFocusedID
        }
        if let lastKnownFocusedID, visibleIDs.contains(lastKnownFocusedID) {
            return lastKnownFocusedID
        }
        if let preferredActiveStateKey,
           let fallbackID = screenStates[preferredActiveStateKey]?.lastFocusedOrLargestID,
           visibleIDs.contains(fallbackID) {
            return fallbackID
        }
        for state in screenStates.values {
            if let fallbackID = state.lastFocusedOrLargestID, visibleIDs.contains(fallbackID) {
                return fallbackID
            }
        }
        if let cursorActiveStateKey,
           let fallback = nearestWindow(
                to: cursor,
                in: windows,
                matchingStateKey: cursorActiveStateKey,
                floatingWindowIDs: floatingWindowIDs
           ) {
            return fallback.id
        }
        return nearestWindow(
            to: cursor,
            in: windows,
            matchingStateKey: nil,
            floatingWindowIDs: floatingWindowIDs
        )?.id
    }

    static func frameBasedNeighborID(
        from focusedID: WindowIdentity,
        direction: SnapDirection,
        windows: [ManagedWindow],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> WindowIdentity? {
        guard let focusedWindow = windows.first(where: { $0.id == focusedID }) else { return nil }
        let sourceFrame = focusedWindow.frame
        let sourcePoint = frameSideCenter(of: sourceFrame, leaving: direction)
        var best: (id: WindowIdentity, score: CGFloat, overlap: CGFloat)?

        for candidate in windows where candidate.id != focusedID {
            guard !floatingWindowIDs.contains(candidate.id),
                  candidate.screen.stateKey == focusedWindow.screen.stateKey,
                  isFrameCandidate(candidate.frame, from: sourceFrame, direction: direction) else {
                continue
            }
            let targetPoint = frameSideCenter(of: candidate.frame, enteringFrom: direction)
            let dx = sourcePoint.x - targetPoint.x
            let dy = sourcePoint.y - targetPoint.y
            let distanceSquared = dx * dx + dy * dy
            let overlap = framePerpendicularOverlap(sourceFrame, candidate.frame, direction: direction)
            let score = distanceSquared - overlap * overlap * 0.25
            if best == nil || score < best!.score - TileLayout.epsilon ||
                (abs(score - best!.score) <= TileLayout.epsilon && overlap > best!.overlap) {
                best = (candidate.id, score, overlap)
            }
        }
        return best?.id
    }

    private static func frameSideCenter(of frame: CGRect, leaving direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.minY)
        case .down: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    private static func frameSideCenter(of frame: CGRect, enteringFrom direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.maxX, y: frame.midY)
        case .right: return CGPoint(x: frame.minX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.maxY)
        case .down: return CGPoint(x: frame.midX, y: frame.minY)
        }
    }

    private static func isFrameCandidate(_ candidate: CGRect, from focused: CGRect, direction: SnapDirection) -> Bool {
        switch direction {
        case .left: return candidate.midX < focused.midX - TileLayout.epsilon
        case .right: return candidate.midX > focused.midX + TileLayout.epsilon
        case .up: return candidate.midY < focused.midY - TileLayout.epsilon
        case .down: return candidate.midY > focused.midY + TileLayout.epsilon
        }
    }

    private static func framePerpendicularOverlap(_ lhs: CGRect, _ rhs: CGRect, direction: SnapDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        case .up, .down:
            return max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        }
    }

    private static func nearestWindow(
        to cursor: CGPoint,
        in windows: [ManagedWindow],
        matchingStateKey stateKey: String?,
        floatingWindowIDs: Set<WindowIdentity>
    ) -> ManagedWindow? {
        windows
            .filter { window in
                !floatingWindowIDs.contains(window.id) &&
                    (stateKey == nil || window.screen.stateKey == stateKey)
            }
            .min { $0.frame.distanceSquared(to: cursor) < $1.frame.distanceSquared(to: cursor) }
    }
}
