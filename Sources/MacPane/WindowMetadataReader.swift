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

    func descriptors(
        pid: pid_t,
        bundleIdentifier rawBundleIdentifier: String?,
        axIdentifier rawAXIdentifier: String?,
        document rawDocument: String?,
        title rawTitle: String?,
        stateKey: String
    ) -> (signature: WindowSignature?, layoutIdentity: WindowLayoutIdentity?) {
        let bundleIdentifier = normalizedWindowString(rawBundleIdentifier)
        let axIdentifier = normalizedWindowString(rawAXIdentifier)
        let document = normalizedWindowString(rawDocument)
        let normalizedTitle = normalizedWindowString(rawTitle)
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

    func normalizedWindowString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
