import CoreGraphics

/// Picks focus targets from on-screen geometry, for the cases the tile tree cannot answer: floating
/// windows and moving between displays.
enum WindowFocusNavigator {
    /// The window whose frame is the best step from `source` in `direction`.
    static func neighbor(
        of source: CGRect,
        direction: SnapDirection,
        among candidates: [(id: WindowID, frame: CGRect)]
    ) -> WindowID? {
        let eligible = candidates.filter { isCandidate($0.frame, from: source, direction: direction) }
        return bestIndex(from: source, direction: direction, frames: eligible.map(\.frame)).map { eligible[$0].id }
    }

    /// The display reached by leaving `source` in `direction`.
    static func adjacentScreen(
        to source: ScreenInfo,
        direction: SnapDirection,
        screens: [ScreenInfo]
    ) -> ScreenInfo? {
        let eligible = screens.filter { screen in
            screen.key != source.key && isCandidate(screen.bounds, from: source.bounds, direction: direction)
        }
        return bestIndex(from: source.bounds, direction: direction, frames: eligible.map(\.bounds)).map { eligible[$0] }
    }

    /// The window to land on when entering a display from `source`: the nearest one across the
    /// shared edge.
    static func entryWindow(
        from source: CGRect,
        direction: SnapDirection,
        among candidates: [(id: WindowID, frame: CGRect)]
    ) -> WindowID? {
        bestIndex(from: source, direction: direction, frames: candidates.map(\.frame)).map { candidates[$0].id }
    }

    private static func bestIndex(from source: CGRect, direction: SnapDirection, frames: [CGRect]) -> Int? {
        let sourcePoint = sideCenter(of: source, leaving: direction)
        var best: (index: Int, score: CGFloat, overlap: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let targetPoint = sideCenter(of: frame, enteringFrom: direction)
            let dx = sourcePoint.x - targetPoint.x
            let dy = sourcePoint.y - targetPoint.y
            let overlap = perpendicularOverlap(source, frame, direction: direction)
            let score = dx * dx + dy * dy - overlap * overlap * 0.25
            if best == nil || score < best!.score - TileLayout.epsilon ||
                (abs(score - best!.score) <= TileLayout.epsilon && overlap > best!.overlap) {
                best = (index, score, overlap)
            }
        }
        return best?.index
    }

    private static func sideCenter(of frame: CGRect, leaving direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.minY)
        case .down: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    private static func sideCenter(of frame: CGRect, enteringFrom direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.maxX, y: frame.midY)
        case .right: return CGPoint(x: frame.minX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.maxY)
        case .down: return CGPoint(x: frame.midX, y: frame.minY)
        }
    }

    private static func isCandidate(_ candidate: CGRect, from focused: CGRect, direction: SnapDirection) -> Bool {
        switch direction {
        case .left: return candidate.midX < focused.midX - TileLayout.epsilon
        case .right: return candidate.midX > focused.midX + TileLayout.epsilon
        case .up: return candidate.midY < focused.midY - TileLayout.epsilon
        case .down: return candidate.midY > focused.midY + TileLayout.epsilon
        }
    }

    private static func perpendicularOverlap(_ lhs: CGRect, _ rhs: CGRect, direction: SnapDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        case .up, .down:
            return max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        }
    }
}
