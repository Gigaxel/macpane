import ApplicationServices
import CoreGraphics
import Foundation

/// One window as its owning app exposes it. Every method blocks until the app answers, so they are
/// only called from that app's `AXApplication` queue.
protocol WindowHandle: AnyObject {
    func setSize(_ size: CGSize) -> AXError
    func setPosition(_ origin: CGPoint) -> AXError
    /// The frame as the app reports it. Only used when the WindowServer cannot be asked.
    func frame() -> CGRect?
    func title() -> String?
    func raise()
}

enum WindowResolution {
    case manageable(handle: WindowHandle, title: String?)
    /// A panel, sheet, dialog or other window that is never tiled.
    case excluded
    /// The app does not list the window yet, or did not answer.
    case unavailable
}

enum ApplicationNotification {
    /// Something about the app's windows changed.
    case windowsChanged
    /// A watched window is closing. This arrives when the close starts, well before the window has
    /// finished fading out.
    case windowClosing(WindowID)
    /// The app has a new focused window. `window` asks the app which one, so it must be called on
    /// the app's queue.
    case focusChanged(window: () -> WindowID?)
}

/// The connection to one app's windows. The app uses Accessibility; the integration tests drive
/// their own windows through the same interface.
protocol ApplicationPort: AnyObject {
    /// Every window the app lists, with its WindowServer ID.
    func windows() -> AXRead<[(id: WindowID, handle: WindowHandle)]>
    func classify(_ window: WindowHandle) -> WindowResolution
    /// Starts delivering notifications to `handler` on the main thread. Move and resize are only
    /// included on request, for when the WindowServer is not reporting them.
    func startObserving(includingGeometry: Bool, handler: @escaping (ApplicationNotification) -> Void)
    /// Asks to be told when this window starts closing. Only takes effect once observing started.
    func observeClosing(of window: WindowHandle, id: WindowID)
    /// Stops notifications. Called on the main thread, so none can be delivered afterwards.
    func stopObserving()
    /// Turns off the app's animated Accessibility resizing if it is on. Returns true when it was,
    /// in which case `resumeAnimatedResizing` puts it back.
    func suspendAnimatedResizing() -> Bool
    func resumeAnimatedResizing()
    /// Makes a window the app's main and focused window without help from the WindowServer.
    func focus(_ window: WindowHandle)
}

// MARK: - Accessibility

final class AXWindowHandle: WindowHandle {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
        // The process-wide default does not reach elements another app hands back.
        AXUIElementSetMessagingTimeout(element, AXApplication.messagingTimeout)
    }

    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func setPosition(_ origin: CGPoint) -> AXError {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func frame() -> CGRect? {
        AXReader.frame(of: element)
    }

    func title() -> String? {
        AXReader.string(element, attribute: kAXTitleAttribute)
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

/// The context of a per-window registration: which port it belongs to and which window it is for.
private final class WindowWatch {
    weak var port: AXApplicationPort?
    let id: WindowID

    init(port: AXApplicationPort, id: WindowID) {
        self.port = port
        self.id = id
    }
}

private let accessibilityNotificationCallback: AXObserverCallback = { _, element, notification, context in
    guard let context else { return }
    if notification as String == kAXUIElementDestroyedNotification {
        let watch = Unmanaged<WindowWatch>.fromOpaque(context).takeUnretainedValue()
        watch.port?.deliverClosing(watch)
    } else {
        Unmanaged<AXApplicationPort>.fromOpaque(context).takeUnretainedValue()
            .deliver(notification as String, element: element)
    }
}

final class AXApplicationPort: ApplicationPort {
    private static let enhancedUserInterface = "AXEnhancedUserInterface"
    private static let classificationAttributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        "AXModal",
        "AXFullScreen"
    ]

    private let pid: pid_t
    private let element: AXUIElement
    private let lock = NSLock()
    private var observer: AXObserver?
    private var handler: ((ApplicationNotification) -> Void)?
    /// Kept alive here because the observer only holds a raw pointer to each.
    private var watches: [WindowID: WindowWatch] = [:]
    private var isStopped = false

    init(pid: pid_t) {
        self.pid = pid
        element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, AXApplication.messagingTimeout)
    }

    func windows() -> AXRead<[(id: WindowID, handle: WindowHandle)]> {
        AXReader.elementsChecked(element, attribute: kAXWindowsAttribute).map { elements in
            elements.compactMap { element in
                AXReader.windowID(of: element).map { (id: $0, handle: AXWindowHandle(element: element)) }
            }
        }
    }

    func classify(_ window: WindowHandle) -> WindowResolution {
        guard let window = window as? AXWindowHandle,
              let reads = AXReader.multipleChecked(window.element, attributes: Self.classificationAttributes) else {
            return .unavailable
        }
        // With SkyLight a fullscreen window is on a Space that is never tiled. Without it the Space
        // is unknown, and the window has to say so itself.
        if !WindowServer.shared.usesSkyLight,
           case .value(true) = AXReader.boolReadFromBatch(reads["AXFullScreen"]) {
            return .excluded
        }
        let title = AXReader.stringFromBatch(reads[kAXTitleAttribute])
        var inputs = WindowManageabilityPlanner.Inputs(
            role: AXReader.stringReadFromBatch(reads[kAXRoleAttribute]),
            subrole: AXReader.stringReadFromBatch(reads[kAXSubroleAttribute]),
            isModal: AXReader.boolReadFromBatch(reads["AXModal"]),
            title: title,
            positionSettable: .value(true),
            sizeSettable: .value(true)
        )
        // Most windows are excluded by role alone, so only the survivors pay for these two calls.
        if WindowManageabilityPlanner.manageability(inputs) == .manageable {
            inputs.positionSettable = AXReader.isSettable(window.element, attribute: kAXPositionAttribute)
            inputs.sizeSettable = AXReader.isSettable(window.element, attribute: kAXSizeAttribute)
        }
        switch WindowManageabilityPlanner.manageability(inputs) {
        case .manageable:
            return .manageable(handle: window, title: title)
        case .excluded:
            return .excluded
        case .unknown:
            return .unavailable
        }
    }

    func startObserving(includingGeometry: Bool, handler: @escaping (ApplicationNotification) -> Void) {
        var created: AXObserver?
        guard AXObserverCreate(pid, accessibilityNotificationCallback, &created) == .success, let created else {
            return
        }
        var notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification
        ]
        if includingGeometry {
            notifications += [kAXWindowMovedNotification, kAXWindowResizedNotification]
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registeredAny = false
        for notification in notifications {
            let error = AXObserverAddNotification(created, element, notification as CFString, context)
            registeredAny = registeredAny || error == .success || error == .notificationAlreadyRegistered
        }
        guard registeredAny else { return }
        // The source goes in on the main thread, where `stopObserving` takes it out, so the two
        // cannot cross: a stop that comes first leaves nothing installed.
        DispatchQueue.main.async { [self] in
            lock.lock()
            let shouldInstall = !isStopped && observer == nil
            if shouldInstall {
                observer = created
                self.handler = handler
            }
            lock.unlock()
            if shouldInstall {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            }
        }
    }

    func observeClosing(of window: WindowHandle, id: WindowID) {
        guard let window = window as? AXWindowHandle else { return }
        // The watch is stored before it is registered: the notification can arrive straight away,
        // and it carries only a raw pointer to it.
        let watch = WindowWatch(port: self, id: id)
        lock.lock()
        let observer = isStopped || watches[id] != nil ? nil : self.observer
        if observer != nil {
            watches[id] = watch
        }
        lock.unlock()
        guard let observer else { return }
        let error = AXObserverAddNotification(
            observer,
            window.element,
            kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(watch).toOpaque()
        )
        guard error != .success, error != .notificationAlreadyRegistered else { return }
        lock.lock()
        let retired = watches.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async { _ = retired }
    }

    fileprivate func deliverClosing(_ watch: WindowWatch) {
        lock.lock()
        let handler = watches.removeValue(forKey: watch.id) != nil ? self.handler : nil
        lock.unlock()
        handler?(.windowClosing(watch.id))
    }

    func stopObserving() {
        lock.lock()
        isStopped = true
        let installed = observer
        observer = nil
        handler = nil
        // The watches outlive the run loop source below: a callback already on its way in still
        // finds its context alive, and finds no handler.
        let retired = watches
        watches.removeAll()
        lock.unlock()
        DispatchQueue.main.async { _ = retired }
        if let installed {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(installed), .commonModes)
        }
    }

    fileprivate func deliver(_ notification: String, element: AXUIElement) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else { return }
        if notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification {
            handler(.focusChanged(window: { AXReader.windowID(of: element) }))
        } else {
            handler(.windowsChanged)
        }
    }

    func suspendAnimatedResizing() -> Bool {
        AXReader.bool(element, attribute: Self.enhancedUserInterface) == true &&
            AXUIElementSetAttributeValue(element, Self.enhancedUserInterface as CFString, kCFBooleanFalse) == .success
    }

    func resumeAnimatedResizing() {
        AXUIElementSetAttributeValue(element, Self.enhancedUserInterface as CFString, kCFBooleanTrue)
    }

    func focus(_ window: WindowHandle) {
        guard let window = window as? AXWindowHandle else { return }
        AXUIElementSetAttributeValue(element, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        window.raise()
    }
}
