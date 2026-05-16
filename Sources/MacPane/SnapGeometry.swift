import CoreGraphics
enum SnapDirection: CaseIterable, Equatable {
    case left
    case right
    case up
    case down
    var opposite: SnapDirection {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}
enum HorizontalSnap {
    case full
    case left
    case right
}
enum VerticalSnap {
    case full
    case top
    case bottom
}
struct SnapGeometry {
    private static let partialRatio: CGFloat = 0.65
    static func targetRect(for direction: SnapDirection, current: CGRect, screen: CGRect) -> CGRect {
        var horizontal = classifyHorizontal(current: current, screen: screen)
        var vertical = classifyVertical(current: current, screen: screen)
        switch direction {
        case .left:
            horizontal = .left
        case .right:
            horizontal = .right
        case .up:
            vertical = .top
        case .down:
            vertical = .bottom
        }
        let width: CGFloat
        let x: CGFloat
        switch horizontal {
        case .full:
            x = screen.minX
            width = screen.width
        case .left:
            x = screen.minX
            width = screen.width / 2
        case .right:
            x = screen.midX
            width = screen.width / 2
        }
        let height: CGFloat
        let y: CGFloat
        switch vertical {
        case .full:
            y = screen.minY
            height = screen.height
        case .top:
            y = screen.minY
            height = screen.height / 2
        case .bottom:
            y = screen.midY
            height = screen.height / 2
        }
        return CGRect(
            x: x.rounded(.toNearestOrAwayFromZero),
            y: y.rounded(.toNearestOrAwayFromZero),
            width: width.rounded(.toNearestOrAwayFromZero),
            height: height.rounded(.toNearestOrAwayFromZero)
        )
    }
    private static func classifyHorizontal(current: CGRect, screen: CGRect) -> HorizontalSnap {
        guard current.width <= screen.width * partialRatio else {
            return .full
        }
        return current.midX < screen.midX ? .left : .right
    }
    private static func classifyVertical(current: CGRect, screen: CGRect) -> VerticalSnap {
        guard current.height <= screen.height * partialRatio else {
            return .full
        }
        return current.midY < screen.midY ? .top : .bottom
    }
}
enum ScreenGeometry {
    static func bestScreenIndex(for frame: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() where screen.width > 0 && screen.height > 0 {
            let intersection = frame.intersection(screen)
            let area = intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
            guard area > TileLayout.epsilon else { continue }
            if best == nil || area > best!.area + TileLayout.epsilon {
                best = (index, area)
            }
        }
        return best?.index
    }
}
