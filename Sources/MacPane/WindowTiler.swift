import AppKit
import ApplicationServices

/// Keeps every window where the tiling model says it belongs.
///
/// The WindowServer is the source of truth. Any event (a window created, moved or closed, a Space
/// switched, a hotkey pressed) triggers a `reconcile`, which re-reads the whole window list in a few
/// tens of microseconds, updates the model and writes whichever frames differ from their goal.
/// Nothing is polled and nothing observed is kept between reconciles, so a missed or duplicated
/// event cannot leave the model out of date.
///
/// Everything here runs on the main thread and never waits on another app: all Accessibility calls
/// happen on per-app queues in `AXApplication`.
final class WindowTiler {
    /// What the integration tests answer differently from the app.
    struct Environment {
        var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        /// MacPane manages every app but itself. The integration tests turn that around and manage
        /// only their own windows.
        var managesProcess: (pid_t) -> Bool = { $0 != getpid() }
        /// How an app's windows are reached: through Accessibility, or in the integration tests
        /// directly, since a process cannot see its own windows through Accessibility.
        var makePort: (pid_t) -> ApplicationPort = { AXApplicationPort(pid: $0) }
        /// The tests drive their own windows directly, so they run with the screen locked too.
        var isScreenLocked: () -> Bool = {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        }
    }

    private let environment: Environment
    private let settings: WindowTilerSettings
    private let server = WindowServer.shared
    private var model = TilingModel()
    private var applications: [pid_t: AXApplication] = [:]

    // MARK: Discovery state

    /// A window the WindowServer shows that Accessibility has not described yet.
    private struct Resolution {
        let pid: pid_t
        let firstSeenAt: UInt64
        var attempts = 1
        var isInFlight = true
        var nextAttemptAt: UInt64 = 0
    }
    private struct ResolvedWindow {
        let pid: pid_t
        let handle: WindowHandle
        let title: String?
        let firstSeenAt: UInt64
    }
    private var resolving: [WindowID: Resolution] = [:]
    private var awaitingAdoption: [WindowID: ResolvedWindow] = [:]
    /// Managed windows waiting on a replacement for a dead handle.
    /// Windows whose handle is being replaced, each with the identity of the repair under way.
    private var rehandling: [WindowID: Int] = [:]
    private var lastRepair = 0
    /// On-screen windows their app described as something not to tile (a dialog, a panel), with
    /// the app they belong to. The answer is asked for again when that app next reports a change,
    /// because a window can start out as one thing and become another.
    private var ignored: [WindowID: pid_t] = [:]
    private var hasAdoptedInitialWindows = false
    private let maximumResolutionAttempts = 12
    /// How long a batch of new windows waits for the rest of the batch, so launching MacPane or
    /// visiting a Space for the first time lays out once instead of once per app.
    private let adoptionGate: UInt64 = 120_000_000
    private let autoFloatGrowOutInterval: UInt64 = 3_000_000_000

    // MARK: Layout state

    private var frameRecords: [WindowID: FrameRecord] = [:]
    private var nextWriteToken = 0
    /// Windows the user is moving or resizing with the pointer right now.
    private var dragged: Set<WindowID> = []
    /// Windows whose app said they are closing, with a deadline. macOS keeps a closing window on
    /// screen while it fades out; its neighbors take its space straight away.
    private var closing: [WindowID: UInt64] = [:]
    private let closingGrace: UInt64 = 1_000_000_000
    /// Windows sent to another display whose Space has not caught up yet, with a deadline.
    private var relocating: [WindowID: UInt64] = [:]
    private var layoutPausedUntil: UInt64 = 0
    /// The displays and their bounds when the display layout last changed.
    private var displayLayout: [CGDirectDisplayID: CGRect] = [:]
    private let relocationGrace: UInt64 = 2_000_000_000

    // MARK: Focus state

    /// The window commands act on: the one being focused if a request is in flight, else the one
    /// the WindowServer shows in front.
    private var focusedWindow: WindowID?
    private var observedFocus: WindowID?
    private var focusIntent: (window: WindowID, deadline: UInt64)?
    /// What each app last reported as its focused window. Only used to tell apart two windows of
    /// the front app that are each topmost on their own display.
    private var accessibilityFocus: [pid_t: WindowID] = [:]
    /// A display with no windows that was focused with the keyboard.
    private var selectedEmptyScreen: (key: String, focus: WindowID?)?
    private let focusIntentDuration: UInt64 = 400_000_000

    // MARK: Workspace switching

    private var slide: SlideChain?
    private var pendingWorkspaceSwitchIndicator: WorkspaceSwitchIndicatorState?
    private let workspaceSlideAnimationDuration: TimeInterval = 0.18
    private let workspaceSlideChainedDuration: TimeInterval = 0.14

    // MARK: Lifecycle state

    private enum Suspension: Hashable {
        case sleep
        case inactiveSession
        /// While the screen is locked, apps show Accessibility nothing but themselves: no windows.
        case lockedScreen
    }
    private var isRunning = false
    private var isStopping = false
    private var suspensions: Set<Suspension> = []
    private var isReconcileScheduled = false
    private var wake: (item: DispatchWorkItem, deadline: UInt64)?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var fallbackTimer: Timer?
    private var pointerMonitor: Any?
    private var commandStartedAt: UInt64?
    private var traceStarts: [WindowID: UInt64] = [:]

    /// Called on the main thread when something the settings UI shows has changed.
    var onStateChange: (() -> Void)?

    init(environment: Environment = Environment(), settings: WindowTilerSettings = WindowTilerSettings()) {
        self.environment = environment
        self.settings = settings
    }

    /// One reading of the WindowServer, used for a single reconcile or command and then dropped.
    private struct World {
        let now: UInt64
        let screens: [ScreenInfo]
        /// Front to back.
        let windows: [ServerWindow]
        let byID: [WindowID: ServerWindow]
        /// Windows showing on a display whose current Space is an ordinary desktop.
        var onScreen: Set<WindowID>
        let shared: Set<WindowID>

        func screen(for scope: ScopeKey) -> ScreenInfo? {
            screens.first { $0.scope == scope }
        }
        func screen(forDisplay key: String) -> ScreenInfo? {
            screens.first { $0.key == key }
        }
        /// The display a window is on. Displays that share one Space are told apart by geometry.
        func screen(for window: ServerWindow) -> ScreenInfo? {
            let candidates = screens.filter { $0.isTileable && $0.space == window.space }
            return candidates.count == 1 ? candidates[0] : ScreenCatalog.screen(for: window.bounds, in: candidates)
        }
    }

    // MARK: - Settings

    var gapPixels: Int { settings.gapPixels }
    var workspaceCount: Int { settings.workspaceCount }
    var tilingEnabled: Bool { settings.tilingEnabled }
    var workspaceSwitchAnimationsEnabled: Bool { settings.workspaceSwitchAnimationsEnabled }
    var autoFloatSmallWindowsEnabled: Bool { settings.autoFloatSmallWindowsEnabled }
    var autoFloatWidthThreshold: Int { settings.autoFloatWidthThreshold }
    var autoFloatHeightThreshold: Int { settings.autoFloatHeightThreshold }
    var fastFocusEnabled: Bool { settings.fastFocusEnabled }
    var isFastFocusAvailable: Bool { server.canFocusDirectly }
    var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }

    func markOnboardingCompleted() {
        settings.markOnboardingCompleted()
    }
    func setAutoFloatSmallWindowsEnabled(_ value: Bool) {
        settings.setAutoFloatSmallWindowsEnabled(value)
    }
    func setAutoFloatWidthThreshold(_ value: Int) {
        settings.setAutoFloatWidthThreshold(value)
    }
    func setAutoFloatHeightThreshold(_ value: Int) {
        settings.setAutoFloatHeightThreshold(value)
    }
    func setFastFocusEnabled(_ value: Bool) {
        settings.setFastFocusEnabled(value)
    }
    func setGap(_ value: Int) {
        guard !isStopping else { return }
        settings.setGap(value)
        setNeedsReconcile()
    }
    func adjustGap(by delta: Int) {
        setGap(gapPixels + delta)
    }
    func setTilingEnabled(_ value: Bool) {
        guard !isStopping, tilingEnabled != value else { return }
        toggleTiling()
    }
    func setWorkspaceSwitchAnimationsEnabled(_ value: Bool) {
        guard !isStopping, workspaceSwitchAnimationsEnabled != value else { return }
        toggleWorkspaceSwitchAnimations()
    }
    func isWorkspaceIndexAvailable(_ index: Int) -> Bool {
        settings.availableWorkspaceIndex(index) != nil
    }

    // MARK: - Accessibility permission

    func hasAccessibilityPermission(prompt: Bool) -> Bool {
        guard prompt else { return environment.isAccessibilityTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    func requestAccessibilityPermission() -> Bool {
        settings.markAccessibilityPrompted()
        return hasAccessibilityPermission(prompt: true)
    }
    private func ensureAccessibilityPermission() -> Bool {
        if hasAccessibilityPermission(prompt: false) { return true }
        guard !settings.hasPromptedForAccessibilityPermission else { return false }
        return requestAccessibilityPermission()
    }
    /// macOS does not say when permission is granted, so this checks once a second, and only while
    /// MacPane is waiting for it.
    private func beginPermissionPolling() {
        guard !isStopping, permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, !self.isStopping else {
                timer.invalidate()
                return
            }
            guard self.hasAccessibilityPermission(prompt: false) else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.startWatching()
            self.setNeedsReconcile()
            self.onStateChange?()
        }
    }

    // MARK: - Lifecycle

    func start() {
        isStopping = false
        guard ensureAccessibilityPermission() else {
            beginPermissionPolling()
            return
        }
        startWatching()
        setNeedsReconcile()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        restoreWindowsBeforeStopping()
        isRunning = false
        wake?.item.cancel()
        wake = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in lockObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        lockObservers.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        server.stopEvents()
        for application in applications.values {
            application.invalidate()
        }
        applications.removeAll()
        model = TilingModel()
        resolving.removeAll()
        awaitingAdoption.removeAll()
        rehandling.removeAll()
        ignored.removeAll()
        hasAdoptedInitialWindows = false
        frameRecords.removeAll()
        dragged.removeAll()
        closing.removeAll()
        relocating.removeAll()
        layoutPausedUntil = 0
        displayLayout.removeAll()
        focusedWindow = nil
        observedFocus = nil
        focusIntent = nil
        accessibilityFocus.removeAll()
        selectedEmptyScreen = nil
        pendingWorkspaceSwitchIndicator = nil
        suspensions.removeAll()
        traceStarts.removeAll()
    }

    private func startWatching() {
        guard !isStopping, !isRunning else { return }
        isRunning = true
        // The system-wide element sets the default for every element this process creates.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXApplication.messagingTimeout)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (WindowTiler, Notification) -> Void) {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, !self.isStopping else { return }
                handler(self, notification)
            })
        }
        func runningApplication(_ notification: Notification) -> NSRunningApplication? {
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { tiler, notification in
            if let application = runningApplication(notification), tiler.isManageable(application) {
                _ = tiler.application(for: application.processIdentifier)
            }
            tiler.setNeedsReconcile()
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { tiler, notification in
            if let application = runningApplication(notification) {
                tiler.forgetApplication(application.processIdentifier)
            }
            tiler.setNeedsReconcile()
        }
        observe(NSWorkspace.didActivateApplicationNotification) { tiler, notification in
            if let application = runningApplication(notification) {
                tiler.retryResolutions(forPID: application.processIdentifier)
            }
            tiler.setNeedsReconcile()
        }
        for name in [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            observe(name) { tiler, _ in tiler.setNeedsReconcile() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name) { tiler, _ in tiler.suspend(.sleep) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(name) { tiler, _ in tiler.resume(.sleep) }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { tiler, _ in tiler.suspend(.inactiveSession) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { tiler, _ in tiler.resume(.inactiveSession) }
        let distributedCenter = DistributedNotificationCenter.default()
        lockObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.suspend(.lockedScreen)
        })
        lockObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.resume(.lockedScreen)
        })
        if environment.isScreenLocked() {
            suspensions.insert(.lockedScreen)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChanged()
        }
        displayLayout = currentDisplayLayout()
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            self?.setNeedsReconcile()
        }
        if !server.startEvents({ [weak self] in self?.setNeedsReconcile() }) {
            // Without WindowServer events some apps open windows that nothing announces.
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.setNeedsReconcile()
            }
            fallbackTimer?.tolerance = 0.25
        }
        for application in NSWorkspace.shared.runningApplications where isManageable(application) {
            _ = self.application(for: application.processIdentifier)
        }
    }

    private func currentDisplayLayout() -> [CGDirectDisplayID: CGRect] {
        NSScreen.screens.reduce(into: [:]) { layout, screen in
            guard let displayID = screen.displayID else { return }
            layout[displayID] = CGDisplayBounds(displayID)
        }
    }

    /// This notification covers two very different things. A display being added, removed, moved
    /// or changing resolution makes macOS shuffle windows for a moment, so layout waits for that.
    /// The Dock or menu bar changing size, which happens every time an app joins the Dock, only
    /// changes the usable area and is laid out straight away.
    private func handleScreenParametersChanged() {
        let layout = currentDisplayLayout()
        guard layout != displayLayout else {
            setNeedsReconcile()
            return
        }
        displayLayout = layout
        pauseLayout(for: 1.2)
    }

    private func suspend(_ reason: Suspension) {
        guard !isStopping else { return }
        suspensions.insert(reason)
        cancelSlide()
        cancelPendingWrites()
    }
    private func resume(_ reason: Suspension) {
        guard !isStopping, suspensions.remove(reason) != nil, suspensions.isEmpty else { return }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXApplication.messagingTimeout)
        displayLayout = currentDisplayLayout()
        // Whatever apps answered while the session was away is asked again.
        resolving = resolving.filter { $0.value.isInFlight }
        ignored.removeAll()
        for id in Array(rehandling.keys) {
            startHandleRepair(of: id)
        }
        // Displays come back one at a time after a wake or unlock.
        pauseLayout(for: 1.8)
    }
    private func pauseLayout(for duration: TimeInterval) {
        guard !isStopping else { return }
        cancelSlide()
        cancelPendingWrites()
        layoutPausedUntil = max(layoutPausedUntil, PerformanceTrace.now() + UInt64(duration * 1_000_000_000))
        scheduleWake(after: duration + 0.01)
    }
    /// Drops queued frames and what was known about their progress, so the next reconcile starts
    /// each window from what it observes.
    private func cancelPendingWrites() {
        for application in applications.values {
            application.cancelPendingWrites()
        }
        frameRecords.removeAll()
        dragged.removeAll()
    }

    // MARK: - Applications

    private func isManageable(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular && environment.managesProcess(application.processIdentifier)
    }
    private func isManageableApplication(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid).map(isManageable) ?? false
    }
    private func application(for pid: pid_t) -> AXApplication {
        if let existing = applications[pid] {
            return existing
        }
        let application = AXApplication(
            pid: pid,
            port: environment.makePort(pid),
            onNotification: { [weak self] pid, isGeometry in
                guard let self, !self.isStopping else { return }
                if !isGeometry {
                    // A move says nothing new about what a window is.
                    self.retryResolutions(forPID: pid)
                }
                self.setNeedsReconcile()
            },
            onFocusedWindow: { [weak self] pid, window in
                guard let self, !self.isStopping else { return }
                self.accessibilityFocus[pid] = window
                self.setNeedsReconcile()
            },
            onWindowClosing: { [weak self] window in
                guard let self, !self.isStopping, self.model.isManaged(window) else { return }
                PerformanceTrace.event("window-closing", "window \(window)")
                self.closing[window] = PerformanceTrace.now() + self.closingGrace
                // If the window is still there by then, its handle is dead and has to be replaced.
                self.scheduleWake(after: PerformanceTrace.seconds(self.closingGrace) + 0.01)
            },
            onOutcomes: { [weak self] outcomes in
                self?.handleFrameWriteOutcomes(outcomes)
            }
        )
        applications[pid] = application
        application.observe(includingGeometry: !server.deliversEvents)
        return application
    }
    private func forgetApplication(_ pid: pid_t) {
        applications.removeValue(forKey: pid)?.invalidate()
        accessibilityFocus.removeValue(forKey: pid)
        for id in model.windows.values.filter({ $0.pid == pid }).map(\.id) {
            forget(id)
        }
        for (id, resolution) in resolving where resolution.pid == pid {
            resolving.removeValue(forKey: id)
        }
        for (id, resolved) in awaitingAdoption where resolved.pid == pid {
            awaitingAdoption.removeValue(forKey: id)
        }
    }
    private func forget(_ id: WindowID) {
        PerformanceTrace.event("window-forgotten", "window \(id)")
        model.forget(id)
        forgetTracking(of: id)
    }
    /// Drops everything the tiler itself keeps about a window that the model no longer has.
    private func forgetTracking(of id: WindowID) {
        frameRecords.removeValue(forKey: id)
        dragged.remove(id)
        closing.removeValue(forKey: id)
        rehandling.removeValue(forKey: id)
        relocating.removeValue(forKey: id)
        traceStarts.removeValue(forKey: id)
        accessibilityFocus = accessibilityFocus.filter { $0.value != id }
        if focusedWindow == id { focusedWindow = nil }
        if observedFocus == id { observedFocus = nil }
        if focusIntent?.window == id { focusIntent = nil }
    }

    // MARK: - Scheduling

    /// Requests a reconcile on the next turn of the main run loop. Any number of events in one turn
    /// cost one reconcile.
    private func setNeedsReconcile() {
        guard isRunning, !isStopping, !isReconcileScheduled else { return }
        isReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isReconcileScheduled else { return }
            self.reconcile()
        }
    }
    /// Reconciles once more after `delay`, for the few things that settle without an event.
    private func scheduleWake(after delay: TimeInterval) {
        guard isRunning, !isStopping else { return }
        let deadline = PerformanceTrace.now() + UInt64(max(delay, 0) * 1_000_000_000)
        if let wake, wake.deadline <= deadline { return }
        wake?.item.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wake = nil
            self.setNeedsReconcile()
        }
        wake = (item, deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
    }
    private func scheduleWake(at deadline: UInt64, now: UInt64) {
        scheduleWake(after: PerformanceTrace.seconds(deadline > now ? deadline - now : 0))
    }

    // MARK: - Reconcile

    private func readWorld() -> World {
        let screens = ScreenCatalog.current(server: server)
        var spaces: [UInt64] = []
        for screen in screens where !spaces.contains(screen.space) {
            spaces.append(screen.space)
        }
        let listing = server.windows(onSpaces: spaces)
        let tileableSpaces = Set(screens.filter(\.isTileable).map(\.space))
        let now = PerformanceTrace.now()
        var byID: [WindowID: ServerWindow] = [:]
        byID.reserveCapacity(listing.windows.count)
        var onScreen: Set<WindowID> = []
        for window in listing.windows where byID[window.id] == nil {
            byID[window.id] = window
            // A window on its way out is still listed while its animation runs: one being
            // minimized already carries the tag, and one being closed was announced by its app.
            if tileableSpaces.contains(window.space), !window.isMinimized, (closing[window.id] ?? 0) <= now {
                onScreen.insert(window.id)
            }
        }
        return World(
            now: now,
            screens: screens,
            windows: listing.windows,
            byID: byID,
            onScreen: onScreen,
            shared: listing.shared
        )
    }

    /// Brings the model up to date with the WindowServer and writes every frame that is off its
    /// goal. Returns the reading it worked from, or nil when MacPane is not allowed to act.
    @discardableResult
    private func reconcile() -> World? {
        isReconcileScheduled = false
        guard isRunning, !isStopping, suspensions.isEmpty else { return nil }
        guard hasAccessibilityPermission(prompt: false) else {
            beginPermissionPolling()
            return nil
        }
        var world = readWorld()
        // A tab that was just switched away from holds its tile until its successor takes over, so
        // its neighbors do not grow into the space and shrink back.
        world.onScreen.formUnion(removeDepartedWindows(world))
        guard isSettled(world) else {
            server.subscribe(to: world.windows.map(\.id).sorted())
            return world
        }
        let restored = model.reconcileDisplays(world.screens, onScreen: world.onScreen) { windows in
            Self.fallbackScreen(for: windows, world)
        }
        for id in restored {
            relocating[id] = world.now + relocationGrace
        }
        discoverWindows(world)
        adoptResolvedWindows(world)
        rehomeWindows(world)
        reconsiderAutoFloats(world)
        updateFocus(world)
        finishDragsIfReleased(world)
        if settings.tilingEnabled {
            convergeFrames(world)
        }
        server.subscribe(to: world.windows.filter(\.isStandard).map(\.id).sorted())
        return world
    }

    /// False while Mission Control is showing or the display layout is still changing. Windows are
    /// still tracked then, but nothing is adopted, moved or written.
    private func isSettled(_ world: World) -> Bool {
        if world.now < layoutPausedUntil {
            scheduleWake(at: layoutPausedUntil, now: world.now)
            return false
        }
        if isMissionControlShowing(world) {
            // Its overlay closing is an event; this is only for the case where that goes unseen.
            scheduleWake(after: 0.25)
            return false
        }
        return true
    }

    /// Mission Control and App Exposé cover each display with a Dock window that starts one point
    /// above the display.
    private func isMissionControlShowing(_ world: World) -> Bool {
        world.windows.contains { window in
            world.screens.contains { window.bounds.minY == $0.bounds.minY - 1 } &&
                NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == "com.apple.dock"
        }
    }

    /// Forgets managed windows that are gone. Returns the ones that are off screen only because a
    /// tab switch is replacing them.
    @discardableResult
    private func removeDepartedWindows(_ world: World) -> Set<WindowID> {
        for id in ignored.keys where world.byID[id] == nil {
            ignored.removeValue(forKey: id)
        }
        for id in resolving.keys where world.byID[id] == nil {
            resolving.removeValue(forKey: id)
        }
        for id in awaitingAdoption.keys where world.byID[id] == nil {
            awaitingAdoption.removeValue(forKey: id)
        }
        for (id, deadline) in closing where world.byID[id] == nil || deadline <= world.now {
            closing.removeValue(forKey: id)
            if world.byID[id] != nil {
                // The app destroyed the element but the window is still here: it rebuilt its
                // windows, and the handle is dead.
                replaceHandle(of: id)
            }
        }
        if let nextDeadline = closing.values.min() {
            // Only the earliest wake is kept, so the deadline is asked for again every time.
            scheduleWake(at: nextDeadline, now: world.now)
        }
        let missing = model.windows.keys.filter { world.byID[$0] == nil }
        guard !missing.isEmpty else { return [] }
        let described = server.describe(missing)
        let showingSpaces = Set(world.screens.map(\.space))
        var beingReplaced: Set<WindowID> = []
        for id in missing {
            guard let window = described[id] else {
                forget(id)
                continue
            }
            // A window that still exists but is not showing keeps its place when it is minimized,
            // hidden with its app, or on a Space that is not showing. Otherwise it was closed and
            // the app merely kept it around; the public window list cannot tell these apart.
            guard server.usesSkyLight, !window.isMinimized, !window.isHiddenWithApplication,
                  let expected = model.workspace(of: id)?.space ?? model.floating[id]?.space,
                  showingSpaces.contains(expected),
                  server.space(of: id).map(showingSpaces.contains) ?? true else {
                continue
            }
            if isBeingReplaced(id, bounds: window.bounds, world) {
                beingReplaced.insert(id)
            } else {
                forget(id)
            }
        }
        return beingReplaced
    }

    /// True while a new window of the same app is being adopted at exactly this spot. That is a tab
    /// switch: one window is ordered out and another ordered in. The old window is kept until the
    /// new one can take over its tile.
    private func isBeingReplaced(_ id: WindowID, bounds: CGRect, _ world: World) -> Bool {
        guard let pid = model.windows[id]?.pid else { return false }
        // A successor is a new window of the same app at the same frame that is still on its way
        // to being adopted. One whose app has stopped answering about it does not hold the tile.
        return world.windows.contains { window in
            window.pid == pid && window.isStandard && world.onScreen.contains(window.id) &&
                !model.isManaged(window.id) && ignored[window.id] == nil &&
                resolving[window.id]?.nextAttemptAt != .max &&
                FramePlanner.approximatelyEqual(window.bounds, bounds)
        }
    }

    /// The display that takes over some windows whose own display is gone: the one most of them
    /// are on now, else the one under the pointer.
    private static func fallbackScreen(for windows: [WindowID], _ world: World) -> ScreenInfo? {
        let tileable = world.screens.filter(\.isTileable)
        var counts: [String: Int] = [:]
        for id in windows {
            guard let window = world.byID[id], let screen = world.screen(for: window) else { continue }
            counts[screen.key, default: 0] += 1
        }
        if let busiest = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
           let screen = world.screen(forDisplay: busiest.key) {
            return screen
        }
        return ScreenCatalog.screen(containing: ScreenCatalog.cursorLocation(), in: tileable) ?? tileable.first
    }

    // MARK: - Discovery

    private func discoverWindows(_ world: World) {
        var requests: [pid_t: Set<WindowID>] = [:]
        var earliestRetry: UInt64?
        for window in world.windows where window.isStandard && world.onScreen.contains(window.id) {
            let id = window.id
            guard !model.isManaged(id), ignored[id] == nil, awaitingAdoption[id] == nil else { continue }
            if var resolution = resolving[id] {
                guard !resolution.isInFlight else { continue }
                guard resolution.nextAttemptAt <= world.now else {
                    if resolution.nextAttemptAt != .max {
                        earliestRetry = min(earliestRetry ?? .max, resolution.nextAttemptAt)
                    }
                    continue
                }
                resolution.isInFlight = true
                resolution.attempts += 1
                resolving[id] = resolution
            } else {
                // Not remembered: an app can turn into a regular app after its window is up.
                guard isManageableApplication(pid: window.pid) else { continue }
                resolving[id] = Resolution(pid: window.pid, firstSeenAt: world.now)
            }
            requests[window.pid, default: []].insert(id)
        }
        for (pid, windows) in requests {
            application(for: pid).resolve(windows) { [weak self] resolutions in
                self?.handleResolutions(resolutions)
            }
        }
        if let earliestRetry {
            scheduleWake(at: earliestRetry, now: world.now)
        }
    }

    private func handleResolutions(_ resolutions: [WindowID: WindowResolution]) {
        guard isRunning, !isStopping else { return }
        let now = PerformanceTrace.now()
        for (id, resolution) in resolutions {
            guard var pending = resolving[id] else { continue }
            switch resolution {
            case .manageable(let handle, let title):
                resolving.removeValue(forKey: id)
                awaitingAdoption[id] = ResolvedWindow(
                    pid: pending.pid,
                    handle: handle,
                    title: title,
                    firstSeenAt: pending.firstSeenAt
                )
            case .excluded:
                resolving.removeValue(forKey: id)
                ignored[id] = pending.pid
                PerformanceTrace.event("window-excluded", "window \(id) pid \(pending.pid)")
            case .unavailable:
                // Apps publish a window to Accessibility a little after the WindowServer shows it.
                // Back off quickly, then wait for the app to say something.
                pending.isInFlight = false
                if pending.attempts >= maximumResolutionAttempts {
                    pending.nextAttemptAt = .max
                } else {
                    let delay: UInt64 = min(UInt64(16_000_000) << UInt64(pending.attempts - 1), 1_000_000_000)
                    pending.nextAttemptAt = now + delay
                }
                resolving[id] = pending
                PerformanceTrace.event("window-unresolved", "window \(id) pid \(pending.pid) attempt \(pending.attempts)")
            }
        }
        setNeedsReconcile()
    }

    /// Asks the app for a fresh handle to a window whose handle has died. The window keeps its tile
    /// meanwhile. It is forgotten, to be found again as new, only when the app says it is not a
    /// window to tile or keeps failing to produce it.
    private func replaceHandle(of id: WindowID) {
        guard model.windows[id] != nil, rehandling[id] == nil else { return }
        startHandleRepair(of: id)
    }

    /// Starts a repair from its first attempt. Anything still in flight for an earlier repair of
    /// the same window no longer matches and ends there.
    private func startHandleRepair(of id: WindowID) {
        lastRepair += 1
        rehandling[id] = lastRepair
        requestHandle(for: id, repair: lastRepair, attempt: 1)
    }

    private func requestHandle(for id: WindowID, repair: Int, attempt: Int) {
        guard let window = model.windows[id] else { return }
        application(for: window.pid).resolve([id]) { [weak self] resolutions in
            guard let self, self.rehandling[id] == repair, self.model.isManaged(id) else { return }
            // Apps hide their windows from Accessibility while the screen is locked, so an answer
            // that came while suspended decides nothing. The repair starts over on resume.
            guard self.suspensions.isEmpty else { return }
            switch resolutions[id] {
            case .manageable(let handle, _)?:
                self.rehandling.removeValue(forKey: id)
                self.model.setHandle(handle, of: id)
                self.frameRecords.removeValue(forKey: id)
                self.application(for: window.pid).watch(handle, id: id)
                self.setNeedsReconcile()
            case .unavailable? where attempt < self.maximumResolutionAttempts:
                // The app is busy or still rebuilding the window. Ask again shortly.
                let delay = min(0.016 * pow(2, Double(attempt - 1)), 1.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    // While suspended the entry stays, and the repair starts over on resume.
                    guard let self, !self.isStopping, self.suspensions.isEmpty,
                          self.rehandling[id] == repair else { return }
                    self.requestHandle(for: id, repair: repair, attempt: attempt + 1)
                }
            default:
                self.forget(id)
                self.setNeedsReconcile()
            }
        }
    }

    /// An app that just notified or came forward gets another chance right away.
    private func retryResolutions(forPID pid: pid_t) {
        for (id, owner) in ignored where owner == pid {
            ignored.removeValue(forKey: id)
        }
        for (id, resolution) in resolving where resolution.pid == pid && !resolution.isInFlight {
            resolving[id]?.nextAttemptAt = 0
            if resolution.attempts >= maximumResolutionAttempts {
                resolving[id]?.attempts = 1
            }
        }
    }

    private func adoptResolvedWindows(_ world: World) {
        let newestFirstAttempt = resolving.values
            .filter { $0.isInFlight && $0.attempts == 1 }
            .map(\.firstSeenAt)
            .max()
        guard !awaitingAdoption.isEmpty else {
            // Nothing was open when MacPane started: the windows that come later are new ones.
            hasAdoptedInitialWindows = hasAdoptedInitialWindows || newestFirstAttempt == nil
            return
        }
        if let newestFirstAttempt, world.now &- newestFirstAttempt < adoptionGate {
            scheduleWake(at: newestFirstAttempt + adoptionGate, now: world.now)
            return
        }
        // Back to front, so the frontmost window is the last one in and gets the newest tile.
        for window in world.windows.reversed() {
            guard let resolved = awaitingAdoption[window.id],
                  world.onScreen.contains(window.id),
                  let screen = world.screen(for: window) else {
                continue
            }
            awaitingAdoption.removeValue(forKey: window.id)
            adopt(window, resolved, on: screen, world)
        }
        hasAdoptedInitialWindows = true
    }

    private func adopt(_ window: ServerWindow, _ resolved: ResolvedWindow, on screen: ScreenInfo, _ world: World) {
        var managed = ManagedWindow(
            id: window.id,
            pid: resolved.pid,
            handle: resolved.handle,
            bundleIdentifier: NSRunningApplication(processIdentifier: resolved.pid)?.bundleIdentifier,
            title: resolved.title
        )
        let key = model.activeKey(on: screen)
        if let replaced = replacedWindow(by: window, on: screen, world) {
            model.adopt(managed, replacing: replaced)
            // Focus that was on the old tab is on its successor.
            if focusedWindow == replaced { focusedWindow = window.id }
            if observedFocus == replaced { observedFocus = window.id }
            if focusIntent?.window == replaced { focusIntent?.window = window.id }
            if accessibilityFocus[resolved.pid] == replaced { accessibilityFocus[resolved.pid] = window.id }
            forgetTracking(of: replaced)
        } else if hasAdoptedInitialWindows, settings.autoFloatSmallWindowsEnabled, isBelowAutoFloatSize(window.bounds) {
            managed.autoFloatedAt = world.now
            model.adoptFloating(managed, in: screen.scope)
        } else {
            model.adoptTiled(managed, in: key, onScreen: world.onScreen)
        }
        application(for: resolved.pid).watch(resolved.handle, id: window.id)
        if PerformanceTrace.isVerbose {
            traceStarts[window.id] = resolved.firstSeenAt
        }
        PerformanceTrace.event(
            "window-adopted",
            "window \(window.id) pid \(resolved.pid) resolved in \(PerformanceTrace.format(PerformanceTrace.milliseconds(since: resolved.firstSeenAt)))"
        )
    }

    /// The managed window a new window takes over from: one of the same app that has just been
    /// ordered out at exactly the same frame. Switching tabs does this.
    private func replacedWindow(by window: ServerWindow, on screen: ScreenInfo, _ world: World) -> WindowID? {
        // Windows on other Spaces are absent too, and a maximized one there has the same frame.
        let candidates = model.windows.values.filter { candidate in
            candidate.pid == window.pid && world.byID[candidate.id] == nil &&
                (model.workspace(of: candidate.id)?.scope ?? model.floating[candidate.id]) == screen.scope
        }.map(\.id)
        guard !candidates.isEmpty else { return nil }
        return server.describe(candidates).values.first { candidate in
            !candidate.isMinimized && !candidate.isHiddenWithApplication &&
                FramePlanner.approximatelyEqual(candidate.bounds, window.bounds)
        }?.id
    }

    private func isBelowAutoFloatSize(_ frame: CGRect) -> Bool {
        frame.width < CGFloat(settings.autoFloatWidthThreshold) ||
            frame.height < CGFloat(settings.autoFloatHeightThreshold)
    }

    /// A window that opened small and was floated is tiled after all if it grows straight away,
    /// which is what apps that size their window after showing it do.
    private func reconsiderAutoFloats(_ world: World) {
        for (id, _) in model.floating {
            guard let floatedAt = model.windows[id]?.autoFloatedAt else { continue }
            guard world.now &- floatedAt <= autoFloatGrowOutInterval else {
                model.clearAutoFloat(id)
                continue
            }
            guard let window = world.byID[id], world.onScreen.contains(id),
                  !isBelowAutoFloatSize(window.bounds),
                  let screen = world.screen(for: window) else {
                continue
            }
            model.tile(id, in: model.activeKey(on: screen), onScreen: world.onScreen)
        }
    }

    /// The WindowServer decides which Space a window is on. A window that turns up on a different
    /// Space than its workspace was moved there in Mission Control, or its Space was removed or its
    /// display reconnected, and its workspace follows it.
    private func rehomeWindows(_ world: World) {
        for (id, deadline) in relocating {
            // Displays can share one Space, so arriving means being on the destination display.
            let hasArrived = model.workspace(of: id).map { key in
                world.byID[id].flatMap { world.screen(for: $0) }?.scope == key.scope
            } ?? true
            if hasArrived || world.now >= deadline {
                relocating.removeValue(forKey: id)
            }
        }
        var moves: [(id: WindowID, from: WorkspaceKey, to: ScreenInfo)] = []
        // While a button is down a window on another display is most likely being dragged there,
        // and the drop decides where it goes. Letting go triggers a reconcile.
        for (key, state) in isPointerButtonDown ? [:] : model.trees {
            for id in state.orderedIDs {
                guard let window = world.byID[id],
                      world.onScreen.contains(id),
                      !world.shared.contains(id),
                      !dragged.contains(id),
                      relocating[id] == nil,
                      slide?.contains(id) != true,
                      let screen = world.screen(for: window),
                      screen.scope != key.scope else {
                    continue
                }
                // A parked window hangs off the corner of its display and can overlap the next
                // one, which is not a move. Only a visible window can really change display.
                guard model.isShowing(key) || screen.key == key.display else { continue }
                moves.append((id, key, screen))
            }
        }
        for move in moves {
            let scope = move.to.scope
            let isNewScope = !model.hasState(in: scope)
            if isNewScope {
                // The whole Space was replaced: carry over which workspace was showing.
                model.setActiveIndex(model.activeIndex(in: move.from.scope), in: scope)
            }
            let index = model.isShowing(move.from) && !isNewScope ? model.activeIndex(in: scope) : move.from.index
            model.move(move.id, to: WorkspaceKey(scope: scope, index: index), onScreen: world.onScreen)
        }
        for (id, scope) in model.floating {
            guard let window = world.byID[id], world.onScreen.contains(id),
                  let screen = world.screen(for: window), screen.scope != scope else {
                continue
            }
            model.setFloatingScope(screen.scope, of: id)
        }
    }

    // MARK: - Focus

    /// The managed window in front, read from the window order: the topmost window of the front app.
    private func frontWindow(_ world: World) -> WindowID? {
        guard let pid = server.frontmostPID() else { return nil }
        // One candidate per display: the front app's topmost managed window there.
        var seenSpaces: Set<UInt64> = []
        var topmost: [WindowID] = []
        for window in world.windows
            where window.pid == pid && world.onScreen.contains(window.id) && model.isManaged(window.id) {
            if seenSpaces.insert(window.space).inserted {
                topmost.append(window.id)
            }
        }
        if topmost.count > 1, let reported = accessibilityFocus[pid], topmost.contains(reported) {
            return reported
        }
        return topmost.first
    }

    private func updateFocus(_ world: World) {
        let front = frontWindow(world)
        if let intent = focusIntent, front == intent.window || world.now >= intent.deadline {
            focusIntent = nil
        }
        if let front, front != observedFocus {
            selectedEmptyScreen = nil
        }
        focusedWindow = focusIntent?.window ?? front
        if let focusedWindow {
            model.markFocused(focusedWindow)
        }
        // Focus arriving on a parked window (Cmd-Tab, a Dock click, a notification) brings its
        // workspace along instead of leaving the keyboard in a window nobody can see.
        // Only when focus left a window that is still there. When that window closed or was
        // minimized, macOS hands focus to the app's next window, and nobody asked to go to it.
        if focusIntent == nil, slide == nil, let front, front != observedFocus,
           let previous = observedFocus, world.onScreen.contains(previous),
           let key = model.workspace(of: front), !model.isShowing(key),
           let screen = world.screen(for: key.scope) {
            // This runs inside a reconcile, which goes on to lay out the workspace it just showed.
            showWorkspace(key.index, on: screen, world, directionHint: nil, focusing: false, applying: false)
        }
        // A launcher or MacPane's own Settings taking focus for a moment leaves this alone, so
        // focus falling back to a parked window afterwards does not count as arriving there.
        if let front {
            observedFocus = front
        }
    }

    private func focus(_ id: WindowID) {
        guard let window = model.windows[id] else { return }
        selectedEmptyScreen = nil
        focusIntent = (id, PerformanceTrace.now() + focusIntentDuration)
        focusedWindow = id
        model.markFocused(id)
        let application = application(for: window.pid)
        if settings.fastFocusEnabled, server.focus(pid: window.pid, window: id) {
            application.raise(window.handle)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid,
           let running = NSRunningApplication(processIdentifier: window.pid) {
            if #available(macOS 14.0, *) {
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }
        application.focusThroughAccessibility(window.handle)
    }

    // MARK: - Frames

    private var isPointerButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) ||
            CGEventSource.buttonState(.combinedSessionState, button: .center)
    }

    private func convergeFrames(_ world: World) {
        let pointerDown = isPointerButtonDown
        let placements = model.placements(
            screens: world.screens,
            onScreen: world.onScreen,
            gap: CGFloat(settings.gapPixels)
        )
        var writes: [pid_t: [FrameWrite]] = [:]
        var learnedMinimum = false
        for (id, placement) in placements {
            guard let observed = world.byID[id]?.bounds,
                  let window = model.windows[id],
                  slide?.contains(id) != true,
                  rehandling[id] == nil else {
                continue
            }
            forgetOutgrownMinimum(of: window, observed: observed)
            let goal: FrameGoal
            switch placement {
            case .tile(let frame):
                goal = .tile(FramePlanner.sanitized(frame))
            case .parked(let screen):
                goal = .park(
                    FramePlanner.parkOrigin(
                        windowSize: observed.size,
                        screenFrame: screen.frame,
                        otherScreenFrames: world.screens.filter { $0.key != screen.key }.map(\.frame)
                    ),
                    clearing: world.screens.map(\.frame)
                )
            }
            var record = frameRecords[id]
            switch FramePlanner.decide(
                goal: goal, observed: observed, record: &record, pointerDown: pointerDown, now: world.now
            ) {
            case .none:
                break
            case .write:
                nextWriteToken += 1
                record?.pendingToken = nextWriteToken
                record?.pendingSince = world.now
                let frame: CGRect
                let setsSize: Bool
                switch goal {
                case .tile(let target):
                    frame = target
                    setsSize = true
                case .park(let origin, _):
                    frame = CGRect(origin: origin, size: observed.size)
                    setsSize = false
                }
                writes[window.pid, default: []].append(FrameWrite(
                    window: id, handle: window.handle, frame: frame, setsSize: setsSize, token: nextWriteToken
                ))
            case .settling(let until):
                scheduleWake(at: until, now: world.now)
            case .userMoved:
                dragged.insert(id)
            case .learnMinimum(let minimum):
                learnMinimum(minimum, of: id)
                learnedMinimum = true
            }
            frameRecords[id] = record
            if record?.hasConverged == true, let started = traceStarts.removeValue(forKey: id) {
                PerformanceTrace.event(
                    "window-tiled",
                    "window \(id) in \(PerformanceTrace.format(PerformanceTrace.milliseconds(since: started))) from first seen"
                )
            }
        }
        for id in frameRecords.keys where placements[id] == nil && slide?.contains(id) != true {
            frameRecords.removeValue(forKey: id)
        }
        for (pid, batch) in writes {
            application(for: pid).submit(batch)
        }
        if !writes.isEmpty {
            // The answers bring the next reconcile. This is for an answer that never comes.
            scheduleWake(after: PerformanceTrace.seconds(FramePlanner.pendingWriteTimeout) + 0.01)
        }
        if learnedMinimum {
            setNeedsReconcile()
        }
        if !dragged.isEmpty {
            // The pointer-up event ends a drag; this covers one that never reaches MacPane.
            scheduleWake(after: 0.5)
        }
    }

    private func handleFrameWriteOutcomes(_ outcomes: [FrameWriteOutcome]) {
        guard isRunning, !isStopping else { return }
        let now = PerformanceTrace.now()
        for outcome in outcomes where frameRecords[outcome.window]?.pendingToken == outcome.token {
            if outcome.error == .invalidUIElement {
                // The handle no longer names a window.
                frameRecords.removeValue(forKey: outcome.window)
                replaceHandle(of: outcome.window)
                continue
            }
            FramePlanner.absorb(token: outcome.token, error: outcome.error, record: &frameRecords[outcome.window], now: now)
        }
        if let started = commandStartedAt {
            commandStartedAt = nil
            PerformanceTrace.event(
                "command-frames",
                "\(outcomes.count) windows acknowledged in \(PerformanceTrace.format(PerformanceTrace.milliseconds(since: started)))"
            )
        }
        // The reconcile that follows reads what the writes did.
        setNeedsReconcile()
    }

    /// Records the size an app refused to go below. Zero in a dimension means that dimension was
    /// not limited.
    private func learnMinimum(_ minimum: CGSize, of id: WindowID) {
        guard let existing = model.windows[id]?.minimumSize else { return }
        model.setMinimumSize(
            CGSize(width: max(existing.width, minimum.width), height: max(existing.height, minimum.height)),
            of: id
        )
        PerformanceTrace.event("minimum-learned", "window \(id) \(Int(minimum.width))x\(Int(minimum.height))")
    }

    /// A window seen smaller than its recorded minimum proves the minimum wrong.
    private func forgetOutgrownMinimum(of window: ManagedWindow, observed: CGRect) {
        var minimum = window.minimumSize
        guard minimum.width > 0 || minimum.height > 0 else { return }
        let slack: CGFloat = 8
        if minimum.width > 0, observed.width < minimum.width - slack {
            minimum.width = 0
        }
        if minimum.height > 0, observed.height < minimum.height - slack {
            minimum.height = 0
        }
        if minimum != window.minimumSize {
            model.setMinimumSize(minimum, of: window.id)
        }
    }

    // MARK: - Pointer drags

    private func finishDragsIfReleased(_ world: World) {
        guard !dragged.isEmpty, !isPointerButtonDown else { return }
        let finished = dragged
        dragged.removeAll()
        for id in finished {
            finishDrag(of: id, world)
        }
    }

    private func finishDrag(of id: WindowID, _ world: World) {
        guard let window = world.byID[id],
              let key = model.workspace(of: id), model.isShowing(key),
              let state = model.trees[key], state.zoomedWindowID != id,
              let screen = world.screen(for: key.scope),
              case .tile(let target)? = frameRecords[id]?.goal else {
            return
        }
        let gap = CGFloat(settings.gapPixels)
        let hidden = model.hidden(in: key, onScreen: world.onScreen)
        // A window that settled on its own size (a terminal's cell grid, an app minimum) was not
        // resized just because it differs from its tile.
        let settledSize = (frameRecords[id]?.accepted ?? target).size
        if !FramePlanner.approximatelyEqual(window.bounds.size, settledSize) {
            // Resized: move the split the dragged edge belongs to.
            let slots = state.resolvedSlots(
                in: screen.frame, gap: gap, accommodating: model.minimumSizes(in: key), hidden: hidden
            )
            guard let rendered = slots[id] else { return }
            let observed = TileSlot.observed(from: window.bounds, in: screen.frame, gap: gap, rendered: rendered)
            let threshold = TileLayout.resizeReflectionThreshold
            guard abs(observed.x - rendered.x) > threshold || abs(observed.y - rendered.y) > threshold ||
                abs(observed.maxX - rendered.maxX) > threshold || abs(observed.maxY - rendered.maxY) > threshold else {
                return
            }
            model.edit(key) { $0.reflectResize(id, observedSlot: observed, hidden: hidden) }
            return
        }
        // Moved: drop it on the tile under the pointer, on whichever display that is.
        let cursor = ScreenCatalog.cursorLocation()
        let dropScreen = ScreenCatalog.screen(containing: cursor, in: world.screens.filter(\.isTileable)) ?? screen
        let dropKey = model.activeKey(on: dropScreen)
        // Let go inside its own tile: a nudge, not a move. The window goes back.
        guard dropKey != key || !target.contains(cursor) else { return }
        if dropKey != key {
            relocating[id] = world.now + relocationGrace
        }
        let candidates = visibleTiles(in: dropKey, world).filter { $0.id != id }
        guard let hit = WindowDropPlanner.target(cursor: cursor, movingFrame: window.bounds, candidates: candidates) else {
            if dropKey != key {
                model.move(id, to: dropKey, onScreen: world.onScreen)
            }
            return
        }
        let action = WindowDropPlanner.dropAction(cursor: cursor, targetFrame: hit.frame)
        if dropKey == key {
            let placement: TilePlacement
            switch action {
            case .swap: placement = .swap
            case .split(let direction): placement = .split(direction)
            }
            model.edit(key) { $0.move(id, onto: hit.id, placement: placement, hidden: hidden) }
        } else {
            // Swapping across displays would move a window the user never touched.
            var direction = SnapDirection.right
            if case .split(let split) = action {
                direction = split
            }
            model.move(id, to: dropKey, near: hit.id, placement: .split(direction), onScreen: world.onScreen)
        }
    }

    // MARK: - Commands

    func retileNow() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else {
            beginPermissionPolling()
            NSSound.beep()
            return
        }
        startWatching()
        frameRecords.removeAll()
        reconcile()
    }

    func handle(action: HotKeyAction) {
        guard !isStopping else { return }
        pendingWorkspaceSwitchIndicator = nil
        guard hasAccessibilityPermission(prompt: false) else {
            beginPermissionPolling()
            NSSound.beep()
            return
        }
        startWatching()
        commandStartedAt = PerformanceTrace.now()
        // Every command starts from a fresh reading rather than whatever the last event left.
        guard let world = reconcile(), isSettled(world) else {
            NSSound.beep()
            return
        }
        switch action {
        case .focus(let direction):
            focusNeighbor(direction, world)
        case .swap(let direction):
            editFocusedTile(world) { state, id, hidden in
                let unzoomed = state.clearZoom()
                return state.swap(id, direction: direction, hidden: hidden) || unzoomed
            }
        case .resize(let direction):
            editFocusedTile(world) { state, id, hidden in
                let unzoomed = state.clearZoom()
                return state.resize(id, direction: direction, hidden: hidden) || unzoomed
            }
        case .toggleOrientation:
            editFocusedTile(world) { state, id, hidden in
                let unzoomed = state.clearZoom()
                return state.toggleOrientation(id, hidden: hidden) || unzoomed
            }
        case .balance:
            editFocusedTile(world) { state, _, _ in
                state.clearZoom()
                state.balance()
                return true
            }
        case .toggleZoom:
            if let tile = editFocusedTile(world, { state, id, _ in state.toggleZoom(id) }) {
                focus(tile)
            }
        case .toggleFloating:
            toggleFocusedFloating(world)
        case .toggleTiling:
            toggleTiling()
        case .toggleWorkspaceSwitchAnimations:
            toggleWorkspaceSwitchAnimations()
        case .retile:
            retileNow()
        case .createWorkspace:
            createWorkspace(world)
        case .deleteWorkspace:
            deleteCurrentWorkspace(world)
        case .switchWorkspace(let index):
            switchWorkspace(to: settings.availableWorkspaceIndex(index), world, directionHint: nil)
        case .cycleWorkspace(let delta):
            let current = currentScreen(world).map { model.activeIndex(in: $0.scope) } ?? 0
            switchWorkspace(to: settings.wrappedWorkspaceIndex(current + delta), world, directionHint: delta)
        case .moveWindowToWorkspace(let index):
            moveWindowToWorkspace(index: index, displayID: nil, window: nil, world)
        case .moveWindowToWorkspaceOnDisplay(let index, let displayID, let window):
            moveWindowToWorkspace(index: index, displayID: displayID, window: window, world)
        case .showWorkspaceOverview, .hideWorkspaceOverview, .overviewSwitchWorkspace, .overviewRenameStart,
             .pickerSelectMonitor, .hideMonitorPicker, .openSettings, .decreaseGap, .increaseGap, .resetGap:
            break
        }
    }

    func consumeWorkspaceSwitchIndicator() -> WorkspaceSwitchIndicatorState? {
        defer { pendingWorkspaceSwitchIndicator = nil }
        return pendingWorkspaceSwitchIndicator
    }

    /// The window a command acts on: the focused one, or with nothing managed in front, the last
    /// focused tile of the workspace the pointer is over.
    private func commandWindow(_ world: World) -> WindowID? {
        guard selectedEmptyScreen == nil else { return nil }
        if let focusedWindow, world.onScreen.contains(focusedWindow),
           model.workspace(of: focusedWindow).map(model.isShowing) ?? model.isManaged(focusedWindow) {
            return focusedWindow
        }
        if let screen = currentScreen(world) {
            let key = model.activeKey(on: screen)
            if let target = model.trees[key]?.focusTarget(hidden: model.hidden(in: key, onScreen: world.onScreen)) {
                return target
            }
        }
        return nil
    }

    /// The display a workspace command applies to.
    private func currentScreen(_ world: World) -> ScreenInfo? {
        if let selectedEmptyScreen, let screen = world.screen(forDisplay: selectedEmptyScreen.key) {
            return screen
        }
        if let focusedWindow, let window = world.byID[focusedWindow] {
            if let key = model.workspace(of: focusedWindow), let screen = world.screen(for: key.scope) {
                return screen
            }
            if model.isManaged(focusedWindow), let screen = world.screen(for: window) {
                return screen
            }
        }
        return ScreenCatalog.screen(containing: ScreenCatalog.cursorLocation(), in: world.screens)
            ?? world.screens.first
    }

    /// The tiled windows showing in a workspace, with their current frames.
    private func visibleTiles(in key: WorkspaceKey, _ world: World) -> [(id: WindowID, frame: CGRect)] {
        (model.trees[key]?.orderedIDs ?? []).compactMap { id in
            guard world.onScreen.contains(id), let window = world.byID[id] else { return nil }
            return (id, window.bounds)
        }
    }

    /// Every managed window showing on a display: its visible tiles and its floating windows.
    private func visibleWindows(on screen: ScreenInfo, _ world: World) -> [(id: WindowID, frame: CGRect)] {
        var windows = visibleTiles(in: model.activeKey(on: screen), world)
        for (id, scope) in model.floating where scope == screen.scope {
            guard world.onScreen.contains(id), let window = world.byID[id] else { continue }
            windows.append((id, window.bounds))
        }
        return windows
    }

    /// Edits the tree of the focused tile and applies the result. Returns the tile on success.
    @discardableResult
    private func editFocusedTile(
        _ world: World,
        _ body: (inout ScreenTileState, WindowID, Set<WindowID>) -> Bool
    ) -> WindowID? {
        guard let id = commandWindow(world), let key = model.workspace(of: id), model.isShowing(key) else {
            NSSound.beep()
            return nil
        }
        finishSlideImmediately()
        let hidden = model.hidden(in: key, onScreen: world.onScreen)
        guard model.edit(key, { body(&$0, id, hidden) }) else { return nil }
        reconcile()
        return id
    }

    private func focusNeighbor(_ direction: SnapDirection, _ world: World) {
        if let selectedEmptyScreen, let screen = world.screen(forDisplay: selectedEmptyScreen.key) {
            focusAcrossDisplays(from: screen, sourceFrame: screen.bounds, direction, world)
            return
        }
        guard let id = commandWindow(world), let window = world.byID[id] else {
            NSSound.beep()
            return
        }
        let key = model.workspace(of: id)
        var target: WindowID?
        if let key, let state = model.trees[key] {
            target = state.neighborID(
                from: id, direction: direction, hidden: model.hidden(in: key, onScreen: world.onScreen)
            )
        }
        let screen = key.flatMap { world.screen(for: $0.scope) } ?? world.screen(for: window)
        if target == nil, let screen {
            target = WindowFocusNavigator.neighbor(
                of: window.bounds,
                direction: direction,
                among: visibleWindows(on: screen, world).filter { $0.id != id }
            )
        }
        if let target {
            // Leaving a zoomed window puts its workspace back to tiles.
            if let key, model.edit(key, { $0.clearZoom() }) {
                reconcile()
            }
            focus(target)
            return
        }
        if let screen {
            focusAcrossDisplays(from: screen, sourceFrame: window.bounds, direction, world)
        }
    }

    private func focusAcrossDisplays(
        from screen: ScreenInfo,
        sourceFrame: CGRect,
        _ direction: SnapDirection,
        _ world: World
    ) {
        // The edge of the outermost display is simply where focus stops.
        guard let adjacent = WindowFocusNavigator.adjacentScreen(
            to: screen, direction: direction, screens: world.screens.filter(\.isTileable)
        ) else {
            return
        }
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: model.activeIndex(in: adjacent.scope),
            displayID: adjacent.displayID
        )
        if let target = WindowFocusNavigator.entryWindow(
            from: sourceFrame, direction: direction, among: visibleWindows(on: adjacent, world)
        ) {
            focus(target)
            return
        }
        selectedEmptyScreen = (adjacent.key, observedFocus)
        CGWarpMouseCursorPosition(CGPoint(x: adjacent.frame.midX, y: adjacent.frame.midY))
        // Without this the pointer stays frozen for a quarter of a second after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func toggleFocusedFloating(_ world: World) {
        guard let id = focusedWindow, model.isManaged(id), let window = world.byID[id], world.onScreen.contains(id) else {
            NSSound.beep()
            return
        }
        finishSlideImmediately()
        if model.floating[id] != nil {
            guard let screen = world.screen(for: window) else { return }
            model.tile(id, in: model.activeKey(on: screen), onScreen: world.onScreen)
        } else if let key = model.workspace(of: id) {
            model.float(id, in: key.scope)
        }
        reconcile()
    }

    private func toggleTiling() {
        finishSlideImmediately()
        settings.toggleTiling()
        if tilingEnabled {
            frameRecords.removeAll()
            reconcile()
        } else {
            cancelPendingWrites()
        }
    }

    private func toggleWorkspaceSwitchAnimations() {
        if workspaceSwitchAnimationsEnabled {
            finishSlideImmediately()
        }
        settings.toggleWorkspaceSwitchAnimations()
    }

    // MARK: - Workspaces

    private func switchWorkspace(to index: Int?, _ world: World, directionHint: Int?) {
        guard let index, let screen = currentScreen(world), screen.isTileable else {
            NSSound.beep()
            return
        }
        showWorkspace(index, on: screen, world, directionHint: directionHint, focusing: true)
    }

    /// Switches a display to another virtual workspace on its current Space.
    func switchWorkspace(to index: Int, onDisplay displayID: CGDirectDisplayID?) {
        guard !isStopping, let world = reconcile(), isSettled(world),
              let index = settings.availableWorkspaceIndex(index),
              let screen = world.screens.first(where: { $0.displayID == displayID }) ?? currentScreen(world),
              screen.isTileable else {
            NSSound.beep()
            return
        }
        pendingWorkspaceSwitchIndicator = nil
        showWorkspace(index, on: screen, world, directionHint: nil, focusing: true)
    }

    private func showWorkspace(
        _ index: Int,
        on screen: ScreenInfo,
        _ world: World,
        directionHint: Int?,
        focusing: Bool,
        applying: Bool = true
    ) {
        let scope = screen.scope
        let previous = model.activeIndex(in: scope)
        guard index != previous else { return }
        model.setActiveIndex(index, in: scope)
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: index,
            displayID: screen.displayID
        )
        let direction = WorkspaceSlidePlanner.direction(from: previous, to: index, hint: directionHint)
        let isSliding = slideWorkspace(from: previous, to: index, on: screen, world, direction: direction)
        if focusing {
            let key = WorkspaceKey(scope: scope, index: index)
            if let target = model.trees[key]?.focusTarget(hidden: model.hidden(in: key, onScreen: world.onScreen)) {
                focus(target)
            }
        }
        if !isSliding, applying {
            reconcile()
        }
    }

    private func createWorkspace(_ world: World) {
        guard workspaceCount < settings.maximumWorkspaceCount, let screen = currentScreen(world), screen.isTileable else {
            NSSound.beep()
            return
        }
        finishSlideImmediately()
        let index = workspaceCount
        settings.setWorkspaceCount(index + 1)
        model.setActiveIndex(index, in: screen.scope)
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: index,
            displayID: screen.displayID
        )
        reconcile()
    }

    private func deleteCurrentWorkspace(_ world: World) {
        guard let screen = currentScreen(world) else {
            NSSound.beep()
            return
        }
        let index = model.activeIndex(in: screen.scope)
        guard model.deletionBlockReason(index: index, workspaceCount: workspaceCount) == nil else {
            NSSound.beep()
            return
        }
        finishSlideImmediately()
        model.deleteWorkspace(index: index, workspaceCount: workspaceCount)
        settings.shiftWorkspaceNames(deletingWorkspaceIndex: index)
        settings.setWorkspaceCount(workspaceCount - 1)
        let key = model.activeKey(on: screen)
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: key.index,
            displayID: screen.displayID
        )
        if let target = model.trees[key]?.focusTarget(hidden: model.hidden(in: key, onScreen: world.onScreen)) {
            focus(target)
        }
        reconcile()
    }

    private func moveWindowToWorkspace(
        index: Int,
        displayID: CGDirectDisplayID?,
        window preferred: WindowID?,
        _ world: World
    ) {
        guard let index = settings.availableWorkspaceIndex(index),
              let id = preferred.flatMap({ model.workspace(of: $0) != nil ? $0 : nil }) ?? commandWindow(world),
              let sourceKey = model.workspace(of: id),
              let sourceScreen = world.screen(for: sourceKey.scope) else {
            NSSound.beep()
            return
        }
        let targetScreen = displayID.flatMap { id in world.screens.first { $0.displayID == id } } ?? sourceScreen
        guard targetScreen.isTileable else {
            NSSound.beep()
            return
        }
        let targetKey = targetScreen.workspaceKey(index: index)
        guard targetKey != sourceKey else { return }
        finishSlideImmediately()
        model.move(id, to: targetKey, onScreen: world.onScreen)
        if targetScreen.key != sourceScreen.key {
            relocating[id] = world.now + relocationGrace
            if model.isShowing(targetKey) {
                pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
                    workspaceIndex: index,
                    displayID: targetScreen.displayID
                )
            }
        }
        if model.isShowing(targetKey) {
            focus(id)
        } else if let next = model.trees[sourceKey]?.focusTarget(
            hidden: model.hidden(in: sourceKey, onScreen: world.onScreen)
        ) {
            focus(next)
        }
        reconcile()
    }

    struct MonitorMoveRequest {
        let windowID: WindowID
        let sourceDisplayID: CGDirectDisplayID?
    }

    /// The tiled window a "move to workspace" shortcut would act on, and the display it is on.
    func monitorMoveRequest() -> MonitorMoveRequest? {
        guard !isStopping, let world = reconcile(), isSettled(world),
              let id = commandWindow(world),
              let key = model.workspace(of: id) else {
            return nil
        }
        return MonitorMoveRequest(windowID: id, sourceDisplayID: world.screen(for: key.scope)?.displayID)
    }

    // MARK: - Workspace slide

    private func slideWorkspace(
        from previous: Int,
        to index: Int,
        on screen: ScreenInfo,
        _ world: World,
        direction: WorkspaceSlideDirection
    ) -> Bool {
        guard tilingEnabled, workspaceSwitchAnimationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishSlideImmediately()
            return false
        }
        let targetKey = WorkspaceKey(scope: screen.scope, index: index)
        let hidden = model.hidden(in: targetKey, onScreen: world.onScreen)
        let targetState = model.trees[targetKey]
        let targetFrames = targetState?.frames(
            in: screen.frame,
            gap: CGFloat(settings.gapPixels),
            accommodating: model.minimumSizes(in: targetKey),
            hidden: hidden
        ) ?? [:]
        let incoming = (targetState?.orderedIDs ?? []).compactMap { id in
            targetFrames[id].map { (id: id, frame: $0) }
        }

        if let chain = slide, chain.scope == screen.scope, let animator = chain.animator {
            // A slide is already running on this display: bend it towards the new target instead of
            // stopping and starting again.
            let progress = animator.currentProgress
            var origins: [WindowID: CGPoint] = [:]
            for transition in chain.transitions {
                origins[transition.window] = WorkspaceSlidePlanner.interpolatedOrigin(
                    from: transition.startFrame, to: transition.endFrame, progress: progress
                )
            }
            let transitions = WorkspaceSlidePlanner.chainedTransitions(
                previous: chain.transitions,
                currentOrigins: origins,
                incoming: incoming,
                screen: screen,
                direction: direction,
                screens: world.screens
            )
            guard !transitions.isEmpty, transitions.count <= WorkspaceSlidePlanner.maximumTransitionCount else {
                finishSlideImmediately()
                return false
            }
            chain.transitions = transitions
            applySlideInitialFrames(transitions)
            animator.reseat(progress: 0, duration: workspaceSlideChainedDuration)
            return true
        }

        finishSlideImmediately()
        let transitions = WorkspaceSlidePlanner.transitions(
            outgoing: visibleTiles(in: WorkspaceKey(scope: screen.scope, index: previous), world),
            incoming: incoming,
            screen: screen,
            direction: direction,
            screens: world.screens
        )
        guard !transitions.isEmpty, transitions.count <= WorkspaceSlidePlanner.maximumTransitionCount else {
            return false
        }
        let chain = SlideChain(scope: screen.scope, transitions: transitions)
        slide = chain
        applySlideInitialFrames(transitions)
        let nsScreen = ScreenCatalog.nsScreen(for: screen)
        let animator = WorkspaceSlideAnimator(
            duration: workspaceSlideAnimationDuration,
            frameRate: max(nsScreen?.maximumFramesPerSecond ?? 60, 60),
            screen: nsScreen,
            shouldContinue: { [weak self, weak chain] in
                guard let self, let chain else { return false }
                return !self.isStopping && self.slide === chain
            },
            onFrame: { [weak self, weak chain] progress in
                guard let self, let chain, self.slide === chain else { return }
                self.applySlideStep(chain, progress: progress)
            },
            onFinish: { [weak self, weak chain] in
                guard let self, let chain, self.slide === chain else { return }
                self.slide = nil
                self.reconcile()
            }
        )
        chain.animator = animator
        animator.start()
        return true
    }

    /// Incoming windows are sized and put at the edge they slide in from. The steps that follow only
    /// move them.
    private func applySlideInitialFrames(_ transitions: [WorkspaceSlideTransition]) {
        var writes: [pid_t: [FrameWrite]] = [:]
        for transition in transitions {
            frameRecords.removeValue(forKey: transition.window)
            guard transition.needsInitialFrame, let window = model.windows[transition.window] else { continue }
            writes[window.pid, default: []].append(FrameWrite(
                window: window.id, handle: window.handle, frame: transition.startFrame, setsSize: true, token: nil
            ))
        }
        for (pid, batch) in writes {
            application(for: pid).submit(batch)
        }
    }

    private func applySlideStep(_ chain: SlideChain, progress: CGFloat) {
        var writes: [pid_t: [FrameWrite]] = [:]
        for transition in chain.transitions {
            guard let window = model.windows[transition.window] else { continue }
            let origin = WorkspaceSlidePlanner.interpolatedOrigin(
                from: transition.startFrame, to: transition.endFrame, progress: progress
            )
            writes[window.pid, default: []].append(FrameWrite(
                window: window.id,
                handle: window.handle,
                frame: CGRect(origin: origin, size: transition.endFrame.size),
                setsSize: false,
                token: nil
            ))
        }
        for (pid, batch) in writes {
            application(for: pid).submit(batch)
        }
    }

    /// Jumps a running slide to its end. The reconcile it triggers puts every window on its goal.
    private func finishSlideImmediately() {
        slide?.animator?.finishImmediately()
    }

    private func cancelSlide() {
        guard let chain = slide else { return }
        slide = nil
        chain.animator?.cancel()
    }

    // MARK: - Menu and overview

    var workspaceMenuState: WorkspaceMenuState {
        let world = readWorld()
        let screen = currentScreen(world)
        let activeIndex = screen.map { model.activeIndex(in: $0.scope) }
        return WorkspaceMenuState(
            activeIndex: activeIndex,
            displayID: screen?.displayID,
            count: workspaceCount,
            maximumCount: settings.maximumWorkspaceCount,
            canDeleteActive: activeIndex.map {
                model.deletionBlockReason(index: $0, workspaceCount: workspaceCount) == nil
            } ?? false
        )
    }

    var currentDisplayID: CGDirectDisplayID? {
        currentScreen(readWorld())?.displayID
    }

    func workspaceOverview() -> WorkspaceOverview? {
        guard !isStopping, hasAccessibilityPermission(prompt: false) else { return nil }
        startWatching()
        let world = reconcile() ?? readWorld()
        guard let screen = currentScreen(world) else { return nil }
        let activeIndex = model.activeIndex(in: screen.scope)
        let gap = CGFloat(settings.gapPixels)
        let items = (0..<workspaceCount).map { index -> WorkspaceOverviewItem in
            let key = screen.workspaceKey(index: index)
            let state = model.trees[key] ?? ScreenTileState()
            let frames = state.frames(
                in: screen.frame,
                gap: gap,
                accommodating: model.minimumSizes(in: key),
                hidden: model.hidden(in: key, onScreen: world.onScreen)
            )
            let windows = state.orderedIDs.compactMap { id -> WorkspaceOverviewWindow? in
                guard let frame = frames[id], let window = model.windows[id] else { return nil }
                return overviewWindow(window, frame: frame, isFocused: id == focusedWindow || id == state.focusedWindowID)
            }
            return WorkspaceOverviewItem(
                index: index,
                name: settings.workspaceName(on: screen, index: index),
                isActive: index == activeIndex,
                screenFrame: screen.frame,
                windows: windows
            )
        }
        return WorkspaceOverview(
            displayID: screen.displayID,
            displayName: ScreenCatalog.displayName(for: screen),
            activeWorkspaceIndex: activeIndex,
            activeWorkspaceName: settings.workspaceName(on: screen, index: activeIndex),
            workspaceCount: workspaceCount,
            items: items
        )
    }

    private func overviewWindow(_ window: ManagedWindow, frame: CGRect, isFocused: Bool) -> WorkspaceOverviewWindow {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let appName = NSRunningApplication(processIdentifier: window.pid)?.localizedName
            ?? normalized(window.bundleIdentifier)
        let title = normalized(window.title) ?? appName ?? "Window \(window.id)"
        return WorkspaceOverviewWindow(
            title: title,
            detail: appName == title ? nil : appName,
            isFocused: isFocused,
            frame: FramePlanner.sanitized(frame),
            pid: window.pid
        )
    }

    /// Re-reads every managed window's title in the background. `completion` runs on the main
    /// thread and says whether any title changed.
    func refreshWindowTitles(completion: @escaping (Bool) -> Void) {
        guard isRunning, !isStopping else { return }
        var elementsByPID: [pid_t: [WindowID: WindowHandle]] = [:]
        for window in model.windows.values {
            elementsByPID[window.pid, default: [:]][window.id] = window.handle
        }
        var remaining = elementsByPID.count
        var changed = false
        guard remaining > 0 else {
            completion(false)
            return
        }
        for (pid, elements) in elementsByPID {
            application(for: pid).readTitles(elements) { [weak self] titles in
                guard let self else { return }
                for (id, title) in titles where self.model.windows[id] != nil && self.model.windows[id]?.title != title {
                    self.model.setTitle(title, of: id)
                    changed = true
                }
                remaining -= 1
                if remaining == 0 {
                    completion(changed)
                }
            }
        }
    }

    func renameWorkspace(_ index: Int, onDisplay displayID: CGDirectDisplayID?, to name: String) {
        guard !isStopping else { return }
        let world = readWorld()
        guard let screen = world.screens.first(where: { $0.displayID == displayID }) ?? currentScreen(world) else {
            NSSound.beep()
            return
        }
        settings.setWorkspaceName(name, on: screen, index: index)
    }

    // MARK: - Quit

    /// Brings every window back into view before MacPane goes away, including the ones on Spaces
    /// that are not showing.
    private func restoreWindowsBeforeStopping() {
        guard isRunning, hasAccessibilityPermission(prompt: false) else { return }
        cancelSlide()
        cancelPendingWrites()
        let world = readWorld()
        removeDepartedWindows(world)
        model.mergeAllIntoActiveWorkspaces()
        let gap = CGFloat(settings.gapPixels)
        var writes: [pid_t: [FrameWrite]] = [:]
        for (key, state) in model.trees {
            guard let screen = world.screen(forDisplay: key.display) else { continue }
            // Only the showing Space can be checked for minimized or hidden windows.
            let hidden = key.scope == screen.scope ? model.hidden(in: key, onScreen: world.onScreen) : []
            let frames = state.frames(
                in: screen.frame, gap: gap, accommodating: model.minimumSizes(in: key), hidden: hidden
            )
            for (id, frame) in frames {
                guard let window = model.windows[id] else { continue }
                let target = FramePlanner.sanitized(frame)
                // With tiling on, every tile is put right. With it off, windows stay where the user
                // left them, except any that are still parked out of view.
                if let observed = world.byID[id]?.bounds ?? server.bounds(of: id) {
                    let isInView = world.screens.contains { display in
                        let visible = observed.intersection(display.frame)
                        return !visible.isNull && visible.width * visible.height >= observed.width * observed.height / 2
                    }
                    if FramePlanner.approximatelyEqual(observed, target) || (!settings.tilingEnabled && isInView) {
                        continue
                    }
                }
                writes[window.pid, default: []].append(FrameWrite(
                    window: id, handle: window.handle, frame: target, setsSize: true, token: nil
                ))
            }
        }
        let group = DispatchGroup()
        for (pid, batch) in writes {
            let application = application(for: pid)
            application.submit(batch)
            group.enter()
            application.afterPendingWrites { group.leave() }
        }
        // Quitting waits for the windows to come back, but not for an app that has hung. The run
        // loop keeps turning meanwhile, so nothing that needs the main thread is held up.
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while group.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }
}

/// A workspace slide in progress on one display.
private final class SlideChain {
    let scope: ScopeKey
    var transitions: [WorkspaceSlideTransition]
    var animator: WorkspaceSlideAnimator?

    init(scope: ScopeKey, transitions: [WorkspaceSlideTransition]) {
        self.scope = scope
        self.transitions = transitions
    }

    func contains(_ id: WindowID) -> Bool {
        transitions.contains { $0.window == id }
    }
}
