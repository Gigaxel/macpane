import AppKit
import ApplicationServices

private let axWindowNotificationCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tiler = Unmanaged<WindowTiler>.fromOpaque(refcon).takeUnretainedValue()
    tiler.handleAXNotification(notification as String, element: element)
}

final class WindowTiler {
    private let settings = WindowTilerSettings()
    private let focusTracker = WindowFocusTracker()
    private let metadataReader = WindowMetadataReader()
    private var appObservers: [pid_t: AppObserverRegistration] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var scanTimer: Timer?
    private var pendingReconcile: DispatchWorkItem?
    private var pendingFocusRemember: DispatchWorkItem?
    private var pendingMove: DispatchWorkItem?
    private var pendingResize: DispatchWorkItem?
    private var pendingSystemUISettle: DispatchWorkItem?
    private var pendingWorkspaceSwitchApply: DispatchWorkItem?
    private var workspaceSlideAnimator: WorkspaceSlideAnimator?
    private var workspaceSwitchApplyGeneration = 0
    private var windowDiscoveryReconcileGeneration = 0
    private var managedWindowCache: (windows: [ManagedWindow], createdAt: Date)?
    private let interactiveWindowCacheDuration: TimeInterval = 0.80
    private let defaultWindowCacheDuration: TimeInterval = 0.12
    private let workspaceSwitchApplyDelay: TimeInterval = 0.045
    private let workspaceSlideAnimationDuration: TimeInterval = 0.18
    private let windowDiscoveryReconcileOffsets: [TimeInterval] = [0, 0.10, 0.28, 0.70, 1.50]
    private let accessibilityMessagingTimeout: Float = 0.15
    private let accessibilityPermissionCacheDuration: TimeInterval = 0.50
    private var cachedAccessibilityPermission: (granted: Bool, createdAt: Date)?
    private var screenStates: [String: ScreenTileState] = [:]
    private var lastAppliedWorkspaceIndexByNativeStateKey: [String: Int] = [:]
    private var lastWorkspaceSwitchContext: WorkspaceContext?
    private var shouldMigrateWorkspaceStatesAfterScreenChange = false
    private var lastKnownScreenNativeStateKeys: Set<String> = []
    private var disconnectedNativeStateKeysPendingMigration: Set<String> = []
    private var pendingWorkspaceSwitchIndicator: WorkspaceSwitchIndicatorState?
    private var frozenSystemUIScreenStates: [String: ScreenTileState]?
    private var frozenSystemUIActiveStateKeys: Set<String>?
    private var systemUISettleTracker = SystemUISettleTracker()
    private var floatingWindowIDs: Set<WindowIdentity> = []
    private var floatingWindowStateKeys: [WindowIdentity: String] = [:]
    private var identityRegistry = WindowIdentityRegistry()
    private var layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity] = [:]
    private var persistedLayoutsByStateKey: [String: PersistedScreenLayout] = [:]
    private let visibilityScanInterval: TimeInterval = 2.0
    private let observerRecoveryInterval: TimeInterval = 15.0
    private var lastVisibleWindowSignature = VisibleWindowSignature()
    private var lastSyncedVisibleWindowSignature = VisibleWindowSignature()
    private var lastAppliedFrameByWindowID: [WindowIdentity: CGRect] = [:]
    private var lastObserverRefresh = Date.distantPast
    private var knownNonObservablePIDs: Set<pid_t> = []
    private var suppressExternalChangesUntil = Date.distantPast
    private var isWatching = false
    private var isApplyingLayout = false
    private var isStopping = false
    private var screenCatalog: ScreenCatalog {
        ScreenCatalog { [settings] nativeStateKey in
            settings.activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
        }
    }

    // MARK: - Public State

    var gapPixels: Int {
        settings.gapPixels
    }
    var workspaceCount: Int {
        settings.workspaceCount
    }
    var workspaceMenuState: WorkspaceMenuState {
        let context = currentWorkspaceContext()
        let deletion = context.map {
            WorkspaceStatePlanner.deletionAvailability(
                index: $0.activeWorkspaceIndex,
                workspaceCount: workspaceCount,
                screenStates: screenStates,
                floatingWindowStateKeys: floatingWindowStateKeys
            )
        }
        return WorkspaceMenuState(
            activeIndex: context?.activeWorkspaceIndex,
            displayID: context?.screen.displayID,
            count: workspaceCount,
            maximumCount: settings.maximumWorkspaceCount,
            canDeleteActive: deletion?.canDelete ?? false,
            deleteBlockReason: deletion?.reason
        )
    }
    var currentWorkspaceIndex: Int? {
        currentWorkspaceContext()?.activeWorkspaceIndex
    }
    var currentDisplayID: CGDirectDisplayID? {
        currentWorkspaceContext()?.screen.displayID
    }
    var workspaceStatusText: String {
        workspaceMenuState.statusText
    }
    var tilingEnabled: Bool {
        settings.tilingEnabled
    }

    // MARK: - Lifecycle

    func start() {
        isStopping = false
        guard ensureAccessibilityPermission() else {
            startPermissionPolling()
            return
        }
        startWatching()
        scheduleReconcile(delay: 0.05)
    }
    func stop() {
        restoreAllWorkspacesBeforeStopping()
        isStopping = true
        cancelPendingWork()
        stopTimers()
        removeInstalledObservers()
        resetRuntimeState()
        isApplyingLayout = false
        isWatching = false
    }
    private func cancelPendingWork() {
        pendingReconcile?.cancel()
        pendingReconcile = nil
        pendingFocusRemember?.cancel()
        pendingFocusRemember = nil
        pendingMove?.cancel()
        pendingMove = nil
        pendingResize?.cancel()
        pendingResize = nil
        pendingSystemUISettle?.cancel()
        pendingSystemUISettle = nil
        pendingWorkspaceSwitchApply?.cancel()
        pendingWorkspaceSwitchApply = nil
        cancelPendingWorkspaceSlideAnimation(finalize: false)
        workspaceSwitchApplyGeneration += 1
        windowDiscoveryReconcileGeneration += 1
        managedWindowCache = nil
        cachedAccessibilityPermission = nil
    }
    private func stopTimers() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        scanTimer?.invalidate()
        scanTimer = nil
    }
    private func removeInstalledObservers() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for pid in Array(appObservers.keys) {
            removeObserver(for: pid)
        }
    }
    private func resetRuntimeState() {
        screenStates.removeAll()
        settings.resetRuntimeState()
        lastAppliedWorkspaceIndexByNativeStateKey.removeAll()
        lastWorkspaceSwitchContext = nil
        shouldMigrateWorkspaceStatesAfterScreenChange = false
        lastKnownScreenNativeStateKeys.removeAll()
        disconnectedNativeStateKeysPendingMigration.removeAll()
        pendingWorkspaceSwitchIndicator = nil
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        systemUISettleTracker.resetSnapshotStability()
        floatingWindowIDs.removeAll()
        floatingWindowStateKeys.removeAll()
        layoutIdentityByWindowID.removeAll()
        persistedLayoutsByStateKey.removeAll()
        lastVisibleWindowSignature = VisibleWindowSignature()
        lastSyncedVisibleWindowSignature = VisibleWindowSignature()
        lastAppliedFrameByWindowID.removeAll()
        focusTracker.reset()
        lastObserverRefresh = Date.distantPast
        knownNonObservablePIDs.removeAll()
    }
    private func restoreAllWorkspacesBeforeStopping() {
        guard hasAccessibilityPermission(prompt: false) else { return }
        cancelPendingWorkspaceSwitchApply()
        refreshAppObservers()
        var allWindows = managedWindows()
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows, respectingTilingEnabled: false), focusedID: focusedID)
        let migratedAfterScreenChange = migrateWorkspaceStatesAfterScreenChangeIfNeeded(
            windows: allWindows,
            focusedID: focusedID
        )
        if migratedAfterScreenChange {
            invalidateManagedWindowCache(clearAppliedFrames: true)
            allWindows = managedWindows()
            syncStates(with: tiledWindows(from: allWindows, respectingTilingEnabled: false), focusedID: focusedID)
        }
        pruneScreenStatesForVisibleWindows(Set(allWindows.map(\.id)))
        let mergedWorkspaces = mergeAllWorkspaceStatesIntoActiveWorkspaces(focusedID: focusedID)
        guard migratedAfterScreenChange || mergedWorkspaces else { return }
        invalidateManagedWindowCache(clearAppliedFrames: true)
        allWindows = managedWindows()
        applyLayout(to: allWindows, respectingTilingEnabled: false)
        if let focusedID,
           let focusedWindow = allWindows.first(where: { $0.id == focusedID }) {
            focus(window: focusedWindow, updateTreeFocus: true)
        }
    }

    // MARK: - Accessibility Permission

    func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let now = Date()
        if !prompt, let cachedAccessibilityPermission,
           now.timeIntervalSince(cachedAccessibilityPermission.createdAt) <= accessibilityPermissionCacheDuration {
            return cachedAccessibilityPermission.granted
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        cachedAccessibilityPermission = (granted, now)
        return granted
    }
    func requestAccessibilityPermission() -> Bool {
        settings.markAccessibilityPrompted()
        cachedAccessibilityPermission = nil
        return hasAccessibilityPermission(prompt: true)
    }

    // MARK: - Commands

    func retileNow() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else {
            startPermissionPolling()
            NSSound.beep()
            return
        }
        startWatching(refreshIfAlreadyWatching: true)
        reconcileAndApplyLayout()
    }
    func handle(action: HotKeyAction) {
        guard !isStopping else { return }
        pendingWorkspaceSwitchIndicator = nil
        guard hasAccessibilityPermission(prompt: false) else {
            startPermissionPolling()
            NSSound.beep()
            return
        }
        startWatching()
        switch action {
        case .focus(let direction):
            focusNeighbor(direction: direction)
        case .swap(let direction):
            swapFocusedWindow(direction: direction)
        case .resize(let direction):
            resizeFocusedWindow(direction: direction)
        case .createWorkspace:
            createVirtualWorkspace()
        case .deleteWorkspace:
            deleteCurrentVirtualWorkspace()
        case .switchWorkspace(let index):
            switchVirtualWorkspace(to: index)
        case .moveWindowToWorkspace(let index):
            moveFocusedWindowToWorkspace(index: index)
        case .cycleWorkspace(let delta):
            cycleVirtualWorkspace(by: delta)
        case .showWorkspaceOverview:
            break
        case .hideWorkspaceOverview,
             .overviewSwitchWorkspace,
             .overviewRenameStart:
            break
        case .toggleOrientation:
            toggleFocusedSplitOrientation()
        case .toggleFloating:
            toggleFocusedFloating()
        case .toggleTiling:
            toggleTiling()
        case .balance:
            balanceFocusedTree()
        case .retile:
            retileNow()
        }
    }
    func consumeWorkspaceSwitchIndicator() -> WorkspaceSwitchIndicatorState? {
        defer { pendingWorkspaceSwitchIndicator = nil }
        return pendingWorkspaceSwitchIndicator
    }
    func adjustGap(by delta: Int) {
        guard !isStopping else { return }
        setGap(gapPixels + delta)
    }
    func setGap(_ value: Int) {
        guard !isStopping else { return }
        settings.setGap(value)
        scheduleReconcile(delay: 0.01)
    }
    func workspaceOverview() -> WorkspaceOverview? {
        guard !isStopping else { return nil }
        guard hasAccessibilityPermission(prompt: false) else { return nil }
        startWatching()
        var allWindows = managedWindows()
        var focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        if migrateWorkspaceStatesAfterScreenChangeIfNeeded(windows: allWindows, focusedID: focusedID) {
            invalidateManagedWindowCache(clearAppliedFrames: true)
            allWindows = managedWindows()
            focusedID = focusTracker.focusedWindowID(in: allWindows)
            syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        }
        guard let context = currentWorkspaceContext(windows: allWindows, focusedID: focusedID) else {
            return nil
        }
        let windowsByID = Dictionary(allWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = (0..<workspaceCount).map { index in
            let stateKey = ScreenInfo.workspaceStateKey(nativeStateKey: context.nativeStateKey, workspaceIndex: index)
            let state = screenStates[stateKey]
            let windows = (state?.slotList ?? []).map { item in
                overviewWindow(
                    for: item.id,
                    stateFocusedID: state?.focusedWindowID,
                    focusedID: focusedID,
                    windowsByID: windowsByID
                )
            }
            return WorkspaceOverviewItem(
                index: index,
                name: settings.workspaceName(forNativeStateKey: context.nativeStateKey, workspaceIndex: index),
                isActive: index == context.activeWorkspaceIndex,
                windows: windows
            )
        }
        return WorkspaceOverview(
            displayID: context.screen.displayID,
            displayName: displayName(for: context.screen),
            activeWorkspaceIndex: context.activeWorkspaceIndex,
            activeWorkspaceName: settings.workspaceName(
                forNativeStateKey: context.nativeStateKey,
                workspaceIndex: context.activeWorkspaceIndex
            ),
            workspaceCount: workspaceCount,
            items: items
        )
    }
    func renameActiveWorkspace(to name: String) {
        guard !isStopping else { return }
        guard let context = currentWorkspaceContext() else {
            NSSound.beep()
            return
        }
        settings.setWorkspaceName(name, forNativeStateKey: context.nativeStateKey, workspaceIndex: context.activeWorkspaceIndex)
    }
    func handleAXNotification(_ notification: String, element: AXUIElement) {
        guard !isStopping, !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            invalidateManagedWindowCache(clearAppliedFrames: true)
            refreshWindowNotificationRegistrations()
            scheduleWindowDiscoveryReconcileBurst(initialDelay: 0.025)
        case kAXUIElementDestroyedNotification:
            invalidateManagedWindowCache(clearAppliedFrames: true)
            removeFloatingWindowID(forDestroyedElement: element)
            scheduleReconcile(delay: 0.015)
        case kAXFocusedWindowChangedNotification,
             kAXApplicationActivatedNotification,
             kAXMainWindowChangedNotification:
            guard !isApplyingLayout, !isSuppressingExternalChanges else { return }
            scheduleFocusRemember(delay: 0.01)
        case kAXMovedNotification:
            guard !isApplyingLayout, !isSuppressingExternalChanges else { return }
            invalidateManagedWindowCache(clearAppliedFrames: true)
            scheduleExternalMove(element: element, userInitiated: isPointerButtonDown)
        case kAXResizedNotification:
            guard !isApplyingLayout, !isSuppressingExternalChanges else { return }
            invalidateManagedWindowCache(clearAppliedFrames: true)
            scheduleExternalResize(element: element, userInitiated: isPointerButtonDown)
        default:
            break
        }
    }
    private func ensureAccessibilityPermission() -> Bool {
        if hasAccessibilityPermission(prompt: false) { return true }
        guard !settings.hasPromptedForAccessibilityPermission else {
            return false
        }
        return requestAccessibilityPermission()
    }

    // MARK: - Observation

    private func startPermissionPolling() {
        guard !isStopping else { return }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard !self.isStopping else {
                timer.invalidate()
                return
            }
            guard self.hasAccessibilityPermission(prompt: false) else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.startWatching()
            self.scheduleReconcile(delay: 0.05)
        }
    }
    private func startWatching(refreshIfAlreadyWatching: Bool = false) {
        guard !isStopping else { return }
        guard !isWatching else {
            if refreshIfAlreadyWatching {
                refreshAppObservers()
            }
            return
        }
        isWatching = true
        refreshAppObservers()
        lastKnownScreenNativeStateKeys = Set(currentScreenInfos().map(\.nativeStateKey))
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: WindowSnapshotReader.readOnScreenWindows())
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAppObservers()
            self?.scheduleWindowDiscoveryReconcileBurst(initialDelay: 0.06)
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAppObservers()
            self?.scheduleReconcile(delay: 0.04)
        })
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordScreenParameterChangeForWorkspaceMigration()
            self?.pauseLayoutForSystemUI(duration: 1.20, preserveLayout: true)
            self?.scheduleReconcile(delay: 1.35)
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: visibilityScanInterval, repeats: true) { [weak self] _ in
            self?.performPeriodicVisibilityScan()
        }
        scanTimer?.tolerance = visibilityScanInterval * 0.25
    }
    private func recordScreenParameterChangeForWorkspaceMigration() {
        let currentNativeStateKeys = Set(currentScreenInfos().map(\.nativeStateKey))
        if !lastKnownScreenNativeStateKeys.isEmpty {
            disconnectedNativeStateKeysPendingMigration.formUnion(
                lastKnownScreenNativeStateKeys.subtracting(currentNativeStateKeys)
            )
        }
        lastKnownScreenNativeStateKeys = currentNativeStateKeys
        shouldMigrateWorkspaceStatesAfterScreenChange = true
    }
    private func refreshAppObservers() {
        guard !isStopping else { return }
        let allRunningApps = NSWorkspace.shared.runningApplications
        let runningApps = allRunningApps.filter(metadataReader.isObservableApp)
        let runningPIDs = Set(runningApps.map(\.processIdentifier))
        knownNonObservablePIDs = Set(allRunningApps.map(\.processIdentifier)).subtracting(runningPIDs)
        let stalePIDs = Set(appObservers.keys).subtracting(runningPIDs)
        for pid in stalePIDs {
            removeObserver(for: pid)
        }
        removeFloatingWindowIDs(forTerminatedPIDs: stalePIDs)
        for app in runningApps where appObservers[app.processIdentifier] == nil {
            installObserver(for: app)
        }
        refreshWindowNotificationRegistrations()
        lastObserverRefresh = Date()
    }
    private func installObserver(for app: NSRunningApplication) {
        guard !isStopping else { return }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
        var observer: AXObserver?
        guard AXObserverCreate(pid, axWindowNotificationCallback, &observer) == .success,
              let observer else {
            return
        }
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let appNotifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification,
            kAXMainWindowChangedNotification
        ]
        var registeredAnyNotification = false
        for notification in appNotifications {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered {
                registeredAnyNotification = true
            }
        }
        guard registeredAnyNotification else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        appObservers[pid] = AppObserverRegistration(observer: observer, source: source)
        registerWindowNotifications(for: app)
    }
    private func refreshWindowNotificationRegistrations() {
        guard !isStopping else { return }
        for app in NSWorkspace.shared.runningApplications.filter(metadataReader.isObservableApp) {
            registerWindowNotifications(for: app)
        }
    }
    private func registerWindowNotifications(for app: NSRunningApplication) {
        guard !isStopping else { return }
        guard let registration = appObservers[app.processIdentifier] else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
        let windows = AXReader.elements(appElement, attribute: kAXWindowsAttribute)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for (index, window) in windows.enumerated() {
            let token = metadataReader.notificationToken(for: window, fallbackIndex: index)
            guard !registration.observedWindowTokens.contains(token) else { continue }
            var registered = false
            for notification in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                let error = AXObserverAddNotification(registration.observer, window, notification as CFString, refcon)
                if error == .success || error == .notificationAlreadyRegistered {
                    registered = true
                }
            }
            if registered {
                registration.observedWindowTokens.insert(token)
            }
        }
    }
    private func removeObserver(for pid: pid_t) {
        guard let registration = appObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .defaultMode)
    }
    private func scheduleReconcile(delay: TimeInterval) {
        guard !isStopping else { return }
        pendingReconcile?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.reconcileAndApplyLayout()
        }
        pendingReconcile = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    private func scheduleWindowDiscoveryReconcileBurst(initialDelay: TimeInterval) {
        guard !isStopping else { return }
        windowDiscoveryReconcileGeneration += 1
        let generation = windowDiscoveryReconcileGeneration
        for offset in windowDiscoveryReconcileOffsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay + offset) { [weak self] in
                guard let self,
                      !self.isStopping,
                      self.windowDiscoveryReconcileGeneration == generation else {
                    return
                }
                // Some apps publish a new window before it appears in CGWindowList or
                // before the AX element accepts frame writes, so retry through settle.
                self.invalidateManagedWindowCache(clearAppliedFrames: false)
                self.scheduleReconcile(delay: 0)
            }
        }
    }
    private func scheduleReconcileIfWindowSetChanged(delay: TimeInterval) {
        guard !isStopping, tilingEnabled, frozenSystemUIScreenStates == nil, !shouldPauseLayoutForSystemUI() else { return }
        let windows = tiledWindows(from: managedWindows())
        guard hasWindowSetChanged(windows) else { return }
        scheduleReconcile(delay: delay)
    }
    // Recovery polling should stay cheap; AX/workspace notifications are the primary update path.
    private func performPeriodicVisibilityScan() {
        guard !isStopping, tilingEnabled, frozenSystemUIScreenStates == nil else { return }
        guard !systemUISettleTracker.isPaused else { return }
        let snapshot = WindowSnapshotReader.readOnScreenWindows()
        refreshAppObserversIfNeeded(visiblePIDs: Set(snapshot.visibleNumbersByPID.keys))
        scheduleReconcileIfVisibleWindowSetChanged(snapshot: snapshot, delay: 0.01)
    }
    private func refreshAppObserversIfNeeded(visiblePIDs: Set<pid_t>) {
        let observedPIDs = Set(appObservers.keys)
        let visibleObservableCandidates = visiblePIDs.subtracting(knownNonObservablePIDs)
        let hasUnobservedVisibleApp = !visibleObservableCandidates.isSubset(of: observedPIDs)
        let shouldRunRecoveryRefresh = Date().timeIntervalSince(lastObserverRefresh) >= observerRecoveryInterval
        guard hasUnobservedVisibleApp || shouldRunRecoveryRefresh else { return }
        refreshAppObservers()
        if shouldRunRecoveryRefresh {
            scheduleReconcileIfWindowSetChanged(delay: 0.01)
        }
    }
    private func scheduleReconcileIfVisibleWindowSetChanged(snapshot: OnScreenWindowSnapshot, delay: TimeInterval) {
        let signature = VisibleWindowSignature(snapshot: snapshot)
        guard signature != lastVisibleWindowSignature else { return }
        guard !shouldPauseLayoutForSystemUI() else { return }
        lastVisibleWindowSignature = signature
        scheduleWindowDiscoveryReconcileBurst(initialDelay: delay)
    }
    private func scheduleFocusRemember(delay: TimeInterval) {
        guard !isStopping else { return }
        pendingFocusRemember?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.rememberFocusedWindowOnly()
        }
        pendingFocusRemember = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    private func scheduleExternalMove(element: AXUIElement, userInitiated: Bool) {
        guard !isStopping, tilingEnabled, userInitiated, frozenSystemUIScreenStates == nil else { return }
        guard AXReader.string(element, attribute: kAXRoleAttribute) == kAXWindowRole else { return }
        pendingMove?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.handleExternalMove(element: element, userInitiated: userInitiated)
        }
        pendingMove = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }
    private func scheduleExternalResize(element: AXUIElement, userInitiated: Bool) {
        guard !isStopping, tilingEnabled, userInitiated, frozenSystemUIScreenStates == nil else { return }
        guard AXReader.string(element, attribute: kAXRoleAttribute) == kAXWindowRole else { return }
        pendingResize?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.handleExternalResize(element: element, userInitiated: userInitiated)
        }
        pendingResize = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    // MARK: - Reconciliation

    private func reconcileAndApplyLayout() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else { return }
        guard tilingEnabled else { return }
        guard pendingWorkspaceSwitchApply == nil else {
            scheduleReconcile(delay: workspaceSwitchApplyDelay + workspaceSlideAnimationDuration + 0.05)
            return
        }
        guard workspaceSlideAnimator == nil else {
            scheduleReconcile(delay: workspaceSlideAnimationDuration + 0.05)
            return
        }
        guard !shouldPauseLayoutForSystemUI() else {
            scheduleReconcile(delay: 0.70)
            return
        }
        guard frozenSystemUIScreenStates == nil else {
            handleSystemUISettled()
            return
        }
        refreshWindowNotificationRegistrations()
        let allWindows = managedWindows()
        let tiled = tiledWindows(from: allWindows)
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiled, focusedID: focusedID)
        applyLayout(to: allWindows)
    }
    private func rememberFocusedWindowOnly() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else { return }
        guard tilingEnabled else { return }
        guard !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else { return }
        let snapshot = WindowSnapshotReader.readOnScreenWindows()
        let visibleSignatureChanged = VisibleWindowSignature(snapshot: snapshot) != lastVisibleWindowSignature
        let windows = managedWindows(snapshot: snapshot)
        managedWindowCache = (windows, Date())
        if visibleSignatureChanged {
            scheduleWindowDiscoveryReconcileBurst(initialDelay: 0.01)
        }
        let tiled = tiledWindows(from: windows)
        if hasWindowSetChanged(tiled) {
            scheduleReconcile(delay: 0.01)
            return
        }
        guard let focusedID = focusTracker.focusedWindowID(in: windows) else { return }
        focusTracker.remember(focusedID)
        if let key = stateKey(containing: focusedID), var state = screenStates[key] {
            state.markFocusedIfKnown(focusedID)
            screenStates[key] = state
        }
    }
    private func handleExternalMove(element: AXUIElement, userInitiated: Bool) {
        guard !isStopping,
              userInitiated,
              tilingEnabled,
              !isApplyingLayout,
              !isSuppressingExternalChanges,
              frozenSystemUIScreenStates == nil,
              !shouldPauseLayoutForSystemUI() else { return }
        let allWindows = managedWindows()
        guard let changedWindow = focusTracker.window(matching: element, in: allWindows),
              !floatingWindowIDs.contains(changedWindow.id) else {
            return
        }
        guard placeDroppedWindow(changedWindow, allWindows: allWindows) else {
            applyLayout(to: allWindows)
            return
        }
    }
    private func handleExternalResize(element: AXUIElement, userInitiated: Bool) {
        guard !isStopping,
              userInitiated,
              tilingEnabled,
              !isApplyingLayout,
              !isSuppressingExternalChanges,
              frozenSystemUIScreenStates == nil,
              !shouldPauseLayoutForSystemUI() else { return }
        let allWindows = managedWindows()
        guard let changedWindow = focusTracker.window(matching: element, in: allWindows),
              !floatingWindowIDs.contains(changedWindow.id),
              let key = stateKey(containing: changedWindow.id),
              var state = screenStates[key] else {
            return
        }
        let screen = currentScreenInfosByKey()[key] ?? changedWindow.screen
        let observedSlot = TileSlot.normalized(from: changedWindow.frame, in: screen.frame)
        if state.reflectResize(focusedID: changedWindow.id, observedSlot: observedSlot) {
            screenStates[key] = state
        }
        applyLayout(to: allWindows)
        focus(window: changedWindow, updateTreeFocus: true)
    }
    private func placeDroppedWindow(_ changedWindow: ManagedWindow, allWindows: [ManagedWindow]) -> Bool {
        let sourceKey = stateKey(containing: changedWindow.id)
        let cursor = currentCursorPoint()
        let candidates = tiledWindows(from: allWindows).filter { $0.id != changedWindow.id }
        let targetWindow = targetWindowForDrop(cursor: cursor, moving: changedWindow, candidates: candidates)
        if let targetWindow {
            let action = dropAction(cursor: cursor, targetFrame: targetWindow.frame)
            return performDrop(moving: changedWindow, target: targetWindow, action: action, allWindows: allWindows)
        }
        guard let sourceKey else { return false }
        let destinationKey = changedWindow.screen.stateKey
        guard sourceKey != destinationKey else { return false }
        var sourceState = screenStates[sourceKey] ?? ScreenTileState()
        sourceState.remove(changedWindow.id)
        screenStates[sourceKey] = sourceState
        var destinationState = screenStates[destinationKey] ?? ScreenTileState()
        destinationState.insertExisting(changedWindow.id, near: destinationState.lastFocusedOrLargestID, placement: .automatic)
        destinationState.markFocused(changedWindow.id)
        screenStates[destinationKey] = destinationState
        applyLayout(to: allWindows)
        focus(window: changedWindow, updateTreeFocus: true)
        return true
    }
    private func performDrop(
        moving: ManagedWindow,
        target: ManagedWindow,
        action: DropAction,
        allWindows: [ManagedWindow]
    ) -> Bool {
        let sourceKey = stateKey(containing: moving.id)
        let targetKey = stateKey(containing: target.id) ?? target.screen.stateKey
        guard let sourceKey else { return false }
        switch action {
        case .swap where sourceKey == targetKey:
            guard var state = screenStates[sourceKey], state.move(moving.id, onto: target.id, placement: .swap) else {
                return false
            }
            state.markFocused(moving.id)
            screenStates[sourceKey] = state
        case .swap:
            // Cross-display center drops are treated as a regular split to avoid surprising cross-tree swaps.
            return performDrop(moving: moving, target: target, action: .split(.right), allWindows: allWindows)
        case .split(let direction):
            if sourceKey == targetKey {
                guard var state = screenStates[sourceKey], state.move(moving.id, onto: target.id, placement: .split(direction)) else {
                    return false
                }
                state.markFocused(moving.id)
                screenStates[sourceKey] = state
            } else {
                var sourceState = screenStates[sourceKey] ?? ScreenTileState()
                sourceState.remove(moving.id)
                screenStates[sourceKey] = sourceState
                var targetState = screenStates[targetKey] ?? ScreenTileState()
                targetState.insertExisting(moving.id, near: target.id, placement: .split(direction))
                targetState.markFocused(moving.id)
                screenStates[targetKey] = targetState
            }
        }
        applyLayout(to: allWindows)
        focus(window: moving, updateTreeFocus: true)
        return true
    }
    private func dropAction(cursor: CGPoint, targetFrame: CGRect) -> DropAction {
        WindowDropPlanner.dropAction(cursor: cursor, targetFrame: targetFrame)
    }
    private func targetWindowForDrop(cursor: CGPoint, moving: ManagedWindow, candidates: [ManagedWindow]) -> ManagedWindow? {
        WindowDropPlanner.targetWindowForDrop(cursor: cursor, moving: moving, candidates: candidates)
    }
    private func hasWindowSetChanged(_ windows: [ManagedWindow]) -> Bool {
        WindowStateSyncPlanner.hasWindowSetChanged(
            windows: windows,
            activeStateKeys: Set(currentScreenInfos().map(\.stateKey)),
            screenStates: screenStates
        )
    }
    private func hasLikelyPartialHotKeySnapshot(_ windows: [ManagedWindow]) -> Bool {
        HotKeyStatePlanner.hasLikelyPartialSnapshot(
            windows: windows,
            activeStateKeys: Set(currentScreenInfos().map(\.stateKey)),
            screenStates: screenStates
        )
    }
    private func hasLikelyPartialHotKeySnapshot(
        forStateKey key: String,
        windows: [ManagedWindow]
    ) -> Bool {
        HotKeyStatePlanner.hasLikelyPartialSnapshot(
            forStateKey: key,
            windows: windows,
            screenStates: screenStates
        )
    }
    private func interactiveManagedWindows() -> [ManagedWindow] {
        let cachedWindows = managedWindows(useCache: true, cacheDuration: interactiveWindowCacheDuration)
        let cachedTiled = tiledWindows(from: cachedWindows)
        let shouldRefresh =
            lastVisibleWindowSignature != lastSyncedVisibleWindowSignature ||
            hasWindowSetChanged(cachedTiled)
        guard shouldRefresh else { return cachedWindows }
        let refreshedWindows = managedWindows()
        return refreshedWindows.isEmpty ? cachedWindows : refreshedWindows
    }

    // MARK: - Hot Keys

    @discardableResult
    private func performHotKeyActionWithRetry(
        _ action: (_ windows: [ManagedWindow], _ focusedID: WindowIdentity?) -> Bool
    ) -> Bool {
        let initialWindows = interactiveManagedWindows()
        if !initialWindows.isEmpty {
            let initialFocusedID = resolvedHotKeyFocusedID(
                in: initialWindows,
                preferredFocusedID: focusTracker.focusedWindowIDForHotKey(in: initialWindows)
            )
            syncStatesForHotKeyIfNeeded(with: initialWindows, focusedID: initialFocusedID)
            if action(initialWindows, initialFocusedID) {
                return true
            }
        }
        let refreshedWindows = managedWindows()
        guard !refreshedWindows.isEmpty else {
            scheduleReconcile(delay: 0.01)
            NSSound.beep()
            return false
        }
        let refreshedFocusedID = resolvedHotKeyFocusedID(
            in: refreshedWindows,
            preferredFocusedID: focusTracker.focusedWindowIDForHotKey(in: refreshedWindows)
        )
        let refreshedTiled = tiledWindows(from: refreshedWindows)
        if hasLikelyPartialHotKeySnapshot(refreshedTiled) {
            scheduleReconcile(delay: 0.01)
            let initialFallbackFocusedID = resolvedHotKeyFocusedID(
                in: initialWindows,
                preferredFocusedID: focusTracker.focusedWindowIDForHotKey(in: initialWindows)
            )
            if action(initialWindows, initialFallbackFocusedID) {
                return true
            }
        }
        if action(refreshedWindows, refreshedFocusedID) {
            return true
        }
        scheduleReconcile(delay: 0.02)
        NSSound.beep()
        return false
    }
    private func resolvedHotKeyFocusedID(
        in windows: [ManagedWindow],
        preferredFocusedID: WindowIdentity?
    ) -> WindowIdentity? {
        let focusedContext = currentWorkspaceContext(windows: windows, focusedID: preferredFocusedID)
        let cursorContext = currentWorkspaceContext(windows: windows, focusedID: nil)
        let resolvedID = WindowFocusNavigator.resolvedHotKeyFocusedID(
            in: windows,
            preferredFocusedID: preferredFocusedID,
            lastKnownFocusedID: focusTracker.lastKnownWindowID,
            preferredActiveStateKey: focusedContext?.stateKey,
            cursorActiveStateKey: cursorContext?.stateKey,
            screenStates: screenStates,
            floatingWindowIDs: floatingWindowIDs,
            cursor: currentCursorPoint()
        )
        if let resolvedID {
            focusTracker.remember(resolvedID)
        }
        return resolvedID
    }
    private func resolvedHotKeyStateKey(
        for focusedID: WindowIdentity,
        windows: [ManagedWindow]
    ) -> String? {
        let resolution = HotKeyStatePlanner.resolveStateKey(
            for: focusedID,
            knownStateKey: stateKey(containing: focusedID),
            windows: windows,
            screenStates: screenStates,
            floatingWindowIDs: floatingWindowIDs
        )
        switch resolution {
        case .existing(let key):
            return key
        case .initialize(let key, let windowIDs):
            var state = screenStates[key] ?? ScreenTileState()
            state.sync(windowIDs: windowIDs, focusedID: windowIDs.contains(focusedID) ? focusedID : nil)
            screenStates[key] = state
            return key
        case nil:
            return nil
        }
    }
    private func synchronizeHotKeyState(
        key: String,
        focusedID: WindowIdentity,
        windows: [ManagedWindow]
    ) -> ScreenTileState? {
        var state = screenStates[key]
        switch HotKeyStatePlanner.syncAction(
            currentState: state,
            focusedID: focusedID,
            windows: windows,
            stateKey: key,
            floatingWindowIDs: floatingWindowIDs
        ) {
        case .unavailable:
            return nil
        case .preserveExistingFocus:
            state?.markFocusedIfKnown(focusedID)
        case .sync(let windowIDs, let focusedID):
            state?.sync(windowIDs: windowIDs, focusedID: focusedID)
        case .markFocused:
            state?.markFocusedIfKnown(focusedID)
        }
        screenStates[key] = state
        return screenStates[key]
    }
    private func focusNeighbor(direction: SnapDirection) {
        _ = performHotKeyActionWithRetry { [weak self] allWindows, focusedID in
            guard let self,
                  let focusedID else {
                return false
            }
            let key = self.resolvedHotKeyStateKey(for: focusedID, windows: allWindows)
            let targetID: WindowIdentity?
            if let key, let state = self.synchronizeHotKeyState(key: key, focusedID: focusedID, windows: allWindows) {
                targetID = state.neighborID(from: focusedID, direction: direction)
                    ?? WindowFocusNavigator.frameBasedNeighborID(
                        from: focusedID,
                        direction: direction,
                        windows: allWindows,
                        floatingWindowIDs: self.floatingWindowIDs
                    )
            } else {
                targetID = WindowFocusNavigator.frameBasedNeighborID(
                    from: focusedID,
                    direction: direction,
                    windows: allWindows,
                    floatingWindowIDs: self.floatingWindowIDs
                )
            }
            guard let targetID,
                  let targetWindow = allWindows.first(where: { $0.id == targetID }) else {
                return false
            }
            if let key, var state = self.screenStates[key] {
                state.markFocused(targetID)
                self.screenStates[key] = state
            }
            self.focus(window: targetWindow, updateTreeFocus: true)
            if let targetKey = self.resolvedHotKeyStateKey(for: targetID, windows: allWindows),
               var targetState = self.screenStates[targetKey] {
                targetState.markFocused(targetID)
                self.screenStates[targetKey] = targetState
            }
            return true
        }
    }
    private func scheduleHotKeyReconcileBurst() {
        scheduleReconcile(delay: 0.03)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.scheduleReconcile(delay: 0.01)
        }
    }

    // MARK: - Focus and Split Commands

    private func swapFocusedWindow(direction: SnapDirection) {
        _ = performHotKeyActionWithRetry { [weak self] allWindows, focusedID in
            guard let self,
                  let focusedID,
                  let key = self.resolvedHotKeyStateKey(for: focusedID, windows: allWindows),
                  var state = self.synchronizeHotKeyState(key: key, focusedID: focusedID, windows: allWindows),
                  state.swapFocused(focusedID, direction: direction) else {
                return false
            }
            self.screenStates[key] = state
            self.applyLayout(to: allWindows, limitingToStateKeys: [key])
            return true
        }
    }
    private func resizeFocusedWindow(direction: SnapDirection) {
        _ = performHotKeyActionWithRetry { [weak self] allWindows, focusedID in
            guard let self,
                  let focusedID,
                  let key = self.resolvedHotKeyStateKey(for: focusedID, windows: allWindows),
                  var state = self.synchronizeHotKeyState(key: key, focusedID: focusedID, windows: allWindows),
                  state.resizeFocused(focusedID, direction: direction) else {
                return false
            }
            self.screenStates[key] = state
            self.applyLayout(to: allWindows, limitingToStateKeys: [key])
            if let focusedWindow = allWindows.first(where: { $0.id == focusedID }) {
                self.focus(window: focusedWindow, updateTreeFocus: false)
            }
            self.scheduleHotKeyReconcileBurst()
            return true
        }
    }
    private func toggleFocusedSplitOrientation() {
        _ = performHotKeyActionWithRetry { [weak self] allWindows, focusedID in
            guard let self,
                  let focusedID,
                  let key = self.resolvedHotKeyStateKey(for: focusedID, windows: allWindows),
                  var state = self.synchronizeHotKeyState(key: key, focusedID: focusedID, windows: allWindows),
                  state.toggleOrientation(focusedID: focusedID) else {
                return false
            }
            self.screenStates[key] = state
            self.applyLayout(to: allWindows, limitingToStateKeys: [key])
            return true
        }
    }

    // MARK: - Workspaces

    private func cycleVirtualWorkspace(by delta: Int) {
        guard let context = workspaceSwitchContextFast() else {
            NSSound.beep()
            return
        }
        switchVirtualWorkspaceFast(
            to: settings.wrappedWorkspaceIndex(context.activeWorkspaceIndex + delta),
            context: context,
            directionHint: delta
        )
    }
    private func switchVirtualWorkspace(to index: Int) {
        guard let context = workspaceSwitchContextFast() else {
            NSSound.beep()
            return
        }
        switchVirtualWorkspaceFast(to: index, context: context)
    }
    private func switchVirtualWorkspaceFast(
        to requestedIndex: Int,
        context: WorkspaceContext,
        directionHint: Int? = nil
    ) {
        let currentIndex = settings.activeWorkspaceIndex(forNativeStateKey: context.nativeStateKey)
        let visibleIndex = lastAppliedWorkspaceIndexByNativeStateKey[context.nativeStateKey] ?? currentIndex
        let planningResult = WorkspaceSwitchPlanner.switchPlan(
            targetIndex: settings.availableWorkspaceIndex(requestedIndex),
            currentIndex: currentIndex,
            visibleIndex: visibleIndex,
            context: context,
            directionHint: directionHint
        )
        guard case .planned(let plan) = planningResult else {
            if case .unavailable = planningResult {
                NSSound.beep()
            }
            return
        }

        cancelPendingWorkspaceSwitchApply()
        pendingReconcile?.cancel()
        pendingReconcile = nil
        settings.setActiveWorkspaceIndex(plan.targetIndex, forNativeStateKey: context.nativeStateKey)
        lastWorkspaceSwitchContext = plan.activeContext
        pendingWorkspaceSwitchIndicator = plan.indicator
        suppressExternalChanges(for: 0.20)

        guard let slideDirection = plan.slideDirection else { return }
        let generation = workspaceSwitchApplyGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishWorkspaceSwitchApply(
                nativeStateKey: context.nativeStateKey,
                visibleIndex: plan.visibleIndex,
                targetIndex: plan.targetIndex,
                slideDirection: slideDirection,
                generation: generation
            )
        }
        pendingWorkspaceSwitchApply = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + workspaceSwitchApplyDelay, execute: workItem)
    }
    private func workspaceSwitchContextFast() -> WorkspaceContext? {
        if let lastKnownFocusedWindowID = focusTracker.lastKnownWindowID,
           let managedWindowCache,
           Date().timeIntervalSince(managedWindowCache.createdAt) <= interactiveWindowCacheDuration,
           let focusedWindow = managedWindowCache.windows.first(where: { $0.id == lastKnownFocusedWindowID }) {
            let context = workspaceContext(for: focusedWindow.screen)
            lastWorkspaceSwitchContext = context
            return context
        }
        if let screen = screenContainingCursor() {
            let context = workspaceContext(for: screenInfo(forScreen: screen))
            lastWorkspaceSwitchContext = context
            return context
        }
        if let cached = lastWorkspaceSwitchContext {
            let activeIndex = settings.activeWorkspaceIndex(forNativeStateKey: cached.nativeStateKey)
            return cached.withActiveWorkspaceIndex(activeIndex)
        }
        if let main = NSScreen.main {
            let context = workspaceContext(for: screenInfo(forScreen: main))
            lastWorkspaceSwitchContext = context
            return context
        }
        return currentScreenInfos().first.map { screen in
            let context = workspaceContext(for: screen)
            lastWorkspaceSwitchContext = context
            return context
        }
    }
    private func completeWorkspaceSwitchApply(allWindows: [ManagedWindow], plan: WorkspaceSwitchApplyPlan) {
        suppressExternalChanges(for: 0.45)
        applyLayout(to: allWindows, limitingToStateKeys: plan.stateKeys)
        lastAppliedWorkspaceIndexByNativeStateKey[plan.nativeStateKey] = plan.targetIndex
        if let targetState = screenStates[plan.targetStateKey],
           let targetID = targetState.lastFocusedOrLargestID,
           let targetWindow = allWindows.first(where: { $0.id == targetID }) {
            focus(window: targetWindow, updateTreeFocus: true)
        }
        scheduleReconcile(delay: 0.18)
    }
    private func animateWorkspaceSwitchIfPossible(
        allWindows: [ManagedWindow],
        nativeStateKey: String,
        visibleStateKey: String,
        targetStateKey: String,
        direction: WorkspaceSlideDirection,
        generation: Int,
        completion: @escaping () -> Void
    ) -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        guard workspaceSlideAnimator == nil else { return false }
        guard let screen = currentScreenInfos().first(where: { $0.nativeStateKey == nativeStateKey }) else {
            return false
        }
        let transitions = WorkspaceSlidePlanner.transitions(
            allWindows: allWindows,
            screen: screen,
            visibleState: screenStates[visibleStateKey],
            targetState: screenStates[targetStateKey],
            direction: direction,
            floatingWindowIDs: floatingWindowIDs,
            screens: currentScreenInfos(),
            gapPixels: CGFloat(gapPixels)
        )
        guard !transitions.isEmpty,
              transitions.count <= WorkspaceSlidePlanner.maximumTransitionCount else {
            return false
        }
        suppressExternalChanges(for: workspaceSlideAnimationDuration + 0.55)
        applyWorkspaceSlideInitialFrames(transitions)
        let animator = WorkspaceSlideAnimator(
            duration: workspaceSlideAnimationDuration,
            frameRate: WorkspaceSlidePlanner.frameRate(for: screen),
            screen: WorkspaceSlidePlanner.nsScreen(for: screen),
            shouldContinue: { [weak self] in
                guard let self else { return false }
                return !self.isStopping && self.workspaceSwitchApplyGeneration == generation
            },
            onFrame: { [weak self] progress in
                guard let self else { return }
                self.applyWorkspaceSlideStep(transitions, progress: progress)
            },
            onFinish: { [weak self] in
                self?.workspaceSlideAnimator = nil
                completion()
            }
        )
        workspaceSlideAnimator = animator
        animator.start()
        return true
    }
    private func applyWorkspaceSlideInitialFrames(_ transitions: [WorkspaceSlideTransition]) {
        let initialTransitions = transitions.filter(\.needsInitialFrame)
        guard !initialTransitions.isEmpty else { return }
        isApplyingLayout = true
        var appliedFramesByID: [WindowIdentity: CGRect] = [:]
        defer {
            isApplyingLayout = false
            updateManagedWindowCache(withAppliedFrames: appliedFramesByID)
        }
        for transition in initialTransitions {
            WindowFrameApplier.applyFrame(transition.startFrame, to: transition.window.element)
            lastAppliedFrameByWindowID[transition.window.id] = transition.startFrame
            appliedFramesByID[transition.window.id] = transition.startFrame
        }
    }
    private func applyWorkspaceSlideStep(_ transitions: [WorkspaceSlideTransition], progress: CGFloat) {
        guard !transitions.isEmpty else { return }
        isApplyingLayout = true
        var appliedFramesByID: [WindowIdentity: CGRect] = [:]
        defer {
            isApplyingLayout = false
            updateManagedWindowCache(withAppliedFrames: appliedFramesByID)
            suppressExternalChanges(for: 0.45)
        }
        for transition in transitions {
            let frame = WorkspaceSlidePlanner.interpolatedFrame(
                from: transition.startFrame,
                to: transition.endFrame,
                progress: progress
            )
            WindowFrameApplier.applyPosition(frame.origin, to: transition.window.element)
            lastAppliedFrameByWindowID[transition.window.id] = frame
            appliedFramesByID[transition.window.id] = frame
        }
    }
    private func finishWorkspaceSwitchApply(
        nativeStateKey: String,
        visibleIndex: Int,
        targetIndex: Int,
        slideDirection: WorkspaceSlideDirection,
        generation: Int
    ) {
        pendingWorkspaceSwitchApply = nil
        guard !isStopping, workspaceSwitchApplyGeneration == generation else { return }
        guard hasAccessibilityPermission(prompt: false), tilingEnabled else { return }
        guard !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else {
            scheduleReconcile(delay: 0.08)
            return
        }
        let allWindows = interactiveManagedWindows()
        let focusedID = focusTracker.focusedWindowIDForHotKey(in: allWindows)
        syncStatesForHotKeyIfNeeded(with: allWindows, focusedID: focusedID)
        let applyPlan = WorkspaceSwitchPlanner.applyPlan(
            nativeStateKey: nativeStateKey,
            visibleIndex: visibleIndex,
            targetIndex: targetIndex
        )
        suppressExternalChanges(for: 0.45)
        let completion: () -> Void = { [weak self] in
            self?.completeWorkspaceSwitchApply(
                allWindows: allWindows,
                plan: applyPlan
            )
        }
        guard animateWorkspaceSwitchIfPossible(
            allWindows: allWindows,
            nativeStateKey: nativeStateKey,
            visibleStateKey: applyPlan.visibleStateKey,
            targetStateKey: applyPlan.targetStateKey,
            direction: slideDirection,
            generation: generation,
            completion: completion
        ) else {
            completion()
            return
        }
    }
    private func createVirtualWorkspace() {
        cancelPendingWorkspaceSwitchApply()
        guard workspaceCount < settings.maximumWorkspaceCount else {
            NSSound.beep()
            return
        }
        guard let context = currentWorkspaceContext() else {
            NSSound.beep()
            return
        }
        let allWindows = managedWindows()
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        let newWorkspaceIndex = workspaceCount
        settings.setWorkspaceCount(newWorkspaceIndex + 1)
        settings.setActiveWorkspaceIndex(newWorkspaceIndex, forNativeStateKey: context.nativeStateKey)
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: newWorkspaceIndex,
            displayID: context.screen.displayID
        )
        suppressExternalChanges(for: 0.65)
        applyLayout(to: allWindows)
        scheduleReconcile(delay: 0.10)
    }
    private func deleteCurrentVirtualWorkspace() {
        cancelPendingWorkspaceSwitchApply()
        guard let context = currentWorkspaceContext() else {
            NSSound.beep()
            return
        }
        let allWindows = managedWindows()
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        let deletingIndex = context.activeWorkspaceIndex
        guard WorkspaceStatePlanner.deletionAvailability(
            index: deletingIndex,
            workspaceCount: workspaceCount,
            screenStates: screenStates,
            floatingWindowStateKeys: floatingWindowStateKeys
        ).canDelete else {
            NSSound.beep()
            return
        }
        let newWorkspaceCount = workspaceCount - 1
        let nextActiveIndex = settings.shiftedActiveWorkspaceIndex(
            context.activeWorkspaceIndex,
            deletingWorkspaceIndex: deletingIndex,
            newWorkspaceCount: newWorkspaceCount
        )
        screenStates = WorkspaceStatePlanner.shiftedScreenStates(
            screenStates,
            deletingWorkspaceIndex: deletingIndex
        )
        persistedLayoutsByStateKey = WorkspaceStatePlanner.shiftedPersistedLayouts(
            persistedLayoutsByStateKey,
            deletingWorkspaceIndex: deletingIndex
        )
        floatingWindowStateKeys = WorkspaceStatePlanner.shiftedFloatingWindowStateKeys(
            floatingWindowStateKeys,
            deletingWorkspaceIndex: deletingIndex
        )
        settings.shiftWorkspaceNames(deletingWorkspaceIndex: deletingIndex)
        settings.shiftActiveWorkspaceIndices(deletingWorkspaceIndex: deletingIndex, newWorkspaceCount: newWorkspaceCount)
        settings.setWorkspaceCount(newWorkspaceCount)
        settings.setActiveWorkspaceIndex(nextActiveIndex, forNativeStateKey: context.nativeStateKey)
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: nextActiveIndex,
            displayID: context.screen.displayID
        )
        suppressExternalChanges(for: 0.65)
        applyLayout(to: allWindows)
        let targetStateKey = ScreenInfo.workspaceStateKey(
            nativeStateKey: context.nativeStateKey,
            workspaceIndex: nextActiveIndex
        )
        if let targetState = screenStates[targetStateKey],
           let targetID = targetState.lastFocusedOrLargestID,
           let targetWindow = allWindows.first(where: { $0.id == targetID }) {
            focus(window: targetWindow, updateTreeFocus: true)
        }
        scheduleReconcile(delay: 0.15)
    }
    private func moveFocusedWindowToWorkspace(index requestedIndex: Int) {
        cancelPendingWorkspaceSwitchApply()
        let allWindows = managedWindows()
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let focusedWindow = allWindows.first(where: { $0.id == focusedID }),
              let sourceKey = stateKey(containing: focusedID),
              var sourceState = screenStates[sourceKey] else {
            NSSound.beep()
            return
        }
        let nativeStateKey = WorkspaceStateKeys.nativeStateKeyComponent(of: sourceKey)
        guard let targetIndex = settings.availableWorkspaceIndex(requestedIndex) else {
            NSSound.beep()
            return
        }
        let targetKey = ScreenInfo.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: targetIndex)
        guard sourceKey != targetKey else { return }
        sourceState.remove(focusedID)
        if sourceState.isEmpty {
            screenStates.removeValue(forKey: sourceKey)
        } else {
            screenStates[sourceKey] = sourceState
        }
        var targetState = screenStates[targetKey] ?? ScreenTileState()
        targetState.insertExisting(focusedID, near: targetState.lastFocusedOrLargestID, placement: .automatic)
        targetState.markFocused(focusedID)
        screenStates[targetKey] = targetState
        suppressExternalChanges(for: 0.65)
        applyLayout(to: allWindows)
        let activeTargetKey = ScreenInfo.workspaceStateKey(
            nativeStateKey: nativeStateKey,
            workspaceIndex: settings.activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
        )
        if targetKey == activeTargetKey {
            focus(window: focusedWindow, updateTreeFocus: true)
            return
        }
        if let fallbackID = sourceState.lastFocusedOrLargestID,
           let fallbackWindow = allWindows.first(where: { $0.id == fallbackID }) {
            focus(window: fallbackWindow, updateTreeFocus: true)
        }
    }
    private func toggleFocusedFloating() {
        cancelPendingWorkspaceSwitchApply()
        let allWindows = managedWindows()
        guard let focusedID = focusTracker.focusedWindowID(in: allWindows) else {
            NSSound.beep()
            return
        }
        if floatingWindowIDs.contains(focusedID) {
            floatingWindowIDs.remove(focusedID)
            floatingWindowStateKeys.removeValue(forKey: focusedID)
        } else {
            let key = stateKey(containing: focusedID)
            floatingWindowIDs.insert(focusedID)
            if let key {
                floatingWindowStateKeys[focusedID] = key
            }
            if let key, var state = screenStates[key] {
                state.remove(focusedID)
                screenStates[key] = state
            }
        }
        scheduleReconcile(delay: 0.01)
    }
    private func toggleTiling() {
        cancelPendingWorkspaceSwitchApply()
        settings.toggleTiling()
        if tilingEnabled {
            scheduleReconcile(delay: 0.01)
        }
    }
    private func balanceFocusedTree() {
        _ = performHotKeyActionWithRetry { [weak self] allWindows, focusedID in
            guard let self,
                  let focusedID,
                  let key = self.resolvedHotKeyStateKey(for: focusedID, windows: allWindows),
                  var state = self.synchronizeHotKeyState(key: key, focusedID: focusedID, windows: allWindows) else {
                return false
            }
            state.balance()
            state.markFocused(focusedID)
            self.screenStates[key] = state
            self.applyLayout(to: allWindows, limitingToStateKeys: [key])
            return true
        }
    }

    // MARK: - Layout State

    private func syncStates(with windows: [ManagedWindow], focusedID: WindowIdentity?) {
        _ = restoreKnownLayoutIdentities(using: windows)
        _ = restorePersistedLayouts(using: windows)
        let grouped = Dictionary(grouping: windows, by: { $0.screen.stateKey })
        let idsByScreen = grouped.mapValues { Set($0.map(\.id)) }
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        for key in Array(screenStates.keys) where activeStateKeys.contains(key) {
            var state = screenStates[key] ?? ScreenTileState()
            state.removeMissing(keeping: idsByScreen[key] ?? [])
            if state.isEmpty {
                screenStates.removeValue(forKey: key)
            } else {
                screenStates[key] = state
            }
        }
        for (screenKey, screenWindows) in grouped {
            var state = screenStates[screenKey] ?? ScreenTileState()
            let ids = screenWindows.map(\.id)
            let screenFocusedID = focusedID.flatMap { ids.contains($0) ? $0 : nil }
            state.sync(windowIDs: ids, focusedID: screenFocusedID)
            screenStates[screenKey] = state
        }
        rememberLayoutIdentities(using: windows)
        pruneLayoutIdentityCache(retainingVisibleIDs: Set(windows.map(\.id)))
        rememberPersistedLayouts(using: windows)
        if let focusedID {
            focusTracker.remember(focusedID)
        }
        lastSyncedVisibleWindowSignature = lastVisibleWindowSignature
    }
    private func pruneScreenStatesForVisibleWindows(_ visibleIDs: Set<WindowIdentity>) {
        for key in Array(screenStates.keys) {
            guard var state = screenStates[key] else { continue }
            state.removeMissing(keeping: visibleIDs)
            if state.isEmpty {
                screenStates.removeValue(forKey: key)
            } else {
                screenStates[key] = state
            }
        }
    }
    private func mergeAllWorkspaceStatesIntoActiveWorkspaces(focusedID: WindowIdentity?) -> Bool {
        let screens = currentScreenInfos()
        guard !screens.isEmpty else { return false }
        var merged = false
        for screen in screens {
            let targetIndex = settings.activeWorkspaceIndex(forNativeStateKey: screen.nativeStateKey)
            let targetKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: screen.nativeStateKey,
                workspaceIndex: targetIndex
            )
            merged = WorkspaceStateMigrator.mergeWorkspaceStates(
                inNativeStateKey: screen.nativeStateKey,
                into: targetKey,
                focusedID: focusedID,
                screenStates: &screenStates
            ) || merged
            merged = WorkspaceStateMigrator.moveFloatingWindowStateKeys(
                inNativeStateKey: screen.nativeStateKey,
                to: targetKey,
                floatingWindowStateKeys: &floatingWindowStateKeys
            ) || merged
        }
        return merged
    }
    private func syncStatesForHotKeyIfNeeded(with windows: [ManagedWindow], focusedID: WindowIdentity?) {
        let tiled = tiledWindows(from: windows)
        guard !hasLikelyPartialHotKeySnapshot(tiled) else {
            scheduleReconcile(delay: 0.01)
            if let focusedID,
               let key = stateKey(containing: focusedID),
               var state = screenStates[key] {
                state.markFocusedIfKnown(focusedID)
                screenStates[key] = state
            }
            return
        }
        guard lastVisibleWindowSignature == lastSyncedVisibleWindowSignature else {
            syncStates(with: tiled, focusedID: focusedID)
            return
        }
        guard !hasWindowSetChanged(tiled) else {
            syncStates(with: tiled, focusedID: focusedID)
            return
        }
        if let focusedID, stateKey(containing: focusedID) == nil {
            syncStates(with: tiled, focusedID: focusedID)
            return
        }
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key] else {
            return
        }
        state.markFocusedIfKnown(focusedID)
        screenStates[key] = state
    }
    private func applyLayout(
        to windows: [ManagedWindow],
        limitingToStateKeys stateKeyLimit: Set<String>? = nil,
        respectingTilingEnabled: Bool = true
    ) {
        guard !isStopping else { return }
        guard !respectingTilingEnabled || tilingEnabled else { return }
        let currentScreens = currentScreenInfos()
        let plan = WindowLayoutPlanner.plan(
            windows: windows,
            screenStates: screenStates,
            currentScreens: currentScreens,
            floatingWindowIDs: floatingWindowIDs,
            stateKeyLimit: stateKeyLimit,
            gapPixels: CGFloat(gapPixels)
        )
        pendingMove?.cancel()
        pendingResize?.cancel()
        suppressExternalChanges(for: 0.45)
        isApplyingLayout = true
        var appliedFramesByID: [WindowIdentity: CGRect] = [:]
        defer {
            isApplyingLayout = false
            updateManagedWindowCache(withAppliedFrames: appliedFramesByID)
            updateLastAppliedWorkspaceIndices(using: currentScreens)
            suppressExternalChanges(for: 0.45)
            if plan.skippedIncompleteState {
                scheduleReconcile(delay: 0.01)
            }
        }
        for assignment in plan.assignments {
            if let appliedFrame = set(window: assignment.window, frame: assignment.frame) {
                appliedFramesByID[assignment.window.id] = appliedFrame
            }
        }
        rememberPersistedLayouts(using: windows, limitingToStateKeys: stateKeyLimit)
    }
    private func updateLastAppliedWorkspaceIndices(using screens: [ScreenInfo]? = nil) {
        for screen in screens ?? currentScreenInfos() {
            lastAppliedWorkspaceIndexByNativeStateKey[screen.nativeStateKey] =
                settings.activeWorkspaceIndex(forNativeStateKey: screen.nativeStateKey)
        }
    }
    private var isSuppressingExternalChanges: Bool {
        Date() < suppressExternalChangesUntil
    }
    private func suppressExternalChanges(for duration: TimeInterval) {
        suppressExternalChangesUntil = max(suppressExternalChangesUntil, Date().addingTimeInterval(duration))
    }
    private func cancelPendingWorkspaceSwitchApply() {
        pendingWorkspaceSwitchApply?.cancel()
        pendingWorkspaceSwitchApply = nil
        cancelPendingWorkspaceSlideAnimation()
        workspaceSwitchApplyGeneration += 1
    }
    private func cancelPendingWorkspaceSlideAnimation(finalize: Bool = true) {
        if finalize {
            workspaceSlideAnimator?.finishImmediately()
        } else {
            workspaceSlideAnimator?.cancel()
        }
        workspaceSlideAnimator = nil
    }

    // MARK: - System UI Settling

    private func pauseLayoutForSystemUI(duration: TimeInterval, preserveLayout: Bool = true) {
        guard !isStopping else { return }
        if preserveLayout {
            if frozenSystemUIScreenStates == nil {
                frozenSystemUIScreenStates = screenStates
            }
            frozenSystemUIActiveStateKeys = Set(currentScreenInfos().map(\.stateKey))
            systemUISettleTracker.resetSnapshotStability()
        } else if frozenSystemUIScreenStates == nil {
            systemUISettleTracker.resetSnapshotStability()
        }
        systemUISettleTracker.pause(for: duration)
        pendingReconcile?.cancel()
        pendingFocusRemember?.cancel()
        pendingMove?.cancel()
        pendingResize?.cancel()
        cancelPendingWorkspaceSwitchApply()
        if preserveLayout {
            scheduleSystemUISettleCheck(delay: max(0.35, duration + 0.10))
        }
    }
    private func shouldPauseLayoutForSystemUI() -> Bool {
        systemUISettleTracker.isPaused
    }
    private func scheduleSystemUISettleCheck(delay: TimeInterval = 1.30) {
        guard !isStopping else { return }
        pendingSystemUISettle?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.handleSystemUISettled()
        }
        pendingSystemUISettle = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    private func handleSystemUISettled() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false), tilingEnabled else {
            frozenSystemUIScreenStates = nil
            frozenSystemUIActiveStateKeys = nil
            systemUISettleTracker.resetSnapshotStability()
            return
        }
        if systemUISettleTracker.isPaused {
            pauseLayoutForSystemUI(duration: 0.80, preserveLayout: true)
            return
        }
        refreshAppObservers()
        var allWindows = managedWindows()
        var tiled = tiledWindows(from: allWindows)
        guard systemUISettleTracker.isSnapshotStable(
            tiled,
            frozenStates: frozenSystemUIScreenStates,
            activeStateKeys: frozenSystemUIActiveStateKeys,
            layoutIdentityByWindowID: layoutIdentityByWindowID
        ) else {
            scheduleSystemUISettleCheck(delay: 0.35)
            return
        }
        let restoredFrozenLayout = restoreFrozenStatesIfWindowSetUnchanged(using: tiled)
        let restoredIdentityLayout = restoreKnownLayoutIdentities(using: tiled, sourceStates: frozenSystemUIScreenStates)
        let restoredPersistedLayout = restorePersistedLayouts(using: tiled)
        let focusedID = focusTracker.focusedWindowID(in: allWindows)
        let migratedWorkspaceStates = migrateWorkspaceStatesAfterScreenChangeIfNeeded(windows: allWindows, focusedID: focusedID)
        if migratedWorkspaceStates {
            invalidateManagedWindowCache(clearAppliedFrames: true)
            allWindows = managedWindows()
            tiled = tiledWindows(from: allWindows)
        }
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        systemUISettleTracker.resetSnapshotStability()
        if hasWindowSetChanged(tiled) {
            scheduleReconcile(delay: 0.05)
        } else if restoredFrozenLayout || restoredIdentityLayout || restoredPersistedLayout || migratedWorkspaceStates {
            applyLayout(to: allWindows)
        }
    }
    private func restoreFrozenStatesIfWindowSetUnchanged(using windows: [ManagedWindow]) -> Bool {
        guard let frozenSystemUIScreenStates else { return false }
        var restored = false
        let idsByScreen = Dictionary(grouping: windows, by: { $0.screen.stateKey })
            .mapValues { Set($0.map(\.id)) }
        for (key, ids) in idsByScreen {
            if let frozenState = frozenSystemUIScreenStates[key], frozenState.windowIDs == ids {
                screenStates[key] = frozenState
                restored = true
                continue
            }
            guard let fallback = frozenSystemUIScreenStates.first(where: { frozenKey, frozenState in
                    WorkspaceStateKeys.canMigrateState(from: frozenKey, to: key) && frozenState.windowIDs == ids
                  }) else {
                continue
            }
            if WorkspaceStateKeys.shouldRemoveStateAfterRestore(from: fallback.key, to: key) {
                screenStates.removeValue(forKey: fallback.key)
            }
            screenStates[key] = fallback.value
            restored = true
        }
        return restored
    }

    // MARK: - Screen Migration

    @discardableResult
    private func migrateWorkspaceStatesAfterScreenChangeIfNeeded(
        windows: [ManagedWindow]? = nil,
        focusedID: WindowIdentity? = nil
    ) -> Bool {
        guard shouldMigrateWorkspaceStatesAfterScreenChange else { return false }
        let currentScreens = currentScreenInfos()
        var migrated = false
        migrated = migrateOrphanedWorkspaceStatesAfterScreenChange(
            currentScreens: currentScreens,
            windows: windows,
            focusedID: focusedID
        ) || migrated
        for screen in currentScreens {
            migrated = WorkspaceStateMigrator.migrateStates(
                toNativeStateKey: screen.nativeStateKey,
                workspaceCount: workspaceCount,
                screenStates: &screenStates,
                persistedLayoutsByStateKey: &persistedLayoutsByStateKey,
                floatingWindowStateKeys: &floatingWindowStateKeys
            ) || migrated
        }
        shouldMigrateWorkspaceStatesAfterScreenChange = false
        return migrated
    }
    private func migrateOrphanedWorkspaceStatesAfterScreenChange(
        currentScreens: [ScreenInfo],
        windows: [ManagedWindow]?,
        focusedID: WindowIdentity?
    ) -> Bool {
        guard !currentScreens.isEmpty else { return false }
        let currentNativeStateKeys = Set(currentScreens.map(\.nativeStateKey))
        let orphanedNativeStateKeys = ScreenMigrationPlanner.orphanedNativeStateKeys(
            currentNativeStateKeys: currentNativeStateKeys,
            screenStates: screenStates,
            persistedLayoutsByStateKey: persistedLayoutsByStateKey,
            floatingWindowStateKeys: floatingWindowStateKeys,
            disconnectedNativeStateKeys: disconnectedNativeStateKeysPendingMigration,
            hasWorkspaceMetadata: settings.hasWorkspaceMetadata(forNativeStateKey:)
        )
        guard !orphanedNativeStateKeys.isEmpty else { return false }
        var migrated = false
        for sourceNativeStateKey in orphanedNativeStateKeys.sorted() {
            guard let targetNativeStateKey = targetNativeStateKeyForOrphanedDisplay(
                sourceNativeStateKey,
                currentScreens: currentScreens,
                windows: windows
            ) else {
                continue
            }
            migrated = migrateOrphanedWorkspaceStates(
                fromNativeStateKey: sourceNativeStateKey,
                toNativeStateKey: targetNativeStateKey,
                focusedID: focusedID
            ) || migrated
            disconnectedNativeStateKeysPendingMigration.remove(sourceNativeStateKey)
        }
        return migrated
    }
    private func targetNativeStateKeyForOrphanedDisplay(
        _ sourceNativeStateKey: String,
        currentScreens: [ScreenInfo],
        windows: [ManagedWindow]?
    ) -> String? {
        let sourceWindowIDs = ScreenMigrationPlanner.windowIDs(
            inNativeStateKey: sourceNativeStateKey,
            screenStates: screenStates,
            floatingWindowStateKeys: floatingWindowStateKeys
        )
        let screenCatalog = self.screenCatalog
        return ScreenMigrationPlanner.targetNativeStateKeyForOrphanedDisplay(
            sourceNativeStateKey: sourceNativeStateKey,
            currentScreens: currentScreens,
            windows: windows,
            sourceWindowIDs: sourceWindowIDs,
            screenForFrame: { window, screens in
                screenCatalog.info(for: window.frame, screens: screens)
            },
            fallbackNativeStateKeys: screenMigrationFallbackNativeStateKeys()
        )
    }
    private func screenMigrationFallbackNativeStateKeys() -> [String] {
        var keys: [String] = []
        if let cursorScreen = screenContainingCursor() {
            keys.append(screenInfo(forScreen: cursorScreen).nativeStateKey)
        }
        if let main = NSScreen.main {
            keys.append(screenInfo(forScreen: main).nativeStateKey)
        }
        return keys
    }
    private func migrateOrphanedWorkspaceStates(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        focusedID: WindowIdentity?
    ) -> Bool {
        guard sourceNativeStateKey != targetNativeStateKey else { return false }
        let targetHadState = WorkspaceStateMigrator.hasAnyScreenState(
            inNativeStateKey: targetNativeStateKey,
            screenStates: screenStates
        )
        let sourceActiveIndex = settings.storedActiveWorkspaceIndex(forNativeStateKey: sourceNativeStateKey)
        var focusedWorkspaceIndex: Int?
        var migrated = WorkspaceStateMigrator.migrateNativeWorkspaceStates(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey,
            workspaceCount: workspaceCount,
            focusedID: focusedID,
            screenStates: &screenStates,
            persistedLayoutsByStateKey: &persistedLayoutsByStateKey,
            floatingWindowStateKeys: &floatingWindowStateKeys,
            focusedWorkspaceIndex: &focusedWorkspaceIndex
        )
        migrated = settings.migrateActiveWorkspaceIndex(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey,
            sourceActiveIndex: sourceActiveIndex,
            focusedWorkspaceIndex: focusedWorkspaceIndex,
            targetHadState: targetHadState
        ) || migrated
        migrated = settings.migrateWorkspaceNames(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey
        ) || migrated
        return migrated
    }

    // MARK: - Floating and Identity Restoration

    private func tiledWindows(from windows: [ManagedWindow], respectingTilingEnabled: Bool = true) -> [ManagedWindow] {
        guard !respectingTilingEnabled || tilingEnabled else { return [] }
        restoreFloatingLayoutIdentities(using: windows)
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        return windows.filter { activeStateKeys.contains($0.screen.stateKey) && !floatingWindowIDs.contains($0.id) }
    }
    private func updateVisibleFloatingWindowStateKeys(using windows: [ManagedWindow]) {
        for window in windows where floatingWindowIDs.contains(window.id) {
            floatingWindowStateKeys[window.id] = window.screen.stateKey
        }
    }
    private func removeFloatingWindowID(forDestroyedElement element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        let windowKey = AXReader.int(element, attribute: "AXWindowNumber")
            .map { WindowOrderKey(pid: pid, number: $0) }
            ?? AXReader.int(element, attribute: "_AXWindowNumber")
            .map { WindowOrderKey(pid: pid, number: $0) }
        let elementKey = WindowElementKey(pid: pid, hash: CFHash(element))
        guard let id = identityRegistry.identityForStrongAlias(windowKey: windowKey, elementKey: elementKey),
              floatingWindowIDs.contains(id) else {
            return
        }
        removeFloatingWindowIDs([id])
    }
    private func removeFloatingWindowIDs(forTerminatedPIDs pids: Set<pid_t>) {
        guard !pids.isEmpty else { return }
        removeFloatingWindowIDs(Set(floatingWindowIDs.filter { pids.contains($0.pid) }))
    }
    private func removeFloatingWindowIDs(_ ids: Set<WindowIdentity>) {
        guard !ids.isEmpty else { return }
        floatingWindowIDs.subtract(ids)
        for id in ids {
            floatingWindowStateKeys.removeValue(forKey: id)
        }
        identityRegistry.removeAliases(for: ids)
    }
    @discardableResult
    private func restoreFloatingLayoutIdentities(using windows: [ManagedWindow]) -> Bool {
        let visibleIDs = Set(windows.map(\.id))
        let missingFloatingIDs = floatingWindowIDs.subtracting(visibleIDs)
        guard !missingFloatingIDs.isEmpty else { return false }
        var knownTiledIDs = Set(screenStates.values.flatMap(\.windowIDs))
        if let frozenSystemUIScreenStates {
            knownTiledIDs.formUnion(frozenSystemUIScreenStates.values.flatMap(\.windowIDs))
        }
        let candidateWindows = windows.filter { window in
            !floatingWindowIDs.contains(window.id) && !knownTiledIDs.contains(window.id)
        }
        guard !candidateWindows.isEmpty else { return false }
        let missingIDsByStateKey = Dictionary(grouping: Array(missingFloatingIDs)) { id in
            floatingWindowStateKeys[id]
        }
        let stateKeys = missingIDsByStateKey.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (.some(lhs), .some(rhs)):
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some), (.none, .none):
                return false
            }
        }
        var replacements: [WindowIdentity: WindowIdentity] = [:]
        var usedVisibleIDs: Set<WindowIdentity> = []
        for stateKey in stateKeys {
            let storedIDs = Set(missingIDsByStateKey[stateKey] ?? [])
            let visibleWindows = candidateWindows.filter { window in
                !usedVisibleIDs.contains(window.id) && (stateKey == nil || window.screen.stateKey == stateKey)
            }
            let stateReplacements = WindowLayoutIdentityMatcher.replacements(
                stored: LayoutRestorePlanner.layoutIdentityItems(
                    forStoredIDs: storedIDs,
                    identitiesByWindowID: layoutIdentityByWindowID
                ),
                visible: LayoutRestorePlanner.layoutIdentityItems(forWindows: visibleWindows)
            )
            replacements.merge(stateReplacements, uniquingKeysWith: { existing, _ in existing })
            usedVisibleIDs.formUnion(stateReplacements.values)
        }
        guard !replacements.isEmpty else { return false }
        applyLayoutIdentityRemapping(replacements)
        return true
    }
    @discardableResult
    private func restoreKnownLayoutIdentities(
        using windows: [ManagedWindow],
        sourceStates: [String: ScreenTileState]? = nil
    ) -> Bool {
        let states = sourceStates ?? screenStates
        guard !windows.isEmpty, !states.isEmpty else { return false }
        let grouped = Dictionary(grouping: windows, by: { $0.screen.stateKey })
        var replacements: [WindowIdentity: WindowIdentity] = [:]
        var restored = false
        for (currentKey, screenWindows) in grouped {
            guard
                let storedKey = LayoutRestorePlanner.storedStateKeyForLayoutRestore(
                    currentKey: currentKey,
                    windows: screenWindows,
                    states: states,
                    layoutIdentityByWindowID: layoutIdentityByWindowID,
                    canMigrateState: { WorkspaceStateKeys.canMigrateState(from: $0, to: $1) }
                ),
                let state = states[storedKey],
                let screen = screenWindows.first?.screen
            else {
                continue
            }
            if sourceStates != nil || storedKey != currentKey {
                screenStates[currentKey] = state
                if WorkspaceStateKeys.shouldRemoveStateAfterRestore(from: storedKey, to: currentKey) {
                    screenStates.removeValue(forKey: storedKey)
                }
                restored = true
            }
            replacements.merge(
                LayoutRestorePlanner.identityReplacements(
                    for: state,
                    on: screen,
                    currentWindows: screenWindows,
                    layoutIdentityByWindowID: layoutIdentityByWindowID,
                    gapPixels: CGFloat(gapPixels)
                ),
                uniquingKeysWith: { existing, _ in existing }
            )
        }
        guard !replacements.isEmpty else { return restored }
        applyLayoutIdentityRemapping(replacements)
        return true
    }
    private func applyLayoutIdentityRemapping(_ replacements: [WindowIdentity: WindowIdentity]) {
        let replacements = replacements.filter { $0.key != $0.value }
        guard !replacements.isEmpty else { return }
        for key in Array(screenStates.keys) {
            guard var state = screenStates[key] else { continue }
            if state.replaceWindowIDs(replacements) {
                screenStates[key] = state
            }
        }
        for (storedID, visibleID) in replacements {
            if floatingWindowIDs.remove(storedID) != nil {
                floatingWindowIDs.insert(visibleID)
            }
            if let stateKey = floatingWindowStateKeys.removeValue(forKey: storedID) {
                floatingWindowStateKeys[visibleID] = stateKey
            }
            if layoutIdentityByWindowID[visibleID] == nil,
               let layoutIdentity = layoutIdentityByWindowID[storedID] {
                layoutIdentityByWindowID[visibleID] = layoutIdentity
            }
            layoutIdentityByWindowID.removeValue(forKey: storedID)
        }
    }
    private func rememberLayoutIdentities(using windows: [ManagedWindow]) {
        for window in windows {
            guard let layoutIdentity = window.layoutIdentity else { continue }
            layoutIdentityByWindowID[window.id] = layoutIdentity
        }
    }
    private func pruneLayoutIdentityCache(retainingVisibleIDs visibleIDs: Set<WindowIdentity>) {
        var retainedIDs = visibleIDs
        retainedIDs.formUnion(screenStates.values.flatMap(\.windowIDs))
        if let frozenSystemUIScreenStates {
            retainedIDs.formUnion(frozenSystemUIScreenStates.values.flatMap(\.windowIDs))
        }
        retainedIDs.formUnion(floatingWindowIDs)
        layoutIdentityByWindowID = layoutIdentityByWindowID.filter { retainedIDs.contains($0.key) }
    }
    @discardableResult
    private func restorePersistedLayouts(using windows: [ManagedWindow]) -> Bool {
        guard !windows.isEmpty, !persistedLayoutsByStateKey.isEmpty else { return false }
        let grouped = Dictionary(grouping: windows, by: { $0.screen.stateKey })
        let snapshots = Array(persistedLayoutsByStateKey.values)
        var restored = false
        for (currentKey, screenWindows) in grouped {
            guard let screen = screenWindows.first?.screen else { continue }
            let candidates = LayoutRestorePlanner.persistedLayoutCandidates(
                for: currentKey,
                in: snapshots,
                canMigrateState: { WorkspaceStateKeys.canMigrateState(from: $0, to: $1) }
            )
            for snapshot in candidates {
                guard let state = LayoutRestorePlanner.restoredState(
                    from: snapshot,
                    on: screen,
                    currentWindows: screenWindows,
                    gapPixels: CGFloat(gapPixels)
                ) else {
                    continue
                }
                screenStates[currentKey] = state
                if WorkspaceStateKeys.shouldRemoveStateAfterRestore(from: snapshot.stateKey, to: currentKey) {
                    screenStates.removeValue(forKey: snapshot.stateKey)
                }
                restored = true
                break
            }
        }
        return restored
    }
    private func rememberPersistedLayouts(using windows: [ManagedWindow], limitingToStateKeys stateKeyLimit: Set<String>? = nil) {
        guard !windows.isEmpty else { return }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (stateKey, state) in screenStates where !state.isEmpty {
            if let stateKeyLimit, !stateKeyLimit.contains(stateKey) { continue }
            guard let snapshot = LayoutRestorePlanner.snapshot(
                stateKey: stateKey,
                state: state,
                windowsByID: windowsByID,
                layoutIdentityByWindowID: layoutIdentityByWindowID,
                displayKey: WorkspaceStateKeys.displayKeyComponent(of: stateKey)
            ) else { continue }
            persistedLayoutsByStateKey[stateKey] = snapshot
        }
    }
    // MARK: - Workspace Metadata

    private func currentWorkspaceContext(
        windows providedWindows: [ManagedWindow]? = nil,
        focusedID providedFocusedID: WindowIdentity? = nil
    ) -> WorkspaceContext? {
        if hasAccessibilityPermission(prompt: false) {
            let windows = providedWindows ?? managedWindows()
            let focusedID = providedFocusedID ?? focusTracker.focusedWindowID(in: windows)
            if let focusedID,
               let focusedWindow = windows.first(where: { $0.id == focusedID }) {
                return workspaceContext(for: focusedWindow.screen)
            }
        }
        if let cursorScreen = screenContainingCursor() {
            return workspaceContext(for: screenInfo(forScreen: cursorScreen))
        }
        if let main = NSScreen.main {
            return workspaceContext(for: screenInfo(forScreen: main))
        }
        return currentScreenInfos().first.map(workspaceContext(for:))
    }
    private func workspaceContext(for screen: ScreenInfo) -> WorkspaceContext {
        let nativeStateKey = screen.nativeStateKey
        let activeIndex = settings.activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
        let activeScreen = ScreenInfo(
            key: screen.key,
            frame: screen.frame,
            displayID: screen.displayID,
            workspaceIndex: activeIndex
        )
        return WorkspaceContext(screen: activeScreen, nativeStateKey: nativeStateKey, activeWorkspaceIndex: activeIndex)
    }
    private func screenInfo(forScreen screen: NSScreen) -> ScreenInfo {
        screenCatalog.info(forScreen: screen)
    }
    private func screenContainingCursor() -> NSScreen? {
        screenCatalog.screenContainingCursor()
    }
    private func displayName(for screen: ScreenInfo) -> String {
        screenCatalog.displayName(for: screen)
    }
    private func overviewWindow(
        for id: WindowIdentity,
        stateFocusedID: WindowIdentity?,
        focusedID: WindowIdentity?,
        windowsByID: [WindowIdentity: ManagedWindow]
    ) -> WorkspaceOverviewWindow {
        let window = windowsByID[id]
        let layoutIdentity = layoutIdentityByWindowID[id]
        let appName = NSRunningApplication(processIdentifier: id.pid)?.localizedName
            ?? metadataReader.normalizedWindowString(window?.bundleIdentifier)
            ?? layoutIdentity?.bundleIdentifier
        let title = metadataReader.normalizedWindowString(window?.title)
            ?? layoutIdentity?.title
            ?? appName
            ?? "Window \(id.serial)"
        let detail = appName == title ? nil : appName
        return WorkspaceOverviewWindow(
            title: title,
            detail: detail,
            isFocused: id == focusedID || id == stateFocusedID
        )
    }
    private func screenInfo(forKnownStateKey stateKey: String, fallback: ScreenInfo) -> ScreenInfo {
        let nativeStateKey = WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey)
        let screens = currentScreenInfos()
        if let screen = screens.first(where: { $0.nativeStateKey == nativeStateKey }) {
            return screen.withStateKeyOverride(stateKey)
        }
        let displayKey = WorkspaceStateKeys.displayKeyComponent(of: stateKey)
        let workspaceIndex = ScreenInfo.workspaceIndex(from: stateKey)
        if let screen = screens.first(where: { screen in
            WorkspaceStateKeys.displayKeyComponent(of: screen.nativeStateKey) == displayKey &&
                (workspaceIndex == nil || screen.workspaceIndex == workspaceIndex)
        }) {
            return screen
        }
        return fallback.withStateKeyOverride(stateKey)
    }
    private func stateKey(containing id: WindowIdentity) -> String? {
        stateKey(containing: id, activeStateKeys: Set(currentScreenInfos().map(\.stateKey)))
    }
    private func stateKey(containing id: WindowIdentity, activeStateKeys: Set<String>) -> String? {
        screenStates.first { activeStateKeys.contains($0.key) && $0.value.contains(id) }?.key
            ?? screenStates.first { $0.value.contains(id) }?.key
    }

    // MARK: - Window Discovery

    private func managedWindows(useCache: Bool = false, cacheDuration: TimeInterval? = nil) -> [ManagedWindow] {
        let now = Date()
        let allowedCacheAge = cacheDuration ?? defaultWindowCacheDuration
        if useCache,
           let managedWindowCache,
           now.timeIntervalSince(managedWindowCache.createdAt) <= allowedCacheAge {
            return managedWindowCache.windows
        }
        let windows = managedWindows(snapshot: WindowSnapshotReader.readOnScreenWindows())
        managedWindowCache = (windows, now)
        return windows
    }
    private func invalidateManagedWindowCache(clearAppliedFrames: Bool = false) {
        managedWindowCache = nil
        if clearAppliedFrames {
            lastAppliedFrameByWindowID.removeAll()
        }
    }
    private func updateManagedWindowCache(withAppliedFrames framesByID: [WindowIdentity: CGRect]) {
        guard !framesByID.isEmpty, let managedWindowCache else { return }
        let windows = managedWindowCache.windows.map { window -> ManagedWindow in
            guard let frame = framesByID[window.id] else { return window }
            return window.withFrame(frame)
        }
        self.managedWindowCache = (windows, managedWindowCache.createdAt)
    }
    private func refreshLastAppliedFrames(using windows: [ManagedWindow], retaining retainedIDs: Set<WindowIdentity>) {
        lastAppliedFrameByWindowID = lastAppliedFrameByWindowID.filter { retainedIDs.contains($0.key) }
        for window in windows {
            guard let frame = lastAppliedFrameByWindowID[window.id],
                  !WindowFrameApplier.approximatelyEqual(frame, window.frame) else {
                continue
            }
            lastAppliedFrameByWindowID.removeValue(forKey: window.id)
        }
    }
    private func managedWindows(snapshot: OnScreenWindowSnapshot) -> [ManagedWindow] {
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: snapshot)
        let screens = currentScreenInfos()
        let activeStateKeys = Set(screens.map(\.stateKey))
        let retainedOffscreenIDs = WindowStateSyncPlanner.retainedOffscreenWindowIDs(
            activeStateKeys: activeStateKeys,
            frozenSystemUIScreenStates: frozenSystemUIScreenStates,
            screenStates: screenStates,
            floatingWindowIDs: floatingWindowIDs
        )

        var registry = identityRegistry
        let discovery = WindowDiscovery(
            metadataReader: metadataReader,
            screenCatalog: screenCatalog,
            accessibilityMessagingTimeout: accessibilityMessagingTimeout
        )
        let result = discovery.managedWindows(
            snapshot: snapshot,
            screens: screens,
            retainedOffscreenIDs: retainedOffscreenIDs,
            identityRegistry: &registry,
            knownStateKey: { self.stateKey(containing: $0, activeStateKeys: activeStateKeys) },
            screenForKnownStateKey: { self.screenInfo(forKnownStateKey: $0, fallback: $1) }
        )
        identityRegistry = registry

        let windows = result.windows
        updateVisibleFloatingWindowStateKeys(using: windows)
        rememberLayoutIdentities(using: windows)
        pruneLayoutIdentityCache(retainingVisibleIDs: result.retainedIDs)
        refreshLastAppliedFrames(using: windows, retaining: result.retainedIDs)
        return windows
    }
    private func focus(window: ManagedWindow, updateTreeFocus: Bool) {
        focusTracker.focus(window)
        if updateTreeFocus, let key = stateKey(containing: window.id), var state = screenStates[key] {
            state.markFocused(window.id)
            screenStates[key] = state
        }
    }
    @discardableResult
    private func set(window: ManagedWindow, frame: CGRect) -> CGRect? {
        let frame = WindowFrameApplier.sanitizedFrame(frame)
        if WindowFrameApplier.approximatelyEqual(window.frame, frame) {
            lastAppliedFrameByWindowID[window.id] = frame
            return nil
        }
        // Do not synchronously read the AX frame here. AX reads are one of the slowest
        // operations on the hot resize/workspace paths; a later window scan refreshes
        // this cache and will re-apply if the app rejected the write.
        WindowFrameApplier.applyFrame(frame, to: window.element)
        lastAppliedFrameByWindowID[window.id] = frame
        return frame
    }
    private func currentScreenInfosByKey() -> [String: ScreenInfo] {
        screenCatalog.infosByKey()
    }
    private func currentScreenInfos() -> [ScreenInfo] {
        screenCatalog.currentInfos()
    }
    private func currentCursorPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
    }
    private var isPointerButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) ||
            CGEventSource.buttonState(.combinedSessionState, button: .center)
    }
}
