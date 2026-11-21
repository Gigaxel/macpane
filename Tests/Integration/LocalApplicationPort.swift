import AppKit
import ApplicationServices

/// Stands in for Accessibility when the app under test is this process. Like the real port, every
/// call is made from a background queue and returns once the window has changed.
final class LocalWindowHandle: WindowHandle {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    /// AppKit measures from the bottom-left of the primary display, Accessibility from its top-left.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    func setSize(_ size: CGSize) -> AXError {
        DispatchQueue.main.sync {
            // Accessibility keeps the top-left corner in place and honors the window's limits.
            let frame = window.frame
            let width = min(max(size.width, window.minSize.width), window.maxSize.width)
            let height = min(max(size.height, window.minSize.height), window.maxSize.height)
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
            return .success
        }
    }

    func setPosition(_ origin: CGPoint) -> AXError {
        DispatchQueue.main.sync {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: origin.x, y: Self.primaryHeight - origin.y - frame.height))
            return .success
        }
    }

    func frame() -> CGRect? {
        DispatchQueue.main.sync {
            let frame = window.frame
            return CGRect(x: frame.minX, y: Self.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    func title() -> String? {
        DispatchQueue.main.sync { window.title }
    }

    func raise() {
        DispatchQueue.main.sync { window.orderFrontRegardless() }
    }
}

final class LocalApplicationPort: ApplicationPort {
    private var observers: [NSObjectProtocol] = []
    private var handler: ((ApplicationNotification) -> Void)?

    func windows() -> AXRead<[(id: WindowID, handle: WindowHandle)]> {
        DispatchQueue.main.sync {
            .value(NSApp.windows.filter { $0.windowNumber > 0 }.map {
                (id: WindowID($0.windowNumber), handle: LocalWindowHandle(window: $0) as WindowHandle)
            })
        }
    }

    func classify(_ window: WindowHandle) -> WindowResolution {
        guard let local = window as? LocalWindowHandle else { return .unavailable }
        return DispatchQueue.main.sync {
            local.window is NSPanel ? .excluded : .manageable(handle: local, title: local.window.title)
        }
    }

    func observeClosing(of window: WindowHandle, id: WindowID) {
        guard let local = window as? LocalWindowHandle else { return }
        DispatchQueue.main.sync {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: local.window, queue: .main
            ) { [weak self] _ in
                self?.handler?(.windowClosing(id))
            })
        }
    }

    func startObserving(includingGeometry: Bool, handler: @escaping (ApplicationNotification) -> Void) {
        DispatchQueue.main.sync {
            self.handler = handler
            let names: [Notification.Name] = [
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeMainNotification,
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    handler(.windowsChanged)
                }
            }
        }
    }

    func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        handler = nil
    }

    func suspendAnimatedResizing() -> Bool { false }
    func resumeAnimatedResizing() {}

    func focus(_ window: WindowHandle) {
        window.raise()
    }
}
