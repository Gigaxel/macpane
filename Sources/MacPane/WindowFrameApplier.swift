import ApplicationServices
import CoreGraphics

enum WindowFrameApplier {
    static func applyFrame(_ frame: CGRect, to window: AXUIElement) {
        var size = frame.size
        var origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)
        let positionValue = AXValueCreate(.cgPoint, &origin)
        if let sizeValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let positionValue {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    static func applyPosition(_ origin: CGPoint, to window: AXUIElement) {
        var origin = CGPoint(
            x: origin.x.rounded(.toNearestOrAwayFromZero),
            y: origin.y.rounded(.toNearestOrAwayFromZero)
        )
        guard let positionValue = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    static func sanitizedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approximatelyEqual(lhs.origin, rhs.origin) && approximatelyEqual(lhs.size, rhs.size)
    }

    static func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    static func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }
}
