import ApplicationServices
import CoreGraphics

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

enum AXReader {
    static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == CFArrayGetTypeID() else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    static func point(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = value(element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = value(element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func value(_ element: AXUIElement, attribute: String) -> AXValue? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        return (rawValue as! AXValue)
    }

    static func string(_ element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return nil }
        return rawValue as? String
    }

    static func bool(_ element: AXUIElement, attribute: String) -> Bool? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return nil }
        return rawValue as? Bool
    }

    static func int(_ element: AXUIElement, attribute: String) -> Int? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success else { return nil }
        if let intValue = rawValue as? Int { return intValue }
        return (rawValue as? NSNumber)?.intValue
    }

    // MARK: - Checked reads

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

    static func pointFromBatch(_ read: AXRead<CFTypeRef>?) -> CGPoint? {
        guard case .value(let raw)? = read, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func sizeFromBatch(_ read: AXRead<CFTypeRef>?) -> CGSize? {
        guard case .value(let raw)? = read, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    static func stringFromBatch(_ read: AXRead<CFTypeRef>?) -> String? {
        guard case .value(let raw)? = read else { return nil }
        return raw as? String
    }

    static func intFromBatch(_ read: AXRead<CFTypeRef>?) -> Int? {
        guard case .value(let raw)? = read else { return nil }
        if let intValue = raw as? Int { return intValue }
        return (raw as? NSNumber)?.intValue
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
