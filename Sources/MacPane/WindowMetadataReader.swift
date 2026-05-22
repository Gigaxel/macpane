import AppKit
import ApplicationServices
import CoreGraphics

struct WindowMetadataReader {
    private let appBundleIdentifier: String

    init(appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.gigaxel.macpane") {
        self.appBundleIdentifier = appBundleIdentifier
    }

    func isObservableApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              app.bundleIdentifier != appBundleIdentifier else {
            return false
        }
        return true
    }

    func isManageableApp(_ app: NSRunningApplication) -> Bool {
        isObservableApp(app) && !app.isHidden
    }

    func isManageableWindow(
        _ window: AXUIElement,
        app _: NSRunningApplication,
        frame _: CGRect,
        title: String?
    ) -> Bool {
        guard AXReader.string(window, attribute: kAXRoleAttribute) == kAXWindowRole else { return false }
        let subrole = AXReader.string(window, attribute: kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }
        if AXReader.bool(window, attribute: kAXMinimizedAttribute) == true ||
            AXReader.bool(window, attribute: "AXFullScreen") == true ||
            AXReader.bool(window, attribute: "AXModal") == true {
            return false
        }
        let windowTitle = title ?? ""
        if windowTitle.localizedCaseInsensitiveContains("Picture in Picture") ||
            windowTitle.localizedCaseInsensitiveContains("Touch Bar") {
            return false
        }
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        guard positionError == .success, sizeError == .success,
              positionSettable.boolValue, sizeSettable.boolValue else {
            return false
        }
        return true
    }

    func signature(for window: AXUIElement, app: NSRunningApplication, title: String?, stateKey: String) -> WindowSignature? {
        let signature = WindowSignature(
            pid: app.processIdentifier,
            stateKey: stateKey,
            bundleIdentifier: normalizedWindowString(app.bundleIdentifier),
            axIdentifier: normalizedWindowString(AXReader.string(window, attribute: "AXIdentifier")),
            document: normalizedWindowString(AXReader.string(window, attribute: kAXDocumentAttribute)),
            title: normalizedWindowString(title)
        )
        return signature.hasStableComponent ? signature : nil
    }

    func layoutIdentity(for window: AXUIElement, app: NSRunningApplication, title: String?) -> WindowLayoutIdentity? {
        let identity = WindowLayoutIdentity(
            pid: app.processIdentifier,
            bundleIdentifier: normalizedWindowString(app.bundleIdentifier),
            axIdentifier: normalizedWindowString(AXReader.string(window, attribute: "AXIdentifier")),
            document: normalizedWindowString(AXReader.string(window, attribute: kAXDocumentAttribute)),
            title: normalizedWindowString(title)
        )
        return identity.hasStableComponent ? identity : nil
    }

    func notificationToken(for window: AXUIElement, fallbackIndex: Int) -> String {
        if let number = AXReader.int(window, attribute: "AXWindowNumber") ?? AXReader.int(window, attribute: "_AXWindowNumber") {
            return "number:\(number)"
        }
        if let identifier = AXReader.string(window, attribute: "AXIdentifier"), !identifier.isEmpty {
            return "identifier:\(identifier)"
        }
        let title = AXReader.string(window, attribute: kAXTitleAttribute) ?? ""
        let hash = CFHash(window)
        return "fallback:\(hash):\(title):\(fallbackIndex)"
    }

    func normalizedWindowString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
