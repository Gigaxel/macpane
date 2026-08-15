import ApplicationServices
import CoreGraphics

enum FrameWriteMode: Equatable {
    case skip
    case positionOnly
    case full
}

enum FrameWritePlanner {
    static func mode(current: CGRect, target: CGRect) -> FrameWriteMode {
        if WindowFrameApplier.approximatelyEqual(current, target) {
            return .skip
        }
        if WindowFrameApplier.approximatelyEqual(current.size, target.size) {
            return .positionOnly
        }
        return .full
    }
}

enum WindowFrameApplier {
    @discardableResult
    static func applyFrame(_ frame: CGRect, to window: AXUIElement) -> AXError {
        var size = frame.size
        var origin = frame.origin
        var worstError = AXError.success
        // Some apps clamp the size again after the position changes.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            record(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue), into: &worstError)
        }
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            record(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue), into: &worstError)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            record(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue), into: &worstError)
        }
        return worstError
    }

    @discardableResult
    static func applyPosition(_ origin: CGPoint, to window: AXUIElement) -> AXError {
        var origin = CGPoint(
            x: origin.x.rounded(.toNearestOrAwayFromZero),
            y: origin.y.rounded(.toNearestOrAwayFromZero)
        )
        guard let positionValue = AXValueCreate(.cgPoint, &origin) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
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

    private static func record(_ error: AXError, into worstError: inout AXError) {
        if worstError == .success, error != .success {
            worstError = error
        }
    }
}

final class EnhancedUserInterfaceSuspension {
    private static let attribute = "AXEnhancedUserInterface"
    private let appElement: AXUIElement
    private let wasEnabled: Bool

    init(pid: pid_t, messagingTimeout: Float) {
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        wasEnabled = AXReader.bool(appElement, attribute: Self.attribute) == true
        if wasEnabled {
            AXUIElementSetAttributeValue(appElement, Self.attribute as CFString, kCFBooleanFalse)
        }
    }

    func restore() {
        guard wasEnabled else { return }
        AXUIElementSetAttributeValue(appElement, Self.attribute as CFString, kCFBooleanTrue)
    }
}
