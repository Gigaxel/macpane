import ApplicationServices
import CoreGraphics

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
}
