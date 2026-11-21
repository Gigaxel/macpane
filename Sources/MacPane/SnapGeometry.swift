import CoreGraphics
enum SnapDirection: CaseIterable, Equatable {
    case left
    case right
    case up
    case down
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
