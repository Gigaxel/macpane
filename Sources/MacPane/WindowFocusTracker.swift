import AppKit
import ApplicationServices

final class WindowFocusTracker {
    private let appBundleIdentifier: String
    private let messagingTimeout: Float
    private let ioScheduler: AXIOScheduler?
    private(set) var lastKnownWindowID: WindowIdentity?
    var fastFocusEnabled: () -> Bool = { false }

    init(
        appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.gigaxel.macpane",
        messagingTimeout: Float = 0.15,
        ioScheduler: AXIOScheduler? = nil
    ) {
        self.appBundleIdentifier = appBundleIdentifier
        self.messagingTimeout = messagingTimeout
        self.ioScheduler = ioScheduler
    }

    func reset() {
        lastKnownWindowID = nil
    }

    func remember(_ id: WindowIdentity) {
        lastKnownWindowID = id
    }

    func focusedWindowIDForHotKey(in windows: [ManagedWindow]) -> WindowIdentity? {
        if let lastKnownWindowID,
           windows.contains(where: { $0.id == lastKnownWindowID }) {
            return lastKnownWindowID
        }
        let focusedID = focusedWindowID(in: windows)
        if let focusedID {
            lastKnownWindowID = focusedID
        }
        return focusedID
    }

    func focusedWindowID(in windows: [ManagedWindow]) -> WindowIdentity? {
        guard let focusedWindow = focusedWindow() else { return nil }
        if let exactMatch = windows.first(where: { CFEqual($0.element, focusedWindow) }) {
            lastKnownWindowID = exactMatch.id
            return exactMatch.id
        }

        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &focusedPID) == .success else { return nil }
        if let number = AXReader.windowNumber(of: focusedWindow) {
            let focusedID = windows.first { $0.id.pid == focusedPID && $0.windowNumber == number }?.id
            if let focusedID { lastKnownWindowID = focusedID }
            return focusedID
        }

        let focusedID = windows.first { candidate in
            candidate.id.pid == focusedPID && windowsRepresentSameWindow(candidate.element, focusedWindow)
        }?.id
        if let focusedID { lastKnownWindowID = focusedID }
        return focusedID
    }

    func window(matching element: AXUIElement, in windows: [ManagedWindow]) -> ManagedWindow? {
        if let exact = windows.first(where: { CFEqual($0.element, element) }) {
            return exact
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        if let number = AXReader.windowNumber(of: element) {
            return windows.first { $0.id.pid == pid && $0.windowNumber == number }
        }
        return windows.first { candidate in
            candidate.id.pid == pid && windowsRepresentSameWindow(candidate.element, element)
        }
    }

    func focus(_ window: ManagedWindow) {
        lastKnownWindowID = window.id
        let pid = window.id.pid
        let element = window.element
        let timeout = messagingTimeout
        let useFastPath = fastFocusEnabled() && PrivateWindowServer.shared.isAvailable
        let windowNumber = window.windowNumber
        let needsActivation = NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
        let activate: () -> Void = {
            guard needsActivation, let app = NSRunningApplication(processIdentifier: pid) else { return }
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let work: () -> Void = {
            if useFastPath, let windowNumber, PrivateWindowServer.shared.focusWindow(pid: pid, windowNumber: windowNumber) {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                PerformanceTrace.event("focus-fast", "pid \(pid) window \(windowNumber)")
                return
            }
            DispatchQueue.main.async(execute: activate)
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, timeout)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if let ioScheduler {
            ioScheduler.async(pid: pid, work)
        } else {
            work()
        }
    }

    private func focusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = AXReader.element(systemWide, attribute: kAXFocusedWindowAttribute) {
            return focused
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != appBundleIdentifier else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        return AXReader.element(axApp, attribute: kAXFocusedWindowAttribute)
    }

    private func windowsRepresentSameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        let lhsWindowNumber = AXReader.windowNumber(of: lhs)
        let rhsWindowNumber = AXReader.windowNumber(of: rhs)
        if let lhsWindowNumber, let rhsWindowNumber {
            return lhsWindowNumber == rhsWindowNumber
        }

        let lhsIdentifier = AXReader.string(lhs, attribute: "AXIdentifier")
        let rhsIdentifier = AXReader.string(rhs, attribute: "AXIdentifier")
        if let lhsIdentifier, !lhsIdentifier.isEmpty, let rhsIdentifier, !rhsIdentifier.isEmpty {
            return lhsIdentifier == rhsIdentifier
        }

        guard AXReader.string(lhs, attribute: kAXTitleAttribute) == AXReader.string(rhs, attribute: kAXTitleAttribute),
              let lhsPosition = AXReader.point(lhs, attribute: kAXPositionAttribute),
              let rhsPosition = AXReader.point(rhs, attribute: kAXPositionAttribute),
              let lhsSize = AXReader.size(lhs, attribute: kAXSizeAttribute),
              let rhsSize = AXReader.size(rhs, attribute: kAXSizeAttribute) else {
            return false
        }
        return WindowFrameApplier.approximatelyEqual(lhsPosition, rhsPosition) &&
            WindowFrameApplier.approximatelyEqual(lhsSize, rhsSize)
    }
}
