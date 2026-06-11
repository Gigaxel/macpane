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

    func descriptors(
        for window: AXUIElement,
        app: NSRunningApplication,
        title: String?,
        stateKey: String
    ) -> (signature: WindowSignature?, layoutIdentity: WindowLayoutIdentity?) {
        let pid = app.processIdentifier
        let bundleIdentifier = normalizedWindowString(app.bundleIdentifier)
        let axIdentifier = normalizedWindowString(AXReader.string(window, attribute: "AXIdentifier"))
        let document = normalizedWindowString(AXReader.string(window, attribute: kAXDocumentAttribute))
        let normalizedTitle = normalizedWindowString(title)
        let signature = WindowSignature(
            pid: pid,
            stateKey: stateKey,
            bundleIdentifier: bundleIdentifier,
            axIdentifier: axIdentifier,
            document: document,
            title: normalizedTitle
        )
        let layoutIdentity = WindowLayoutIdentity(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            axIdentifier: axIdentifier,
            document: document,
            title: normalizedTitle
        )
        return (
            signature.hasStableComponent ? signature : nil,
            layoutIdentity.hasStableComponent ? layoutIdentity : nil
        )
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
