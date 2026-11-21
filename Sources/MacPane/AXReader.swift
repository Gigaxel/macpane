import ApplicationServices
import CoreGraphics
import Foundation

/// The result of one Accessibility read, keeping "the app has no such value" apart from "the app
/// did not answer", which must be retried rather than believed.
enum AXRead<T> {
    case value(T)
    case missing
    case failed
}

extension AXRead {
    func map<U>(_ transform: (T) -> U?) -> AXRead<U> {
        switch self {
        case .value(let value):
            return transform(value).map(AXRead<U>.value) ?? .missing
        case .missing:
            return .missing
        case .failed:
            return .failed
        }
    }
}

/// Thin wrappers over the Accessibility C API. Every call here blocks on the target app, so they
/// are only used from that app's `AXApplication` queue.
enum AXReader {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: WindowIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    /// The WindowServer ID behind an Accessibility window element: the one identity a window keeps
    /// for its whole life.
    static func windowID(of element: AXUIElement) -> WindowID? {
        guard let windowIDFunction else { return nil }
        var identifier: CGWindowID = 0
        guard windowIDFunction(element, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    static func string(_ element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else { return nil }
        return rawValue as? String
    }

    static func bool(_ element: AXUIElement, attribute: String) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else { return nil }
        return rawValue as? Bool
    }

    /// Position and size in one round trip.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let reads = multipleChecked(element, attributes: [kAXPositionAttribute, kAXSizeAttribute]),
              case .value(let rawPosition)? = reads[kAXPositionAttribute],
              case .value(let rawSize)? = reads[kAXSizeAttribute],
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    static func isSettable(_ element: AXUIElement, attribute: String) -> AXRead<Bool> {
        var settable = DarwinBoolean(false)
        switch AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) {
        case .success:
            return .value(settable.boolValue)
        case .noValue, .attributeUnsupported:
            return .value(false)
        default:
            return .failed
        }
    }

    static func elementsChecked(_ element: AXUIElement, attribute: String) -> AXRead<[AXUIElement]> {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        switch error {
        case .success:
            guard let rawValue, CFGetTypeID(rawValue) == CFArrayGetTypeID() else { return .missing }
            return .value(rawValue as? [AXUIElement] ?? [])
        case .noValue, .attributeUnsupported:
            return .missing
        default:
            return .failed
        }
    }

    /// Reads several attributes in one round trip. Nil means the app did not answer at all.
    static func multipleChecked(_ element: AXUIElement, attributes: [String]) -> [String: AXRead<CFTypeRef>]? {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &rawValues
        )
        guard error == .success, let values = rawValues as? [CFTypeRef], values.count == attributes.count else {
            return nil
        }
        var results: [String: AXRead<CFTypeRef>] = [:]
        results.reserveCapacity(attributes.count)
        for (index, value) in values.enumerated() {
            results[attributes[index]] = checkedBatchValue(value)
        }
        return results
    }

    static func stringFromBatch(_ read: AXRead<CFTypeRef>?) -> String? {
        guard case .value(let raw)? = read else { return nil }
        return raw as? String
    }

    static func boolReadFromBatch(_ read: AXRead<CFTypeRef>?) -> AXRead<Bool> {
        (read ?? .missing).map { $0 as? Bool }
    }

    static func stringReadFromBatch(_ read: AXRead<CFTypeRef>?) -> AXRead<String> {
        (read ?? .missing).map { $0 as? String }
    }

    private static func checkedBatchValue(_ value: CFTypeRef) -> AXRead<CFTypeRef> {
        if CFGetTypeID(value) == CFNullGetTypeID() {
            return .missing
        }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            if AXValueGetType(axValue) == .axError {
                var axError = AXError.success
                if AXValueGetValue(axValue, .axError, &axError),
                   axError == .noValue || axError == .attributeUnsupported {
                    return .missing
                }
                return .failed
            }
        }
        return .value(value)
    }
}
