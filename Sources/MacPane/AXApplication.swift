import ApplicationServices
import CoreGraphics
import Foundation

/// A frame to give one window. Writes for the same window replace each other until one runs.
struct FrameWrite {
    let window: WindowID
    let handle: WindowHandle
    var frame: CGRect
    /// False moves the window and leaves its size alone.
    var setsSize: Bool
    /// Identifies the write in its outcome. Nil for animation steps, which are not read back.
    var token: Int?
}

/// The app's answer to a write. It says the app took the request, not what the frame became: that
/// shows up in the WindowServer a moment later and is read from there.
struct FrameWriteOutcome {
    let window: WindowID
    let token: Int
    let error: AXError
}

/// All traffic with one app, on that app's own serial queue.
///
/// Accessibility calls block until the target app answers, so nothing here ever runs on the main
/// thread, and an app that hangs holds up only its own windows.
final class AXApplication {
    static let messagingTimeout: Float = 0.25

    let pid: pid_t
    private let port: ApplicationPort
    private let queue: DispatchQueue
    private let server = WindowServer.shared
    private let onNotification: (pid_t) -> Void
    private let onFocusedWindow: (pid_t, WindowID) -> Void
    private let onWindowClosing: (WindowID) -> Void
    private let onOutcomes: ([FrameWriteOutcome]) -> Void

    private let lock = NSLock()
    private var mailbox: [WindowID: FrameWrite] = [:]
    private var mailboxOrder: [WindowID] = []
    private var isDraining = false
    private var isInvalidated = false
    /// When each window was last written, kept on the queue. Until a write has had time to reach
    /// the WindowServer, the bounds read from it are those of the frame before.
    private var lastWriteAt: [WindowID: UInt64] = [:]
    private let commitGrace: UInt64 = 100_000_000

    /// Every handler is called on the main thread. `onNotification` fires for any window
    /// notification from the app, `onFocusedWindow` when the app reports its focused window,
    /// `onWindowClosing` when a watched window starts to close, and `onOutcomes` with the result of
    /// each batch of frame writes.
    init(
        pid: pid_t,
        port: ApplicationPort,
        onNotification: @escaping (pid_t) -> Void,
        onFocusedWindow: @escaping (pid_t, WindowID) -> Void,
        onWindowClosing: @escaping (WindowID) -> Void,
        onOutcomes: @escaping ([FrameWriteOutcome]) -> Void
    ) {
        self.pid = pid
        self.port = port
        self.onNotification = onNotification
        self.onFocusedWindow = onFocusedWindow
        self.onWindowClosing = onWindowClosing
        self.onOutcomes = onOutcomes
        queue = DispatchQueue(label: "com.gigaxel.macpane.ax.\(pid)", qos: .userInteractive)
    }

    // MARK: - Notifications

    func observe(includingGeometry: Bool) {
        queue.async { [self] in
            guard !invalidated else { return }
            port.startObserving(includingGeometry: includingGeometry) { [weak self] notification in
                self?.deliver(notification)
            }
        }
    }

    /// Watches a window for the start of its close.
    func watch(_ window: WindowHandle, id: WindowID) {
        queue.async { [self] in
            guard !invalidated else { return }
            port.observeClosing(of: window, id: id)
        }
    }

    private func deliver(_ notification: ApplicationNotification) {
        guard !invalidated else { return }
        if case .windowClosing(let id) = notification {
            onWindowClosing(id)
        }
        onNotification(pid)
        guard case .focusChanged(let window) = notification else { return }
        queue.async { [self] in
            guard !invalidated, let id = window() else { return }
            DispatchQueue.main.async { [self] in
                guard !invalidated else { return }
                onFocusedWindow(pid, id)
            }
        }
    }

    /// Stops notifications and drops queued writes. Call on the main thread.
    func invalidate() {
        lock.lock()
        isInvalidated = true
        mailbox.removeAll()
        mailboxOrder.removeAll()
        lock.unlock()
        port.stopObserving()
    }

    // MARK: - Resolution

    /// Finds the app's handles for windows the WindowServer has shown us and decides whether each
    /// one can be tiled. `completion` runs on the main thread.
    func resolve(_ windows: Set<WindowID>, completion: @escaping ([WindowID: WindowResolution]) -> Void) {
        queue.async { [self] in
            var resolutions: [WindowID: WindowResolution] = [:]
            if !invalidated, case .value(let listed) = port.windows() {
                for (id, handle) in listed where windows.contains(id) && resolutions[id] == nil {
                    resolutions[id] = port.classify(handle)
                }
            }
            for id in windows where resolutions[id] == nil {
                resolutions[id] = .unavailable
            }
            DispatchQueue.main.async {
                completion(resolutions)
            }
        }
    }

    /// Reads the current titles of some windows. `completion` runs on the main thread.
    func readTitles(_ windows: [WindowID: WindowHandle], completion: @escaping ([WindowID: String]) -> Void) {
        queue.async { [self] in
            var titles: [WindowID: String] = [:]
            if !invalidated {
                for (id, window) in windows {
                    guard let title = window.title() else { continue }
                    titles[id] = title
                }
            }
            DispatchQueue.main.async {
                completion(titles)
            }
        }
    }

    // MARK: - Frames

    /// Queues frames to apply. A newer write for a window replaces one that has not run yet, so a
    /// slow app is always handed the latest layout rather than a backlog of old ones.
    func submit(_ writes: [FrameWrite]) {
        guard !writes.isEmpty else { return }
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        for var write in writes {
            if let pending = mailbox[write.window] {
                // A queued resize must survive a later move that carries no size of its own, and a
                // write that is waited on must still be answered.
                if pending.setsSize, !write.setsSize {
                    write.frame.size = pending.frame.size
                    write.setsSize = true
                }
                if write.token == nil {
                    write.token = pending.token
                }
            } else {
                mailboxOrder.append(write.window)
            }
            mailbox[write.window] = write
        }
        let shouldStart = !isDraining
        isDraining = true
        lock.unlock()
        if shouldStart {
            queue.async { [self] in drain() }
        }
    }

    /// Drops every write that has not started.
    func cancelPendingWrites() {
        lock.lock()
        mailbox.removeAll()
        mailboxOrder.removeAll()
        lock.unlock()
    }

    /// Runs `body` on this app's queue once everything queued before it has finished.
    func afterPendingWork(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    private func drain() {
        lock.lock()
        let batch = mailboxOrder.compactMap { mailbox[$0] }
        mailbox.removeAll()
        mailboxOrder.removeAll()
        if batch.isEmpty {
            isDraining = false
        }
        lock.unlock()
        guard !batch.isEmpty else { return }

        // An app with enhanced Accessibility on animates every resize. Turning it off for the
        // batch makes the frames apply at once.
        let suspendedAnimatedResizing = batch.contains(where: \.setsSize) && port.suspendAnimatedResizing()
        var appTimedOut = false
        var outcomes: [FrameWriteOutcome] = []
        for write in batch {
            let error = appTimedOut || invalidated ? AXError.cannotComplete : perform(write)
            // An app that stopped answering is not asked again for the rest of the batch.
            appTimedOut = appTimedOut || error == .cannotComplete
            if let token = write.token {
                outcomes.append(FrameWriteOutcome(window: write.window, token: token, error: error))
            }
        }
        if suspendedAnimatedResizing {
            port.resumeAnimatedResizing()
        }
        if !outcomes.isEmpty {
            DispatchQueue.main.async { [onOutcomes] in
                onOutcomes(outcomes)
            }
        }
        // One batch per turn, so work queued meanwhile runs in the order it was asked for.
        queue.async { [self] in drain() }
    }

    /// Sends the fewest attribute writes that take the window from where it is to `write.frame`.
    private func perform(_ write: FrameWrite) -> AXError {
        let frame = write.frame
        var error = AXError.success
        func record(_ result: AXError) {
            if error == .success || result == .cannotComplete {
                error = result
            }
        }
        func setSize() {
            guard error != .cannotComplete else { return }
            record(write.handle.setSize(frame.size))
        }
        func setPosition() {
            guard error != .cannotComplete else { return }
            record(write.handle.setPosition(frame.origin))
        }

        let now = PerformanceTrace.now()
        let isCommitted = lastWriteAt[write.window].map { now &- $0 > commitGrace } ?? true
        lastWriteAt[write.window] = now
        if lastWriteAt.count > 256 {
            lastWriteAt = lastWriteAt.filter { now &- $0.value <= commitGrace }
        }
        guard write.setsSize else {
            setPosition()
            return error
        }
        guard isCommitted, let current = currentFrame(of: write) else {
            // Where the window is right now is not known, so use the order that works from
            // anywhere: an app can clamp the size again once the window has moved.
            setSize()
            setPosition()
            setSize()
            return error
        }
        let resizes = !FramePlanner.approximatelyEqual(current.size, frame.size)
        let moves = !FramePlanner.approximatelyEqual(current.origin, frame.origin)
        if !resizes {
            if moves {
                setPosition()
            }
        } else if !moves {
            setSize()
        } else if frame.width > current.width + 1 || frame.height > current.height + 1 {
            // Growing in place can run off the display and get clamped, so move first.
            setPosition()
            setSize()
        } else {
            setSize()
            setPosition()
        }
        return error
    }

    private func currentFrame(of write: FrameWrite) -> CGRect? {
        server.usesSkyLight ? server.bounds(of: write.window) : write.handle.frame()
    }

    // MARK: - Focus

    func raise(_ window: WindowHandle) {
        queue.async { [self] in
            guard !invalidated else { return }
            window.raise()
        }
    }

    /// The public route to focusing a window, for when the WindowServer call is unavailable.
    func focusThroughAccessibility(_ window: WindowHandle) {
        queue.async { [self] in
            guard !invalidated else { return }
            port.focus(window)
        }
    }

    // MARK: - Private

    private var invalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInvalidated
    }
}
