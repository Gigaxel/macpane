import AppKit
import ApplicationServices
import Carbon
private let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.gigaxel.macpane"
@main
final class MacPaneApp: NSObject, NSApplicationDelegate, HotKeyHandling {
    private static let sharedDelegate = MacPaneApp()
    private var statusItem: NSStatusItem?
    private var borderColorPanelObserver: NSObjectProtocol?
    private let tiler = WindowTiler()
    private var isPreparingToTerminate = false
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = sharedDelegate
        app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        HotKeyManager.shared.delegate = self
        HotKeyManager.shared.start()
        tiler.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination()
    }
    func handle(action: HotKeyAction) {
        tiler.handle(action: action)
        rebuildMenu()
    }
    private func setupMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton(statusItem.button)
        self.statusItem = statusItem
        rebuildMenu()
    }
    private func configureStatusButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        if let icon = Bundle.main.image(forResource: "MacPaneIcon") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            button.image = icon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else {
            button.title = "MacPane"
        }
        button.toolTip = "MacPane BSP tiling window manager"
    }
    private func rebuildMenu() {
        let menu = NSMenu()
        let permissionTitle = tiler.hasAccessibilityPermission(prompt: false)
            ? "Accessibility: Enabled"
            : "Accessibility: Needed"
        let permissionItem = NSMenuItem(title: permissionTitle, action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        let tilingItem = NSMenuItem(title: "Tiling: \(tiler.tilingEnabled ? "On" : "Off")", action: nil, keyEquivalent: "")
        tilingItem.isEnabled = false
        menu.addItem(tilingItem)
        menu.addItem(NSMenuItem.separator())
        let shortcuts = [
            "Cmd+Option+Arrow/HJKL: focus neighbor",
            "Cmd+Shift+Arrow/HJKL: swap with neighbor",
            "Cmd+Ctrl+Arrow/HJKL: resize focused split",
            "Cmd+Option+O: rotate focused split",
            "Cmd+Option+G: toggle focused window floating",
            "Cmd+Option+Y: toggle tiling",
            "Cmd+Option+B: balance current BSP tree",
            "Cmd+Ctrl+Option+N: create Space",
            "Mouse drop on edge: split target; center: swap target"
        ]
        for shortcut in shortcuts {
            let item = NSMenuItem(title: shortcut, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let gapItem = NSMenuItem(title: "Gap: \(tiler.gapPixels) px", action: nil, keyEquivalent: "")
        gapItem.isEnabled = false
        menu.addItem(gapItem)
        let decreaseGapItem = NSMenuItem(title: "Decrease Gap", action: #selector(decreaseGap), keyEquivalent: "[")
        decreaseGapItem.target = self
        menu.addItem(decreaseGapItem)
        let increaseGapItem = NSMenuItem(title: "Increase Gap", action: #selector(increaseGap), keyEquivalent: "]")
        increaseGapItem.target = self
        menu.addItem(increaseGapItem)
        let resetGapItem = NSMenuItem(title: "Reset Gap", action: #selector(resetGap), keyEquivalent: "0")
        resetGapItem.target = self
        menu.addItem(resetGapItem)
        menu.addItem(NSMenuItem.separator())
        let borderItem = NSMenuItem(title: "Show Focus Border", action: #selector(toggleBorder), keyEquivalent: "")
        borderItem.target = self
        borderItem.state = tiler.borderEnabled ? .on : .off
        menu.addItem(borderItem)
        let borderColorItem = NSMenuItem(title: "Border Color: \(tiler.borderColorName)", action: nil, keyEquivalent: "")
        let borderColorMenu = NSMenu()
        for preset in BorderColorPalette.presets {
            let presetItem = NSMenuItem(title: preset.title, action: #selector(selectBorderColor), keyEquivalent: "")
            presetItem.target = self
            presetItem.representedObject = preset.hex
            presetItem.state = BorderColorPalette.normalizedHex(preset.hex) == tiler.borderColorHex ? .on : .off
            borderColorMenu.addItem(presetItem)
        }
        borderColorMenu.addItem(NSMenuItem.separator())
        let customColorItem = NSMenuItem(title: "Custom Color...", action: #selector(openBorderColorPanel), keyEquivalent: "")
        customColorItem.target = self
        borderColorMenu.addItem(customColorItem)
        borderColorItem.submenu = borderColorMenu
        menu.addItem(borderColorItem)
        menu.addItem(NSMenuItem.separator())
        let retileItem = NSMenuItem(title: "Retile Now", action: #selector(retileNow), keyEquivalent: "r")
        retileItem.target = self
        menu.addItem(retileItem)
        let accessibilityItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        let refreshItem = NSMenuItem(title: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit MacPane", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }
    @objc private func openAccessibilitySettings() {
        _ = tiler.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func refreshStatus() {
        rebuildMenu()
    }
    @objc private func retileNow() {
        tiler.retileNow()
    }
    @objc private func decreaseGap() {
        tiler.adjustGap(by: -2)
        rebuildMenu()
    }
    @objc private func increaseGap() {
        tiler.adjustGap(by: 2)
        rebuildMenu()
    }
    @objc private func resetGap() {
        tiler.setGap(8)
        rebuildMenu()
    }
    @objc private func toggleBorder() {
        tiler.setBorderEnabled(!tiler.borderEnabled)
        rebuildMenu()
    }
    @objc private func selectBorderColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String,
              let color = BorderColorPalette.color(from: hex) else {
            return
        }
        tiler.setBorderColor(color)
        rebuildMenu()
    }
    @objc private func openBorderColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = tiler.borderColor
        observeBorderColorPanel(panel)
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }
    private func observeBorderColorPanel(_ panel: NSColorPanel) {
        guard borderColorPanelObserver == nil else { return }
        borderColorPanelObserver = NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let self, let panel = notification.object as? NSColorPanel else { return }
            self.tiler.setBorderColor(panel.color)
            self.rebuildMenu()
        }
    }
    @objc private func quit() {
        prepareForTermination()
        NSApplication.shared.terminate(nil)
    }
    private func prepareForTermination() {
        guard !isPreparingToTerminate else { return }
        isPreparingToTerminate = true
        HotKeyManager.shared.stop()
        tiler.stop()
        if let borderColorPanelObserver {
            NotificationCenter.default.removeObserver(borderColorPanelObserver)
            self.borderColorPanelObserver = nil
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
}
protocol HotKeyHandling: AnyObject {
    func handle(action: HotKeyAction)
}
enum HotKeyAction {
    case focus(SnapDirection)
    case swap(SnapDirection)
    case resize(SnapDirection)
    case createSpace
    case toggleOrientation
    case toggleFloating
    case toggleTiling
    case balance
    case retile
}
final class HotKeyManager {
    static let shared = HotKeyManager()
    weak var delegate: HotKeyHandling?
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var nextID: UInt32 = 1
    private let signature = fourCharCode("MCPN")
    private init() {}
    func start() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            NSLog("MacPane failed to install hotkey handler: \(handlerStatus)")
            return
        }
        registerHotKeys()
    }
    func stop() {
        delegate = nil
        for hotKeyRef in hotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
        nextID = 1
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    func handleHotKey(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        delegate?.handle(action: action)
    }
    private func registerHotKeys() {
        for item in directionalKeyCodes() {
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey), action: .focus(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | shiftKey), action: .swap(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | controlKey), action: .resize(item.direction))
        }
        register(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .createSpace)
        register(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | optionKey), action: .toggleOrientation)
        register(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey), action: .toggleFloating)
        register(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | optionKey), action: .toggleTiling)
        register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey), action: .balance)
        register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), action: .retile)
    }
    private func register(keyCode: UInt32, modifiers: UInt32, action: HotKeyAction) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            actionsByID[id] = action
            hotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("MacPane failed to register hotkey id=\(id) key=\(keyCode) modifiers=\(modifiers): \(status)")
        }
    }
    private func arrowKeyCodes() -> [(keyCode: UInt32, direction: SnapDirection)] {
        [
            (UInt32(kVK_LeftArrow), .left),
            (UInt32(kVK_DownArrow), .down),
            (UInt32(kVK_UpArrow), .up),
            (UInt32(kVK_RightArrow), .right)
        ]
    }
    private func directionalKeyCodes() -> [(keyCode: UInt32, direction: SnapDirection)] {
        arrowKeyCodes() + [
            (UInt32(kVK_ANSI_H), .left),
            (UInt32(kVK_ANSI_J), .down),
            (UInt32(kVK_ANSI_K), .up),
            (UInt32(kVK_ANSI_L), .right)
        ]
    }
}
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr {
        HotKeyManager.shared.handleHotKey(id: hotKeyID.id)
    }
    return noErr
}
private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(byte)
    }
    return result
}
private let axWindowNotificationCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tiler = Unmanaged<WindowTiler>.fromOpaque(refcon).takeUnretainedValue()
    tiler.handleAXNotification(notification as String, element: element)
}
private enum DropAction {
    case swap
    case split(SnapDirection)
}
private enum BorderColorPalette {
    static let defaultHex = "#FF9500"
    static let presets: [(title: String, hex: String)] = [
        ("Orange", defaultHex),
        ("Blue", "#0A84FF"),
        ("Green", "#30D158"),
        ("Purple", "#BF5AF2"),
        ("Red", "#FF453A"),
        ("White", "#FFFFFF")
    ]
    static func color(from hex: String?) -> NSColor? {
        guard let normalized = normalizedHex(hex) else { return nil }
        let start = normalized.index(normalized.startIndex, offsetBy: 1)
        let scanner = Scanner(string: String(normalized[start...]))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
    static func hexString(for color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = clampedColorComponent(srgb.redComponent)
        let green = clampedColorComponent(srgb.greenComponent)
        let blue = clampedColorComponent(srgb.blueComponent)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
    static func displayName(for hex: String) -> String {
        let normalized = normalizedHex(hex) ?? defaultHex
        return presets.first { normalizedHex($0.hex) == normalized }?.title ?? normalized
    }
    static func normalizedHex(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, UInt64(raw, radix: 16) != nil else { return nil }
        return "#\(raw.uppercased())"
    }
    private static func clampedColorComponent(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}
final class WindowTiler {
    private let gapDefaultsKey = "gapPixels"
    private let tilingEnabledDefaultsKey = "tilingEnabled"
    private let borderEnabledDefaultsKey = "borderEnabled"
    private let borderColorDefaultsKey = "borderColor"
    private let accessibilityPromptedDefaultsKey = "accessibilityPrompted"
    private let defaultGap = 8
    private let maximumGap = 48
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
    private var screenStates: [String: ScreenTileState] = [:]
    private var frozenSystemUIScreenStates: [String: ScreenTileState]?
    private var frozenSystemUIActiveStateKeys: Set<String>?
    private var stableSpaceIDByDisplayKey: [String: SpaceID] = [:]
    private var lastSystemUIWindowSnapshot: SystemUIWindowSnapshot?
    private var stableSystemUIWindowSnapshotCount = 0
    private var systemUISettleBeganAt: Date?
    private let requiredStableSystemUIWindowSnapshotCount = 2
    private let missingFrozenWindowGraceAfterSystemUI: TimeInterval = 3.0
    private let maximumLayoutRestoreFrameScore: CGFloat = 48
    private var floatingWindowIDs: Set<WindowIdentity> = []
    private var floatingWindowStateKeys: [WindowIdentity: String] = [:]
    private var identityRegistry = WindowIdentityRegistry()
    private var layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity] = [:]
    private var persistedLayoutsByStateKey: [String: PersistedScreenLayout] = [:]
    private let focusBorder = FocusBorderOverlay()
    private let visibilityScanInterval: TimeInterval = 2.0
    private let observerRecoveryInterval: TimeInterval = 15.0
    private let missionControlActivityCacheDuration: TimeInterval = 0.25
    private var lastVisibleWindowSignature = VisibleWindowSignature()
    private var lastObserverRefresh = Date.distantPast
    private var lastMissionControlActivityCheck = Date.distantPast
    private var cachedMissionControlLikelyActive = false
    private var knownNonObservablePIDs: Set<pid_t> = []
    private var suppressExternalChangesUntil = Date.distantPast
    private var systemUILayoutPausedUntil = Date.distantPast
    private var isWatching = false
    private var isApplyingLayout = false
    private var isStopping = false
    var gapPixels: Int {
        let stored = UserDefaults.standard.object(forKey: gapDefaultsKey) as? Int
        return min(max(stored ?? defaultGap, 0), maximumGap)
    }
    var tilingEnabled: Bool {
        if UserDefaults.standard.object(forKey: tilingEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: tilingEnabledDefaultsKey)
    }
    var borderEnabled: Bool {
        if UserDefaults.standard.object(forKey: borderEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: borderEnabledDefaultsKey)
    }
    var borderColorHex: String {
        BorderColorPalette.normalizedHex(UserDefaults.standard.string(forKey: borderColorDefaultsKey))
            ?? BorderColorPalette.defaultHex
    }
    var borderColorName: String {
        BorderColorPalette.displayName(for: borderColorHex)
    }
    var borderColor: NSColor {
        BorderColorPalette.color(from: borderColorHex) ?? BorderColorPalette.color(from: BorderColorPalette.defaultHex)!
    }
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
        isStopping = true
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
        permissionTimer?.invalidate()
        permissionTimer = nil
        scanTimer?.invalidate()
        scanTimer = nil
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
        screenStates.removeAll()
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        resetSystemUIWindowSnapshotStability()
        floatingWindowIDs.removeAll()
        floatingWindowStateKeys.removeAll()
        layoutIdentityByWindowID.removeAll()
        persistedLayoutsByStateKey.removeAll()
        focusBorder.close()
        lastVisibleWindowSignature = VisibleWindowSignature()
        lastObserverRefresh = Date.distantPast
        lastMissionControlActivityCheck = Date.distantPast
        cachedMissionControlLikelyActive = false
        knownNonObservablePIDs.removeAll()
        isApplyingLayout = false
        isWatching = false
    }
    func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    func requestAccessibilityPermission() -> Bool {
        UserDefaults.standard.set(true, forKey: accessibilityPromptedDefaultsKey)
        return hasAccessibilityPermission(prompt: true)
    }
    func retileNow() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else {
            startPermissionPolling()
            NSSound.beep()
            return
        }
        startWatching()
        reconcileAndApplyLayout()
    }
    func handle(action: HotKeyAction) {
        guard !isStopping else { return }
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
        case .createSpace:
            createSpaceForFocusedDisplay()
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
    func adjustGap(by delta: Int) {
        guard !isStopping else { return }
        setGap(gapPixels + delta)
    }
    func setGap(_ value: Int) {
        guard !isStopping else { return }
        let nextValue = min(max(value, 0), maximumGap)
        UserDefaults.standard.set(nextValue, forKey: gapDefaultsKey)
        scheduleReconcile(delay: 0.01)
    }
    func setBorderEnabled(_ enabled: Bool) {
        guard !isStopping else { return }
        UserDefaults.standard.set(enabled, forKey: borderEnabledDefaultsKey)
        if enabled {
            refreshFocusBorder()
        } else {
            focusBorder.hide()
        }
    }
    func setBorderColor(_ color: NSColor) {
        guard !isStopping else { return }
        let hex = BorderColorPalette.hexString(for: color) ?? BorderColorPalette.defaultHex
        UserDefaults.standard.set(hex, forKey: borderColorDefaultsKey)
        focusBorder.setColor(borderColor)
    }
    func handleAXNotification(_ notification: String, element: AXUIElement) {
        guard !isStopping,
              !isApplyingLayout,
              !isSuppressingExternalChanges,
              !shouldPauseLayoutForSystemUI(),
              frozenSystemUIScreenStates == nil else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            refreshWindowNotificationRegistrations()
            scheduleReconcile(delay: 0.04)
        case kAXUIElementDestroyedNotification:
            removeFloatingWindowID(forDestroyedElement: element)
            scheduleReconcile(delay: 0.03)
        case kAXFocusedWindowChangedNotification,
             kAXApplicationActivatedNotification,
             kAXMainWindowChangedNotification:
            scheduleFocusRemember(delay: 0.01)
        case kAXMovedNotification:
            scheduleExternalMove(element: element, userInitiated: isPointerButtonDown)
        case kAXResizedNotification:
            scheduleExternalResize(element: element, userInitiated: isPointerButtonDown)
        default:
            break
        }
    }
    private func ensureAccessibilityPermission() -> Bool {
        if hasAccessibilityPermission(prompt: false) { return true }
        guard !UserDefaults.standard.bool(forKey: accessibilityPromptedDefaultsKey) else {
            return false
        }
        return requestAccessibilityPermission()
    }
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
    private func startWatching() {
        guard !isStopping else { return }
        guard !isWatching else {
            refreshAppObservers()
            return
        }
        isWatching = true
        refreshAppObservers()
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: onScreenWindowSnapshot())
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAppObservers()
            self?.scheduleReconcile(delay: 0.06)
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAppObservers()
            self?.scheduleReconcile(delay: 0.04)
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStableSpaceIDsFromObservedScreens()
            self?.pauseLayoutForSystemUI(duration: 1.20, preserveLayout: true)
            self?.refreshAppObservers()
        })
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pauseLayoutForSystemUI(duration: 0.20, preserveLayout: false)
            self?.scheduleReconcile(delay: 0.30)
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: visibilityScanInterval, repeats: true) { [weak self] _ in
            self?.performPeriodicVisibilityScan()
        }
        scanTimer?.tolerance = visibilityScanInterval * 0.25
    }
    private func refreshAppObservers() {
        guard !isStopping else { return }
        let allRunningApps = NSWorkspace.shared.runningApplications
        let runningApps = allRunningApps.filter(isObservableApp)
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
        for app in NSWorkspace.shared.runningApplications.filter(isObservableApp) {
            registerWindowNotifications(for: app)
        }
    }
    private func registerWindowNotifications(for app: NSRunningApplication) {
        guard !isStopping else { return }
        guard let registration = appObservers[app.processIdentifier] else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = copyAXElements(appElement, attribute: kAXWindowsAttribute)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for (index, window) in windows.enumerated() {
            let token = notificationToken(for: window, fallbackIndex: index)
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
    private func scheduleReconcileIfWindowSetChanged(delay: TimeInterval) {
        guard !isStopping, tilingEnabled, frozenSystemUIScreenStates == nil, !shouldPauseLayoutForSystemUI() else { return }
        let windows = tiledWindows(from: managedWindows())
        guard hasWindowSetChanged(windows) else { return }
        scheduleReconcile(delay: delay)
    }
    // Recovery polling should stay cheap; AX/workspace notifications are the primary update path.
    private func performPeriodicVisibilityScan() {
        guard !isStopping, tilingEnabled, frozenSystemUIScreenStates == nil else { return }
        guard Date() >= systemUILayoutPausedUntil else { return }
        let snapshot = onScreenWindowSnapshot()
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
        scheduleReconcile(delay: delay)
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
        guard copyString(element, attribute: kAXRoleAttribute) == kAXWindowRole else { return }
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
        guard copyString(element, attribute: kAXRoleAttribute) == kAXWindowRole else { return }
        pendingResize?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.handleExternalResize(element: element, userInitiated: userInitiated)
        }
        pendingResize = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }
    private func reconcileAndApplyLayout() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else { return }
        guard tilingEnabled else {
            focusBorder.hide()
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
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiled, focusedID: focusedID)
        applyLayout(to: allWindows)
    }
    private func rememberFocusedWindowOnly() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else { return }
        guard tilingEnabled else {
            focusBorder.hide()
            return
        }
        guard !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else { return }
        let windows = managedWindows()
        let tiled = tiledWindows(from: windows)
        if hasWindowSetChanged(tiled) {
            scheduleReconcile(delay: 0.01)
            return
        }
        guard let focusedID = focusedWindowID(in: windows) else {
            updateFocusBorder(using: windows)
            return
        }
        if let key = stateKey(containing: focusedID), var state = screenStates[key] {
            state.markFocusedIfKnown(focusedID)
            screenStates[key] = state
        }
        updateFocusBorder(using: windows)
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
        guard let changedWindow = window(matching: element, in: allWindows),
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
        guard let changedWindow = window(matching: element, in: allWindows),
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
        guard targetFrame.width > 0, targetFrame.height > 0 else { return .split(.right) }
        if targetFrame.contains(cursor) {
            let relativeX = (cursor.x - targetFrame.minX) / targetFrame.width
            let relativeY = (cursor.y - targetFrame.minY) / targetFrame.height
            if relativeX > 0.33, relativeX < 0.67, relativeY > 0.33, relativeY < 0.67 {
                return .swap
            }
        }
        let distances: [(direction: SnapDirection, distance: CGFloat)] = [
            (.left, abs(cursor.x - targetFrame.minX)),
            (.right, abs(cursor.x - targetFrame.maxX)),
            (.up, abs(cursor.y - targetFrame.minY)),
            (.down, abs(cursor.y - targetFrame.maxY))
        ]
        return .split(distances.min { $0.distance < $1.distance }?.direction ?? .right)
    }
    private func targetWindowForDrop(cursor: CGPoint, moving: ManagedWindow, candidates: [ManagedWindow]) -> ManagedWindow? {
        let containing = candidates
            .filter { $0.frame.contains(cursor) }
            .min { lhs, rhs in lhs.frame.area < rhs.frame.area }
        if let containing { return containing }
        let overlapping = candidates.compactMap { candidate -> (window: ManagedWindow, area: CGFloat)? in
            let intersection = candidate.frame.intersection(moving.frame)
            let area = intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
            guard area > min(candidate.frame.area, moving.frame.area) * 0.08 else { return nil }
            return (candidate, area)
        }.max { lhs, rhs in lhs.area < rhs.area }
        if let overlapping { return overlapping.window }
        return candidates.min { lhs, rhs in
            lhs.frame.distanceSquared(to: cursor) < rhs.frame.distanceSquared(to: cursor)
        }
    }
    private func hasWindowSetChanged(_ windows: [ManagedWindow]) -> Bool {
        let grouped = Dictionary(grouping: windows, by: { $0.screen.stateKey })
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        let visibleStateKeysWithWindows = Set(screenStates.filter { key, state in
            activeStateKeys.contains(key) && !state.isEmpty
        }.map(\.key))
        if Set(grouped.keys) != visibleStateKeysWithWindows {
            return true
        }
        for (screenKey, screenWindows) in grouped {
            guard let state = screenStates[screenKey],
                  state.windowIDs == Set(screenWindows.map(\.id)) else {
                return true
            }
        }
        return false
    }
    private func focusNeighbor(direction: SnapDirection) {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key],
              let targetID = state.neighborID(from: focusedID, direction: direction),
              let targetWindow = allWindows.first(where: { $0.id == targetID }) else {
            NSSound.beep()
            return
        }
        state.markFocused(targetID)
        screenStates[key] = state
        focus(window: targetWindow, updateTreeFocus: true)
    }
    private func swapFocusedWindow(direction: SnapDirection) {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key],
              state.swapFocused(focusedID, direction: direction) else {
            NSSound.beep()
            return
        }
        screenStates[key] = state
        applyLayout(to: allWindows)
        if let window = allWindows.first(where: { $0.id == focusedID }) {
            focus(window: window, updateTreeFocus: true)
        }
    }
    private func resizeFocusedWindow(direction: SnapDirection) {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key],
              state.resizeFocused(focusedID, direction: direction) else {
            NSSound.beep()
            return
        }
        screenStates[key] = state
        applyLayout(to: allWindows)
        if let window = allWindows.first(where: { $0.id == focusedID }) {
            focus(window: window, updateTreeFocus: true)
        }
    }
    private func toggleFocusedSplitOrientation() {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key],
              state.toggleOrientation(focusedID: focusedID) else {
            NSSound.beep()
            return
        }
        screenStates[key] = state
        applyLayout(to: allWindows)
        if let window = allWindows.first(where: { $0.id == focusedID }) {
            focus(window: window, updateTreeFocus: true)
        }
    }
    private func moveFocusedWindowToDisplay(direction: SnapDirection) {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let focusedWindow = allWindows.first(where: { $0.id == focusedID }),
              let targetScreen = adjacentScreen(from: focusedWindow.screen, direction: direction),
              let sourceKey = stateKey(containing: focusedID),
              var sourceState = screenStates[sourceKey] else {
            NSSound.beep()
            return
        }
        sourceState.remove(focusedID)
        screenStates[sourceKey] = sourceState
        var targetState = screenStates[targetScreen.stateKey] ?? ScreenTileState()
        targetState.insertExisting(focusedID, near: targetState.lastFocusedOrLargestID, placement: .automatic)
        targetState.markFocused(focusedID)
        screenStates[targetScreen.stateKey] = targetState
        applyLayout(to: allWindows)
        focus(window: focusedWindow, updateTreeFocus: true)
    }
    private func createSpaceForFocusedDisplay() {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        let displayID = focusedID.flatMap { id in
            allWindows.first(where: { $0.id == id })?.screen.displayID
        } ?? NSScreen.main?.displayID
        pauseLayoutForSystemUI(duration: 1.70)
        suppressExternalChanges(for: 1.70)
        SpacesController.shared.createSpace(on: displayID) { [weak self] target in
            guard let self, !self.isStopping else { return }
            guard let target else {
                NSSound.beep()
                self.scheduleReconcile(delay: 0.35)
                return
            }
            _ = SpacesController.shared.switchToSpace(target)
            self.refreshStableSpaceIDsFromObservedScreens()
            self.pauseLayoutForSystemUI(duration: 0.35)
            self.suppressExternalChanges(for: 0.80)
            self.focusBorder.hide()
            self.scheduleReconcile(delay: 0.85)
        }
    }
    private func toggleFocusedFloating() {
        let allWindows = managedWindows()
        guard let focusedID = focusedWindowID(in: allWindows) else {
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
        UserDefaults.standard.set(!tilingEnabled, forKey: tilingEnabledDefaultsKey)
        if tilingEnabled {
            scheduleReconcile(delay: 0.01)
        } else {
            focusBorder.hide()
        }
    }
    private func balanceFocusedTree() {
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let key = stateKey(containing: focusedID),
              var state = screenStates[key] else {
            NSSound.beep()
            return
        }
        state.balance()
        state.markFocused(focusedID)
        screenStates[key] = state
        applyLayout(to: allWindows)
        if let window = allWindows.first(where: { $0.id == focusedID }) {
            focus(window: window, updateTreeFocus: true)
        }
    }
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
    }
    private func applyLayout(to windows: [ManagedWindow]) {
        guard !isStopping else { return }
        guard tilingEnabled else {
            focusBorder.hide()
            return
        }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let screens = currentScreenInfosByKey()
        pendingMove?.cancel()
        pendingResize?.cancel()
        suppressExternalChanges(for: 0.45)
        isApplyingLayout = true
        defer {
            isApplyingLayout = false
            suppressExternalChanges(for: 0.45)
        }
        for (screenKey, state) in screenStates where !state.isEmpty {
            guard let screen = screens[screenKey] ?? windows.first(where: { $0.screen.stateKey == screenKey })?.screen else {
                continue
            }
            for (id, slot) in state.slots {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let frame = slot.frame(in: screen.frame, gap: CGFloat(gapPixels), smartOuterGap: true)
                set(window: window.element, frame: frame)
            }
        }
        rememberPersistedLayouts(using: windows)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.updateFocusBorder(using: windows)
        }
    }
    private var isSuppressingExternalChanges: Bool {
        Date() < suppressExternalChangesUntil
    }
    private func suppressExternalChanges(for duration: TimeInterval) {
        suppressExternalChangesUntil = max(suppressExternalChangesUntil, Date().addingTimeInterval(duration))
    }
    private func pauseLayoutForSystemUI(duration: TimeInterval, preserveLayout: Bool = true) {
        guard !isStopping else { return }
        if preserveLayout {
            if frozenSystemUIScreenStates == nil {
                frozenSystemUIScreenStates = screenStates
            }
            frozenSystemUIActiveStateKeys = Set(currentScreenInfos().map(\.stateKey))
            resetSystemUIWindowSnapshotStability()
        } else if frozenSystemUIScreenStates == nil {
            resetSystemUIWindowSnapshotStability()
        }
        systemUILayoutPausedUntil = max(systemUILayoutPausedUntil, Date().addingTimeInterval(duration))
        pendingReconcile?.cancel()
        pendingFocusRemember?.cancel()
        pendingMove?.cancel()
        pendingResize?.cancel()
        if preserveLayout {
            scheduleSystemUISettleCheck(delay: max(0.35, duration + 0.10))
        }
    }
    private func shouldPauseLayoutForSystemUI() -> Bool {
        if Date() < systemUILayoutPausedUntil { return true }
        if isMissionControlLikelyActive() {
            pauseLayoutForSystemUI(duration: 1.20, preserveLayout: true)
            return true
        }
        return false
    }
    private func isMissionControlLikelyActive() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastMissionControlActivityCheck) >= missionControlActivityCacheDuration else {
            return cachedMissionControlLikelyActive
        }
        cachedMissionControlLikelyActive = SystemUIActivity.isMissionControlLikelyActive()
        lastMissionControlActivityCheck = now
        return cachedMissionControlLikelyActive
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
            resetSystemUIWindowSnapshotStability()
            return
        }
        if Date() < systemUILayoutPausedUntil || isMissionControlLikelyActive() {
            pauseLayoutForSystemUI(duration: 0.80, preserveLayout: true)
            return
        }
        refreshAppObservers()
        let allWindows = managedWindows()
        let tiled = tiledWindows(from: allWindows)
        guard isSystemUIWindowSnapshotStable(tiled) else {
            scheduleSystemUISettleCheck(delay: 0.35)
            return
        }
        let restoredFrozenLayout = restoreFrozenStatesIfWindowSetUnchanged(using: tiled)
        let restoredIdentityLayout = restoreKnownLayoutIdentities(using: tiled, sourceStates: frozenSystemUIScreenStates)
        let restoredPersistedLayout = restorePersistedLayouts(using: tiled)
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        resetSystemUIWindowSnapshotStability()
        if hasWindowSetChanged(tiled) {
            scheduleReconcile(delay: 0.05)
        } else if restoredFrozenLayout || restoredIdentityLayout || restoredPersistedLayout {
            applyLayout(to: allWindows)
        } else {
            updateFocusBorder(using: allWindows)
        }
    }
    private func isSystemUIWindowSnapshotStable(_ windows: [ManagedWindow]) -> Bool {
        if systemUISettleBeganAt == nil {
            systemUISettleBeganAt = Date()
        }
        if shouldKeepWaitingForFrozenWindows(toReappearIn: windows) {
            lastSystemUIWindowSnapshot = nil
            stableSystemUIWindowSnapshotCount = 0
            return false
        }
        let snapshot = SystemUIWindowSnapshot(windows: windows)
        if snapshot == lastSystemUIWindowSnapshot {
            stableSystemUIWindowSnapshotCount += 1
        } else {
            lastSystemUIWindowSnapshot = snapshot
            stableSystemUIWindowSnapshotCount = 1
        }
        return stableSystemUIWindowSnapshotCount >= requiredStableSystemUIWindowSnapshotCount
    }
    private func shouldKeepWaitingForFrozenWindows(toReappearIn windows: [ManagedWindow]) -> Bool {
        guard let frozenSystemUIScreenStates,
              let systemUISettleBeganAt,
              Date().timeIntervalSince(systemUISettleBeganAt) < missingFrozenWindowGraceAfterSystemUI else {
            return false
        }
        let frozenStatesToWaitFor: [ScreenTileState]
        if let frozenSystemUIActiveStateKeys {
            frozenStatesToWaitFor = frozenSystemUIScreenStates.compactMap { key, state in
                frozenSystemUIActiveStateKeys.contains(key) ? state : nil
            }
        } else {
            frozenStatesToWaitFor = Array(frozenSystemUIScreenStates.values)
        }
        let frozenIDs = Set(frozenStatesToWaitFor.flatMap(\.windowIDs))
        guard !frozenIDs.isEmpty else { return false }
        let liveIDs = Set(windows.map(\.id))
        guard !frozenIDs.isSubset(of: liveIDs) else { return false }
        let missingIDs = frozenIDs.subtracting(liveIDs)
        let appearedWindows = windows.filter { !frozenIDs.contains($0.id) }
        let appearedLayoutIdentities = layoutIdentityItems(forWindows: appearedWindows)
        let matchedMissingIDs = Set(WindowLayoutIdentityMatcher.replacements(
            stored: layoutIdentityItems(forStoredIDs: missingIDs),
            visible: appearedLayoutIdentities
        ).keys)
        let stillMissing = missingIDs.subtracting(matchedMissingIDs)
        return !stillMissing.isEmpty
    }
    private func resetSystemUIWindowSnapshotStability() {
        lastSystemUIWindowSnapshot = nil
        stableSystemUIWindowSnapshotCount = 0
        systemUISettleBeganAt = nil
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
            guard keyHasExplicitSpace(key) == false,
                  let fallback = frozenSystemUIScreenStates.first(where: { frozenKey, frozenState in
                    displayKeyComponent(of: frozenKey) == displayKeyComponent(of: key) && frozenState.windowIDs == ids
                  }) else {
                continue
            }
            if !keyHasExplicitSpace(fallback.key) {
                screenStates.removeValue(forKey: fallback.key)
            }
            screenStates[key] = fallback.value
            restored = true
        }
        return restored
    }
    private func displayKeyComponent(of stateKey: String) -> String {
        guard let range = stateKey.range(of: ":space:") else { return stateKey }
        return String(stateKey[..<range.lowerBound])
    }
    private func keyHasExplicitSpace(_ stateKey: String) -> Bool {
        stateKey.contains(":space:")
    }
    private func tiledWindows(from windows: [ManagedWindow]) -> [ManagedWindow] {
        guard tilingEnabled else { return [] }
        restoreFloatingLayoutIdentities(using: windows)
        return windows.filter { !floatingWindowIDs.contains($0.id) }
    }
    private func updateVisibleFloatingWindowStateKeys(using windows: [ManagedWindow]) {
        for window in windows where floatingWindowIDs.contains(window.id) {
            floatingWindowStateKeys[window.id] = window.screen.stateKey
        }
    }
    private func removeFloatingWindowID(forDestroyedElement element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        let windowKey = copyInt(element, attribute: "AXWindowNumber")
            .map { WindowOrderKey(pid: pid, number: $0) }
            ?? copyInt(element, attribute: "_AXWindowNumber")
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
                stored: layoutIdentityItems(forStoredIDs: storedIDs),
                visible: layoutIdentityItems(forWindows: visibleWindows)
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
            guard let storedKey = storedStateKeyForLayoutRestore(currentKey: currentKey, windows: screenWindows, states: states),
                  let state = states[storedKey],
                  let screen = screenWindows.first?.screen else {
                continue
            }
            if sourceStates != nil || storedKey != currentKey {
                screenStates[currentKey] = state
                if storedKey != currentKey, !keyHasExplicitSpace(storedKey) {
                    screenStates.removeValue(forKey: storedKey)
                }
                restored = true
            }
            replacements.merge(
                identityReplacements(for: state, on: screen, currentWindows: screenWindows),
                uniquingKeysWith: { existing, _ in existing }
            )
        }
        guard !replacements.isEmpty else { return restored }
        applyLayoutIdentityRemapping(replacements)
        return true
    }
    private func storedStateKeyForLayoutRestore(
        currentKey: String,
        windows: [ManagedWindow],
        states: [String: ScreenTileState]
    ) -> String? {
        if states[currentKey] != nil { return currentKey }
        guard !keyHasExplicitSpace(currentKey) else { return nil }
        let currentLayoutIdentities = layoutIdentityItems(forWindows: windows)
        guard !currentLayoutIdentities.isEmpty else { return nil }
        let currentDisplayKey = displayKeyComponent(of: currentKey)
        var bestMatch: (key: String, count: Int)?
        var hasAmbiguousBestMatch = false
        for (storedKey, state) in states where displayKeyComponent(of: storedKey) == currentDisplayKey {
            let storedLayoutIdentities = layoutIdentityItems(forStoredIDs: state.windowIDs)
            let expectedMatches = min(storedLayoutIdentities.count, currentLayoutIdentities.count)
            guard expectedMatches > 0 else { continue }
            let matches = WindowLayoutIdentityMatcher.replacements(
                stored: storedLayoutIdentities,
                visible: currentLayoutIdentities
            ).count
            guard matches == expectedMatches else { continue }
            if bestMatch == nil || matches > bestMatch!.count {
                bestMatch = (key: storedKey, count: matches)
                hasAmbiguousBestMatch = false
            } else if matches == bestMatch!.count {
                hasAmbiguousBestMatch = true
            }
        }
        guard !hasAmbiguousBestMatch else { return nil }
        return bestMatch?.key
    }
    private func identityReplacements(
        for state: ScreenTileState,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow]
    ) -> [WindowIdentity: WindowIdentity] {
        let stateIDs = state.windowIDs
        let currentIDs = Set(currentWindows.map(\.id))
        var missingStateIDs = stateIDs.subtracting(currentIDs)
        var appearingWindows = currentWindows.filter { !stateIDs.contains($0.id) }
        guard !missingStateIDs.isEmpty, !appearingWindows.isEmpty else { return [:] }
        var replacements: [WindowIdentity: WindowIdentity] = [:]
        replacements.merge(
            WindowLayoutIdentityMatcher.replacements(
                stored: layoutIdentityItems(forStoredIDs: missingStateIDs),
                visible: layoutIdentityItems(forWindows: appearingWindows)
            ),
            uniquingKeysWith: { existing, _ in existing }
        )
        missingStateIDs.subtract(Set(replacements.keys))
        let usedVisibleIDs = Set(replacements.values)
        appearingWindows.removeAll { usedVisibleIDs.contains($0.id) }
        replacements.merge(
            frameBasedIdentityReplacements(
                forStoredIDs: missingStateIDs,
                in: state,
                on: screen,
                currentWindows: appearingWindows
            ),
            uniquingKeysWith: { existing, _ in existing }
        )
        return replacements
    }
    private func frameBasedIdentityReplacements(
        forStoredIDs storedIDs: Set<WindowIdentity>,
        in state: ScreenTileState,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow]
    ) -> [WindowIdentity: WindowIdentity] {
        guard !storedIDs.isEmpty, !currentWindows.isEmpty else { return [:] }
        let slots = state.slots
        var candidates: [(storedID: WindowIdentity, visibleID: WindowIdentity, score: CGFloat)] = []
        for storedID in storedIDs {
            guard let slot = slots[storedID] else { continue }
            let expectedFrame = slot.frame(in: screen.frame, gap: CGFloat(gapPixels), smartOuterGap: true)
            for window in currentWindows where window.id.pid == storedID.pid {
                let score = expectedFrame.frameSimilarityScore(to: window.frame)
                guard score <= maximumLayoutRestoreFrameScore else { continue }
                candidates.append((storedID: storedID, visibleID: window.id, score: score))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.storedID.pid != rhs.storedID.pid { return lhs.storedID.pid < rhs.storedID.pid }
            if lhs.storedID.serial != rhs.storedID.serial { return lhs.storedID.serial < rhs.storedID.serial }
            return lhs.visibleID.serial < rhs.visibleID.serial
        }
        var replacements: [WindowIdentity: WindowIdentity] = [:]
        var usedStoredIDs: Set<WindowIdentity> = []
        var usedVisibleIDs: Set<WindowIdentity> = []
        for candidate in candidates {
            guard !usedStoredIDs.contains(candidate.storedID),
                  !usedVisibleIDs.contains(candidate.visibleID) else {
                continue
            }
            usedStoredIDs.insert(candidate.storedID)
            usedVisibleIDs.insert(candidate.visibleID)
            replacements[candidate.storedID] = candidate.visibleID
        }
        return replacements
    }
    private func layoutIdentityItems(forStoredIDs ids: Set<WindowIdentity>) -> [(id: WindowIdentity, identity: WindowLayoutIdentity)] {
        ids.compactMap { id in
            guard let layoutIdentity = layoutIdentityByWindowID[id] else { return nil }
            return (id: id, identity: layoutIdentity)
        }
    }
    private func layoutIdentityItems(forWindows windows: [ManagedWindow]) -> [(id: WindowIdentity, identity: WindowLayoutIdentity)] {
        windows.compactMap { window in
            guard let layoutIdentity = window.layoutIdentity else { return nil }
            return (id: window.id, identity: layoutIdentity)
        }
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
        var restored = false
        for (currentKey, screenWindows) in grouped {
            guard let screen = screenWindows.first?.screen else { continue }
            for snapshot in persistedLayoutCandidates(for: currentKey) {
                guard let state = restoredState(from: snapshot, on: screen, currentWindows: screenWindows) else {
                    continue
                }
                screenStates[currentKey] = state
                if snapshot.stateKey != currentKey, !keyHasExplicitSpace(snapshot.stateKey) {
                    screenStates.removeValue(forKey: snapshot.stateKey)
                }
                restored = true
                break
            }
        }
        return restored
    }
    private func persistedLayoutCandidates(for currentKey: String) -> [PersistedScreenLayout] {
        var candidates: [PersistedScreenLayout] = []
        if let exact = persistedLayoutsByStateKey[currentKey] {
            candidates.append(exact)
        }
        guard !keyHasExplicitSpace(currentKey) else { return candidates }
        let currentDisplayKey = displayKeyComponent(of: currentKey)
        let fallbackCandidates = persistedLayoutsByStateKey.values
            .filter { $0.stateKey != currentKey && $0.displayKey == currentDisplayKey }
            .sorted { lhs, rhs in
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                return lhs.stateKey < rhs.stateKey
            }
        candidates.append(contentsOf: fallbackCandidates)
        return candidates
    }
    private func restoredState(
        from snapshot: PersistedScreenLayout,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow]
    ) -> ScreenTileState? {
        guard !snapshot.entriesByID.isEmpty, !currentWindows.isEmpty else { return nil }
        let storedLayoutIdentityItems: [(id: Int, identity: WindowLayoutIdentity)] = snapshot.entriesByID.values.compactMap { entry in
            guard let layoutIdentity = entry.layoutIdentity else { return nil }
            return (id: entry.id, identity: layoutIdentity)
        }
        var entryIDToWindowID = WindowLayoutIdentityMatcher.replacements(
            stored: storedLayoutIdentityItems,
            visible: layoutIdentityItems(forWindows: currentWindows)
        )
        let usedWindowIDs = Set(entryIDToWindowID.values)
        entryIDToWindowID.merge(
            frameBasedPersistedLayoutReplacements(
                from: snapshot,
                on: screen,
                currentWindows: currentWindows.filter { !usedWindowIDs.contains($0.id) },
                excludingEntryIDs: Set(entryIDToWindowID.keys)
            ),
            uniquingKeysWith: { existing, _ in existing }
        )
        let secondPassUsedWindowIDs = Set(entryIDToWindowID.values)
        entryIDToWindowID.merge(
            orderBasedPersistedLayoutReplacements(
                from: snapshot,
                currentWindows: currentWindows.filter { !secondPassUsedWindowIDs.contains($0.id) },
                excludingEntryIDs: Set(entryIDToWindowID.keys)
            ),
            uniquingKeysWith: { existing, _ in existing }
        )
        guard let tree = snapshot.tree.compactMapIDs({ entryIDToWindowID[$0] }) else { return nil }
        let focusedID = snapshot.lastFocusedEntryID.flatMap { entryIDToWindowID[$0] }
        return ScreenTileState(tree: tree, lastFocusedID: focusedID)
    }
    private func frameBasedPersistedLayoutReplacements(
        from snapshot: PersistedScreenLayout,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow],
        excludingEntryIDs excludedEntryIDs: Set<Int>
    ) -> [Int: WindowIdentity] {
        guard !currentWindows.isEmpty else { return [:] }
        let slots = snapshot.tree.slots()
        var candidates: [(entryID: Int, windowID: WindowIdentity, score: CGFloat)] = []
        for (entryID, entry) in snapshot.entriesByID where !excludedEntryIDs.contains(entryID) {
            guard let slot = slots[entryID] else { continue }
            let expectedFrame = slot.frame(in: screen.frame, gap: CGFloat(gapPixels), smartOuterGap: true)
            for window in currentWindows where persistedEntry(entry, canFrameMatch: window) {
                let score = expectedFrame.frameSimilarityScore(to: window.frame)
                guard score <= maximumLayoutRestoreFrameScore else { continue }
                candidates.append((entryID: entryID, windowID: window.id, score: score))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.entryID != rhs.entryID { return lhs.entryID < rhs.entryID }
            return lhs.windowID.serial < rhs.windowID.serial
        }
        var replacements: [Int: WindowIdentity] = [:]
        var usedEntries: Set<Int> = []
        var usedWindows: Set<WindowIdentity> = []
        for candidate in candidates {
            guard !usedEntries.contains(candidate.entryID),
                  !usedWindows.contains(candidate.windowID) else {
                continue
            }
            replacements[candidate.entryID] = candidate.windowID
            usedEntries.insert(candidate.entryID)
            usedWindows.insert(candidate.windowID)
        }
        return replacements
    }
    private func orderBasedPersistedLayoutReplacements(
        from snapshot: PersistedScreenLayout,
        currentWindows: [ManagedWindow],
        excludingEntryIDs excludedEntryIDs: Set<Int>
    ) -> [Int: WindowIdentity] {
        guard !currentWindows.isEmpty else { return [:] }
        let remainingEntries = snapshot.entriesByID.values.filter { !excludedEntryIDs.contains($0.id) }
        let entriesByGroup = Dictionary(grouping: remainingEntries, by: persistedWindowGroupKey)
        let windowsByGroup = Dictionary(grouping: currentWindows, by: persistedWindowGroupKey)
        var replacements: [Int: WindowIdentity] = [:]
        for (groupKey, entries) in entriesByGroup {
            guard let windows = windowsByGroup[groupKey], entries.count == windows.count else { continue }
            let sortedEntries = entries.sorted {
                if $0.orderRank != $1.orderRank { return ($0.orderRank ?? Int.max) < ($1.orderRank ?? Int.max) }
                if $0.scanIndex != $1.scanIndex { return $0.scanIndex < $1.scanIndex }
                return $0.id < $1.id
            }
            let sortedWindows = windows.sorted {
                if $0.orderRank != $1.orderRank { return ($0.orderRank ?? Int.max) < ($1.orderRank ?? Int.max) }
                if $0.scanIndex != $1.scanIndex { return $0.scanIndex < $1.scanIndex }
                return $0.id.serial < $1.id.serial
            }
            for (entry, window) in zip(sortedEntries, sortedWindows) {
                replacements[entry.id] = window.id
            }
        }
        return replacements
    }
    private func persistedEntry(_ entry: PersistedWindowLayoutEntry, canFrameMatch window: ManagedWindow) -> Bool {
        entry.pid == window.id.pid && (entry.bundleIdentifier == nil || window.bundleIdentifier == nil || entry.bundleIdentifier == window.bundleIdentifier)
    }
    private func persistedWindowGroupKey(for entry: PersistedWindowLayoutEntry) -> PersistedWindowGroupKey {
        PersistedWindowGroupKey(pid: entry.pid, bundleIdentifier: entry.bundleIdentifier)
    }
    private func persistedWindowGroupKey(for window: ManagedWindow) -> PersistedWindowGroupKey {
        PersistedWindowGroupKey(pid: window.id.pid, bundleIdentifier: window.bundleIdentifier)
    }
    private func rememberPersistedLayouts(using windows: [ManagedWindow]) {
        guard !windows.isEmpty else { return }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (stateKey, state) in screenStates where !state.isEmpty {
            let slotList = state.slotList
            guard !slotList.isEmpty else { continue }
            var entryIDByWindowID: [WindowIdentity: Int] = [:]
            var entriesByID: [Int: PersistedWindowLayoutEntry] = [:]
            var nextEntryID = 1
            var canSnapshot = true
            for item in slotList {
                guard let window = windowsByID[item.id] else {
                    canSnapshot = false
                    break
                }
                let entryID = nextEntryID
                nextEntryID += 1
                entryIDByWindowID[item.id] = entryID
                entriesByID[entryID] = PersistedWindowLayoutEntry(
                    id: entryID,
                    pid: window.id.pid,
                    bundleIdentifier: window.bundleIdentifier,
                    layoutIdentity: window.layoutIdentity ?? layoutIdentityByWindowID[window.id],
                    orderRank: window.orderRank,
                    scanIndex: window.scanIndex
                )
            }
            guard canSnapshot,
                  let tree = state.compactMapWindowIDs({ entryIDByWindowID[$0] }) else {
                continue
            }
            persistedLayoutsByStateKey[stateKey] = PersistedScreenLayout(
                stateKey: stateKey,
                displayKey: displayKeyComponent(of: stateKey),
                tree: tree,
                entriesByID: entriesByID,
                lastFocusedEntryID: state.focusedWindowID.flatMap { entryIDByWindowID[$0] },
                lastUpdated: Date()
            )
        }
    }

    private func retainedOffscreenWindowIDs(activeStateKeys: Set<String>) -> Set<WindowIdentity> {
        var retainedIDs: Set<WindowIdentity> = []
        if let frozenSystemUIScreenStates {
            retainedIDs.formUnion(frozenSystemUIScreenStates.values.flatMap(\.windowIDs))
        }
        let inactiveStateIDs = screenStates
            .filter { !activeStateKeys.contains($0.key) }
            .values
            .flatMap(\.windowIDs)
        retainedIDs.formUnion(inactiveStateIDs)
        retainedIDs.formUnion(floatingWindowIDs)
        return retainedIDs
    }
    private func stateKey(containing id: WindowIdentity) -> String? {
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        return screenStates.first { activeStateKeys.contains($0.key) && $0.value.contains(id) }?.key
            ?? screenStates.first { $0.value.contains(id) }?.key
    }
    private func managedWindows() -> [ManagedWindow] {
        managedWindows(snapshot: onScreenWindowSnapshot())
    }
    private func managedWindows(snapshot: OnScreenWindowSnapshot) -> [ManagedWindow] {
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: snapshot)
        let apps = NSWorkspace.shared.runningApplications
            .filter(isManageableApp)
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }
        var candidates: [ManagedWindowCandidate] = []
        var scanIndex = 0
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let appWindows = copyAXElements(appElement, attribute: kAXWindowsAttribute)
            for window in appWindows {
                guard let position = copyCGPoint(window, attribute: kAXPositionAttribute),
                      let size = copyCGSize(window, attribute: kAXSizeAttribute),
                      size.width >= TileLayout.minimumWindowFrameSize.width,
                      size.height >= TileLayout.minimumWindowFrameSize.height else {
                    continue
                }
                let frame = CGRect(origin: position, size: size)
                let title = copyString(window, attribute: kAXTitleAttribute)
                guard frameIntersectsAnyVisibleScreen(frame),
                      isManageableWindow(window, app: app, frame: frame, title: title) else {
                    continue
                }
                let screen = screenInfo(for: frame)
                candidates.append(ManagedWindowCandidate(
                    pid: app.processIdentifier,
                    windowNumber: copyInt(window, attribute: "AXWindowNumber")
                        ?? copyInt(window, attribute: "_AXWindowNumber"),
                    elementKey: WindowElementKey(pid: app.processIdentifier, hash: CFHash(window)),
                    signature: windowSignature(for: window, app: app, title: title, stateKey: screen.stateKey),
                    layoutIdentity: windowLayoutIdentity(for: window, app: app, title: title),
                    element: window,
                    screen: screen,
                    frame: frame,
                    bundleIdentifier: app.bundleIdentifier,
                    title: title,
                    orderRank: nil,
                    scanIndex: scanIndex
                ))
                scanIndex += 1
            }
        }
        var visibleCandidates: [ManagedWindowCandidate] = []
        var claimedNumbersByPID: [pid_t: Set<Int>] = [:]
        for var candidate in candidates {
            let number: Int
            if let candidateNumber = candidate.windowNumber {
                guard snapshot.visibleNumbersByPID[candidate.pid]?.contains(candidateNumber) == true else {
                    continue
                }
                number = candidateNumber
            } else {
                guard let matchedNumber = snapshot.matchWindowNumber(
                    pid: candidate.pid,
                    frame: candidate.frame,
                    title: candidate.title,
                    excluding: claimedNumbersByPID[candidate.pid] ?? []
                ) else {
                    continue
                }
                candidate.windowNumber = matchedNumber
                number = matchedNumber
            }
            guard claimedNumbersByPID[candidate.pid]?.contains(number) != true else {
                continue
            }
            claimedNumbersByPID[candidate.pid, default: []].insert(number)
            candidate.orderRank = snapshot.rankByWindow[WindowOrderKey(pid: candidate.pid, number: number)]
            visibleCandidates.append(candidate)
        }
        candidates = visibleCandidates
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        let retainedOffscreenIDs = retainedOffscreenWindowIDs(activeStateKeys: activeStateKeys)
        let stronglyVisibleIDs = Set(candidates.compactMap { candidate -> WindowIdentity? in
            let windowKey = candidate.windowNumber.map { WindowOrderKey(pid: candidate.pid, number: $0) }
            return identityRegistry.identityForStrongAlias(windowKey: windowKey, elementKey: candidate.elementKey)
        })
        identityRegistry.retainAliases(for: stronglyVisibleIDs.union(retainedOffscreenIDs))
        let signatureCounts = candidates.reduce(into: [WindowSignature: Int]()) { counts, candidate in
            guard let signature = candidate.signature else { return }
            counts[signature, default: 0] += 1
        }
        var windows: [ManagedWindow] = []
        var seenIDs: Set<WindowIdentity> = []
        for candidate in candidates {
            let windowKey = candidate.windowNumber.map { WindowOrderKey(pid: candidate.pid, number: $0) }
            let uniqueSignature = candidate.signature.flatMap { signatureCounts[$0] == 1 ? $0 : nil }
            let id = identityRegistry.identity(
                for: windowKey,
                elementKey: candidate.elementKey,
                signature: uniqueSignature,
                avoidingIdentities: seenIDs
            )
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)
            windows.append(ManagedWindow(
                id: id,
                windowNumber: candidate.windowNumber,
                element: candidate.element,
                screen: candidate.screen,
                layoutIdentity: candidate.layoutIdentity,
                frame: candidate.frame,
                bundleIdentifier: candidate.bundleIdentifier,
                title: candidate.title,
                orderRank: candidate.orderRank,
                scanIndex: candidate.scanIndex
            ))
        }
        updateVisibleFloatingWindowStateKeys(using: windows)
        rememberLayoutIdentities(using: windows)
        var retainedIDs = seenIDs
        retainedIDs.formUnion(retainedOffscreenIDs)
        identityRegistry.retainAliases(for: retainedIDs)
        pruneLayoutIdentityCache(retainingVisibleIDs: seenIDs.union(retainedOffscreenIDs))
        return windows.sorted(by: shouldOrderBefore)
    }
    private func windowSignature(for window: AXUIElement, app: NSRunningApplication, title: String?, stateKey: String) -> WindowSignature? {
        let signature = WindowSignature(
            pid: app.processIdentifier,
            stateKey: stateKey,
            bundleIdentifier: normalizedWindowString(app.bundleIdentifier),
            axIdentifier: normalizedWindowString(copyString(window, attribute: "AXIdentifier")),
            document: normalizedWindowString(copyString(window, attribute: kAXDocumentAttribute)),
            title: normalizedWindowString(title)
        )
        return signature.hasStableComponent ? signature : nil
    }
    private func windowLayoutIdentity(for window: AXUIElement, app: NSRunningApplication, title: String?) -> WindowLayoutIdentity? {
        let identity = WindowLayoutIdentity(
            pid: app.processIdentifier,
            bundleIdentifier: normalizedWindowString(app.bundleIdentifier),
            axIdentifier: normalizedWindowString(copyString(window, attribute: "AXIdentifier")),
            document: normalizedWindowString(copyString(window, attribute: kAXDocumentAttribute)),
            title: normalizedWindowString(title)
        )
        return identity.hasStableComponent ? identity : nil
    }
    private func normalizedWindowString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
    private func isObservableApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              app.bundleIdentifier != appBundleIdentifier else {
            return false
        }
        return true
    }
    private func isManageableApp(_ app: NSRunningApplication) -> Bool {
        isObservableApp(app) && !app.isHidden
    }
    private func isManageableWindow(_ window: AXUIElement, app _: NSRunningApplication, frame: CGRect, title: String?) -> Bool {
        guard copyString(window, attribute: kAXRoleAttribute) == kAXWindowRole else { return false }
        let subrole = copyString(window, attribute: kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }
        if copyBool(window, attribute: kAXMinimizedAttribute) == true ||
            copyBool(window, attribute: "AXFullScreen") == true ||
            copyBool(window, attribute: "AXModal") == true {
            return false
        }
        if frame.width < TileLayout.minimumWindowFrameSize.width ||
            frame.height < TileLayout.minimumWindowFrameSize.height {
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
        return copyAXValue(window, attribute: kAXPositionAttribute) != nil &&
            copyAXValue(window, attribute: kAXSizeAttribute) != nil
    }
    private func focusedWindowID(in windows: [ManagedWindow]) -> WindowIdentity? {
        guard let focusedWindow = focusedWindow() else { return nil }
        if let exactMatch = windows.first(where: { CFEqual($0.element, focusedWindow) }) {
            return exactMatch.id
        }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &focusedPID) == .success else { return nil }
        if let number = copyInt(focusedWindow, attribute: "AXWindowNumber") ?? copyInt(focusedWindow, attribute: "_AXWindowNumber") {
            return windows.first { $0.id.pid == focusedPID && $0.windowNumber == number }?.id
        }
        return windows.first { candidate in
            candidate.id.pid == focusedPID && windowsRepresentSameWindow(candidate.element, focusedWindow)
        }?.id
    }
    private func focusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = copyAXElement(systemWide, attribute: kAXFocusedWindowAttribute) {
            return focused
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != appBundleIdentifier else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return copyAXElement(axApp, attribute: kAXFocusedWindowAttribute)
    }
    private func window(matching element: AXUIElement, in windows: [ManagedWindow]) -> ManagedWindow? {
        if let exact = windows.first(where: { CFEqual($0.element, element) }) {
            return exact
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        if let number = copyInt(element, attribute: "AXWindowNumber") ?? copyInt(element, attribute: "_AXWindowNumber") {
            return windows.first { $0.id.pid == pid && $0.windowNumber == number }
        }
        return windows.first { candidate in
            candidate.id.pid == pid && windowsRepresentSameWindow(candidate.element, element)
        }
    }
    private func windowsRepresentSameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        let lhsWindowNumber = copyInt(lhs, attribute: "AXWindowNumber") ?? copyInt(lhs, attribute: "_AXWindowNumber")
        let rhsWindowNumber = copyInt(rhs, attribute: "AXWindowNumber") ?? copyInt(rhs, attribute: "_AXWindowNumber")
        if let lhsWindowNumber, let rhsWindowNumber {
            return lhsWindowNumber == rhsWindowNumber
        }
        let lhsIdentifier = copyString(lhs, attribute: "AXIdentifier")
        let rhsIdentifier = copyString(rhs, attribute: "AXIdentifier")
        if let lhsIdentifier, !lhsIdentifier.isEmpty, let rhsIdentifier, !rhsIdentifier.isEmpty {
            return lhsIdentifier == rhsIdentifier
        }
        guard copyString(lhs, attribute: kAXTitleAttribute) == copyString(rhs, attribute: kAXTitleAttribute),
              let lhsPosition = copyCGPoint(lhs, attribute: kAXPositionAttribute),
              let rhsPosition = copyCGPoint(rhs, attribute: kAXPositionAttribute),
              let lhsSize = copyCGSize(lhs, attribute: kAXSizeAttribute),
              let rhsSize = copyCGSize(rhs, attribute: kAXSizeAttribute) else {
            return false
        }
        return approximatelyEqual(lhsPosition, rhsPosition) && approximatelyEqual(lhsSize, rhsSize)
    }
    private func focus(window: ManagedWindow, updateTreeFocus: Bool) {
        if let app = NSRunningApplication(processIdentifier: window.id.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let appElement = AXUIElementCreateApplication(window.id.pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if updateTreeFocus, let key = stateKey(containing: window.id), var state = screenStates[key] {
            state.markFocused(window.id)
            screenStates[key] = state
        }
        showFocusBorder(for: window)
    }
    private func notificationToken(for window: AXUIElement, fallbackIndex: Int) -> String {
        if let number = copyInt(window, attribute: "AXWindowNumber") ?? copyInt(window, attribute: "_AXWindowNumber") {
            return "number:\(number)"
        }
        if let identifier = copyString(window, attribute: "AXIdentifier"), !identifier.isEmpty {
            return "identifier:\(identifier)"
        }
        let title = copyString(window, attribute: kAXTitleAttribute) ?? ""
        let hash = CFHash(window)
        return "fallback:\(hash):\(title):\(fallbackIndex)"
    }
    private func set(window: AXUIElement, frame: CGRect) {
        let frame = sanitizedFrame(frame)
        if let actual = actualFrame(for: window), approximatelyEqual(actual, frame) {
            return
        }
        applyFrame(frame, to: window)
        if let actual = actualFrame(for: window), !approximatelyEqual(actual, frame) {
            applyFrame(frame, to: window)
        }
    }
    private func applyFrame(_ frame: CGRect, to window: AXUIElement) {
        var size = frame.size
        var origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)
        let positionValue = AXValueCreate(.cgPoint, &origin)
        // Setting size first avoids macOS clamping a position against an old oversized frame.
        if let sizeValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let positionValue {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }
    private func actualFrame(for window: AXUIElement) -> CGRect? {
        guard let position = copyCGPoint(window, attribute: kAXPositionAttribute),
              let size = copyCGSize(window, attribute: kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
    private func sanitizedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }
    private func updateFocusBorder(using windows: [ManagedWindow]) {
        guard tilingEnabled,
              borderEnabled,
              let focusedID = focusedWindowID(in: windows),
              !floatingWindowIDs.contains(focusedID),
              stateKey(containing: focusedID) != nil,
              let focusedWindow = windows.first(where: { $0.id == focusedID }) else {
            focusBorder.hide()
            return
        }
        showFocusBorder(for: focusedWindow)
    }
    private func showFocusBorder(for window: ManagedWindow) {
        guard tilingEnabled, borderEnabled, !floatingWindowIDs.contains(window.id), stateKey(containing: window.id) != nil else {
            focusBorder.hide()
            return
        }
        focusBorder.show(accessibilityFrame: actualFrame(for: window.element) ?? window.frame, color: borderColor)
    }
    private func refreshFocusBorder() {
        guard hasAccessibilityPermission(prompt: false), tilingEnabled else {
            focusBorder.hide()
            return
        }
        updateFocusBorder(using: managedWindows())
    }
    private func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }
    private func copyAXElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == CFArrayGetTypeID() else {
            return []
        }
        return (rawValue as? [AXUIElement]) ?? []
    }
    private func copyCGPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }
    private func copyCGSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
    private func copyAXValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        return (rawValue as! AXValue)
    }
    private func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return rawValue as? String
    }
    private func copyBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return rawValue as? Bool
    }
    private func copyInt(_ element: AXUIElement, attribute: String) -> Int? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        if let intValue = rawValue as? Int { return intValue }
        return (rawValue as? NSNumber)?.intValue
    }
    private func currentScreenInfosByKey() -> [String: ScreenInfo] {
        Dictionary(uniqueKeysWithValues: currentScreenInfos().map { ($0.stateKey, $0) })
    }
    private func currentScreenInfos() -> [ScreenInfo] {
        let missionControlLikelyActive = isMissionControlLikelyActive()
        return NSScreen.screens.map { screen in
            let displayID = screen.displayID
            let displayKey = ScreenInfo.displayKey(for: displayID, frame: screen.frame)
            return ScreenInfo(
                key: displayKey,
                frame: accessibilityVisibleFrame(for: screen),
                displayID: displayID,
                activeSpaceID: stableActiveSpaceID(
                    for: displayID,
                    displayKey: displayKey,
                    missionControlLikelyActive: missionControlLikelyActive
                )
            )
        }
    }
    private func stableActiveSpaceID(
        for displayID: CGDirectDisplayID?,
        displayKey: String,
        missionControlLikelyActive: Bool
    ) -> SpaceID? {
        let observed = SpacesController.shared.currentUserSpaceID(for: displayID)
        if Date() < systemUILayoutPausedUntil || missionControlLikelyActive {
            return stableSpaceIDByDisplayKey[displayKey] ?? observed
        }
        if let observed {
            stableSpaceIDByDisplayKey[displayKey] = observed
            return observed
        }
        return stableSpaceIDByDisplayKey[displayKey]
    }
    private func refreshStableSpaceIDsFromObservedScreens() {
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            let displayKey = ScreenInfo.displayKey(for: displayID, frame: screen.frame)
            if let observed = SpacesController.shared.currentUserSpaceID(for: displayID) {
                stableSpaceIDByDisplayKey[displayKey] = observed
            }
        }
    }
    private func screenInfo(for windowRect: CGRect) -> ScreenInfo {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        let screens = currentScreenInfos()
        if let bestIndex = ScreenGeometry.bestScreenIndex(for: windowRect, screens: screens.map(\.frame)) {
            return screens[bestIndex]
        }
        if let containingScreen = screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen
        }
        return screens.min { lhs, rhs in
            lhs.frame.distanceSquared(to: center) < rhs.frame.distanceSquared(to: center)
        } ?? ScreenInfo(key: "fallback", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), displayID: nil, activeSpaceID: nil)
    }
    private func adjacentScreen(from source: ScreenInfo, direction: SnapDirection) -> ScreenInfo? {
        let sourceCenter = CGPoint(x: source.frame.midX, y: source.frame.midY)
        return currentScreenInfos().filter { candidate in
            guard candidate.key != source.key else { return false }
            let center = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            switch direction {
            case .left: return center.x < sourceCenter.x
            case .right: return center.x > sourceCenter.x
            case .up: return center.y < sourceCenter.y
            case .down: return center.y > sourceCenter.y
            }
        }.min { lhs, rhs in
            lhs.frame.centerDistanceSquared(to: sourceCenter) < rhs.frame.centerDistanceSquared(to: sourceCenter)
        }
    }
    private func accessibilityVisibleFrame(for screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let displayBounds = screen.displayID.map { CGDisplayBounds($0) } ?? screenFrame
        let leftInset = visibleFrame.minX - screenFrame.minX
        let rightInset = screenFrame.maxX - visibleFrame.maxX
        let topInset = screenFrame.maxY - visibleFrame.maxY
        let bottomInset = visibleFrame.minY - screenFrame.minY
        return CGRect(
            x: displayBounds.minX + leftInset,
            y: displayBounds.minY + topInset,
            width: displayBounds.width - leftInset - rightInset,
            height: displayBounds.height - topInset - bottomInset
        )
    }
    private func frameIntersectsAnyVisibleScreen(_ frame: CGRect) -> Bool {
        currentScreenInfos().contains { $0.frame.intersects(frame) }
    }
    private func onScreenWindowSnapshot() -> OnScreenWindowSnapshot {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return OnScreenWindowSnapshot()
        }
        var snapshot = OnScreenWindowSnapshot()
        var rank = 0
        for info in infoList {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0 else { continue }
            let pid = pid_t(pidNumber.intValue)
            let number = windowNumber.intValue
            let key = WindowOrderKey(pid: pid, number: number)
            snapshot.visibleNumbersByPID[pid, default: []].insert(number)
            if snapshot.rankByWindow[key] == nil {
                snapshot.rankByWindow[key] = rank
            }
            if let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) {
                let title = info[kCGWindowName as String] as? String
                snapshot.recordsByPID[pid, default: []].append(CGWindowRecord(
                    pid: pid,
                    number: number,
                    frame: frame,
                    title: title,
                    rank: rank
                ))
            }
            rank += 1
        }
        return snapshot
    }
    private func shouldOrderBefore(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> Bool {
        // CGWindowList is front-to-back. Syncing back-to-front makes a newly frontmost window insert last.
        switch (lhs.orderRank, rhs.orderRank) {
        case (.some(let lhsRank), .some(let rhsRank)) where lhsRank != rhsRank:
            return lhsRank > rhsRank
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        let lhsApp = lhs.bundleIdentifier ?? ""
        let rhsApp = rhs.bundleIdentifier ?? ""
        if lhsApp != rhsApp { return lhsApp < rhsApp }
        if lhs.id.pid != rhs.id.pid { return lhs.id.pid < rhs.id.pid }
        switch (lhs.windowNumber, rhs.windowNumber) {
        case (.some(let lhsNumber), .some(let rhsNumber)) where lhsNumber != rhsNumber:
            return lhsNumber < rhsNumber
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.scanIndex < rhs.scanIndex
        }
    }
    private func currentCursorPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
    }
    private var isPointerButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) ||
            CGEventSource.buttonState(.combinedSessionState, button: .center)
    }
    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }
    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approximatelyEqual(lhs.origin, rhs.origin) && approximatelyEqual(lhs.size, rhs.size)
    }
}
private struct CGWindowRecord {
    let pid: pid_t
    let number: Int
    let frame: CGRect
    let title: String?
    let rank: Int
}
private struct OnScreenWindowSnapshot {
    var recordsByPID: [pid_t: [CGWindowRecord]] = [:]
    var visibleNumbersByPID: [pid_t: Set<Int>] = [:]
    var rankByWindow: [WindowOrderKey: Int] = [:]
    func matchWindowNumber(pid: pid_t, frame: CGRect, title: String?, excluding excludedNumbers: Set<Int>) -> Int? {
        guard let records = recordsByPID[pid], !records.isEmpty else { return nil }
        let normalizedTitle = normalizedWindowTitle(title)
        var best: (number: Int, score: CGFloat)?
        for record in records where !excludedNumbers.contains(record.number) {
            let frameScore = record.frame.frameSimilarityScore(to: frame)
            guard frameScore <= 24 else { continue }
            let recordTitle = normalizedWindowTitle(record.title)
            var score = frameScore
            if !normalizedTitle.isEmpty, !recordTitle.isEmpty, normalizedTitle != recordTitle {
                score += 20
            } else if normalizedTitle.isEmpty || recordTitle.isEmpty {
                score += 4
            }
            score += CGFloat(record.rank) * 0.001
            if best == nil || score < best!.score {
                best = (record.number, score)
            }
        }
        return best?.number
    }
    private func normalizedWindowTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
private struct VisibleWindowSignature: Equatable {
    let visibleNumbersByPID: [pid_t: Set<Int>]

    init() {
        visibleNumbersByPID = [:]
    }

    init(snapshot: OnScreenWindowSnapshot) {
        visibleNumbersByPID = snapshot.visibleNumbersByPID.filter { !$0.value.isEmpty }
    }
}
private struct ScreenInfo {
    let key: String
    let frame: CGRect
    let displayID: CGDirectDisplayID?
    let activeSpaceID: SpaceID?
    var stateKey: String {
        Self.stateKey(displayKey: key, spaceID: activeSpaceID)
    }
    static func stateKey(displayKey: String, spaceID: SpaceID?) -> String {
        guard let spaceID else { return displayKey }
        return "\(displayKey):space:\(spaceID)"
    }
    static func displayKey(for displayID: CGDirectDisplayID?, frame: CGRect?) -> String {
        if let displayID { return "display:\(displayID)" }
        if let frame { return "frame:\(frame.debugDescription)" }
        return "display:unknown"
    }
}
private struct ManagedWindow {
    let id: WindowIdentity
    let windowNumber: Int?
    let element: AXUIElement
    let screen: ScreenInfo
    let layoutIdentity: WindowLayoutIdentity?
    let frame: CGRect
    let bundleIdentifier: String?
    let title: String?
    let orderRank: Int?
    let scanIndex: Int
}
private struct ManagedWindowCandidate {
    let pid: pid_t
    var windowNumber: Int?
    let elementKey: WindowElementKey
    let signature: WindowSignature?
    let layoutIdentity: WindowLayoutIdentity?
    let element: AXUIElement
    let screen: ScreenInfo
    let frame: CGRect
    let bundleIdentifier: String?
    let title: String?
    var orderRank: Int?
    let scanIndex: Int
}
private struct PersistedScreenLayout {
    let stateKey: String
    let displayKey: String
    let tree: BSPTree<Int>
    let entriesByID: [Int: PersistedWindowLayoutEntry]
    let lastFocusedEntryID: Int?
    let lastUpdated: Date
}
private struct PersistedWindowLayoutEntry {
    let id: Int
    let pid: pid_t
    let bundleIdentifier: String?
    let layoutIdentity: WindowLayoutIdentity?
    let orderRank: Int?
    let scanIndex: Int
}
private struct PersistedWindowGroupKey: Hashable {
    let pid: pid_t
    let bundleIdentifier: String?
}
private struct SystemUIWindowSnapshot: Equatable {
    let idsByStateKey: [String: Set<WindowIdentity>]
    let framesByID: [WindowIdentity: RoundedWindowFrame]
    init(windows: [ManagedWindow]) {
        idsByStateKey = Dictionary(grouping: windows, by: { $0.screen.stateKey })
            .mapValues { Set($0.map(\.id)) }
        framesByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, RoundedWindowFrame($0.frame)) })
    }
}
private struct RoundedWindowFrame: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    init(_ frame: CGRect) {
        x = Int(frame.minX.rounded(.toNearestOrAwayFromZero))
        y = Int(frame.minY.rounded(.toNearestOrAwayFromZero))
        width = Int(frame.width.rounded(.toNearestOrAwayFromZero))
        height = Int(frame.height.rounded(.toNearestOrAwayFromZero))
    }
}
private final class AppObserverRegistration {
    let observer: AXObserver
    let source: CFRunLoopSource
    var observedWindowTokens: Set<String> = []
    init(observer: AXObserver, source: CFRunLoopSource) {
        self.observer = observer
        self.source = source
    }
}
private struct ScreenTileState {
    private var tree = BSPTree<WindowIdentity>()
    private var lastFocusedID: WindowIdentity?
    init() {}
    init(tree: BSPTree<WindowIdentity>, lastFocusedID: WindowIdentity? = nil) {
        self.tree = tree
        self.lastFocusedID = lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
    }
    var isEmpty: Bool { tree.isEmpty }
    var slots: [WindowIdentity: TileSlot] { tree.slots() }
    var slotList: [(id: WindowIdentity, slot: TileSlot)] { tree.slotList() }
    var tileCount: Int { tree.tileCount }
    var windowIDs: Set<WindowIdentity> { Set(tree.ids) }
    var focusedWindowID: WindowIdentity? {
        lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
    }
    var lastFocusedOrLargestID: WindowIdentity? {
        lastFocusedID.flatMap { tree.contains($0) ? $0 : nil } ?? tree.largestLeafID() ?? tree.firstID
    }
    func contains(_ id: WindowIdentity) -> Bool {
        tree.contains(id)
    }
    mutating func replaceWindowIDs(_ replacements: [WindowIdentity: WindowIdentity]) -> Bool {
        guard tree.replaceIDs(replacements) else { return false }
        if let lastFocusedID, let replacement = replacements[lastFocusedID] {
            self.lastFocusedID = replacement
        }
        return true
    }
    func compactMapWindowIDs<NewID: Hashable>(_ transform: (WindowIdentity) -> NewID?) -> BSPTree<NewID>? {
        tree.compactMapIDs(transform)
    }
    mutating func sync(windowIDs: [WindowIdentity], focusedID: WindowIdentity?) {
        let liveIDs = Set(windowIDs)
        tree.removeMissing(keeping: liveIDs)
        let existingIDs = Set(tree.ids)
        var target = focusedID.flatMap { existingIDs.contains($0) ? $0 : nil }
            ?? lastFocusedID.flatMap { existingIDs.contains($0) ? $0 : nil }
            ?? tree.largestLeafID()
            ?? tree.firstID
        for id in windowIDs where !existingIDs.contains(id) {
            tree.insert(id, near: target, placement: .automatic)
            target = id
        }
        if let focusedID, liveIDs.contains(focusedID) {
            markFocused(focusedID)
        } else if let lastFocusedID, liveIDs.contains(lastFocusedID) {
            markFocused(lastFocusedID)
        } else if let target, liveIDs.contains(target) {
            markFocused(target)
        } else if let first = tree.firstID {
            markFocused(first)
        } else {
            lastFocusedID = nil
        }
    }
    mutating func removeMissing(keeping liveIDs: Set<WindowIdentity>) {
        tree.removeMissing(keeping: liveIDs)
        if let lastFocusedID, !tree.contains(lastFocusedID) {
            self.lastFocusedID = tree.firstID
        }
    }
    mutating func insertExisting(_ id: WindowIdentity, near targetID: WindowIdentity?, placement: TilePlacement) {
        let target = targetID.flatMap { tree.contains($0) ? $0 : nil } ?? lastFocusedOrLargestID
        tree.insert(id, near: target, placement: placement)
        markFocused(id)
    }
    mutating func remove(_ id: WindowIdentity) {
        tree.remove(id)
        if lastFocusedID == id {
            lastFocusedID = tree.firstID
        }
    }
    func neighborID(from focusedID: WindowIdentity, direction: SnapDirection) -> WindowIdentity? {
        tree.neighborID(from: focusedID, direction: direction)
    }
    mutating func markFocused(_ focusedID: WindowIdentity) {
        guard tree.contains(focusedID) else { return }
        lastFocusedID = focusedID
    }
    mutating func markFocusedIfKnown(_ focusedID: WindowIdentity) {
        guard tree.contains(focusedID) else { return }
        markFocused(focusedID)
    }
    mutating func swapFocused(_ focusedID: WindowIdentity, direction: SnapDirection) -> Bool {
        guard let neighborID = tree.neighborID(from: focusedID, direction: direction),
              tree.swap(focusedID, neighborID) else {
            return false
        }
        markFocused(focusedID)
        return true
    }
    mutating func resizeFocused(_ focusedID: WindowIdentity, direction: SnapDirection) -> Bool {
        guard tree.resize(focusedID: focusedID, direction: direction) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func reflectResize(focusedID: WindowIdentity, observedSlot: TileSlot) -> Bool {
        guard tree.reflectResize(focusedID: focusedID, observedSlot: observedSlot) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func toggleOrientation(focusedID: WindowIdentity) -> Bool {
        guard tree.toggleOrientation(focusedID: focusedID) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func move(_ id: WindowIdentity, onto target: WindowIdentity, placement: TilePlacement) -> Bool {
        guard tree.move(id, onto: target, placement: placement) else { return false }
        markFocused(id)
        return true
    }
    mutating func balance() {
        tree.balance()
        if let lastFocusedID, tree.contains(lastFocusedID) {
            markFocused(lastFocusedID)
        }
    }
    mutating func limitTileCount(to maxCount: Int) -> [WindowIdentity] {
        let removed = tree.limitTileCount(to: maxCount)
        if let lastFocusedID, !tree.contains(lastFocusedID) {
            self.lastFocusedID = tree.firstID
        }
        return removed
    }
}
private final class FocusBorderOverlay {
    private var panel: NSPanel?
    func show(accessibilityFrame frame: CGRect, color: NSColor) {
        let panel = ensurePanel()
        setColor(color)
        let cocoaFrame = Self.cocoaFrame(fromAccessibilityFrame: frame).insetBy(dx: -3, dy: -3)
        panel.setFrame(cocoaFrame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
    func setColor(_ color: NSColor) {
        panel?.contentView?.layer?.borderColor = color.cgColor
    }
    func hide() {
        panel?.orderOut(nil)
    }
    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = BorderColorPalette.color(from: BorderColorPalette.defaultHex)?.cgColor
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view
        self.panel = panel
        return panel
    }
    private static func cocoaFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let matchingScreen = NSScreen.screens.first { screen in
            guard let displayID = screen.displayID else { return false }
            return CGDisplayBounds(displayID).contains(center)
        } ?? NSScreen.main
        guard let screen = matchingScreen else { return frame }
        let displayBounds = screen.displayID.map { CGDisplayBounds($0) } ?? screen.frame
        let localX = frame.minX - displayBounds.minX
        let localYFromTop = frame.minY - displayBounds.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localYFromTop - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
private extension CGRect {
    var area: CGFloat { width * height }
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx: CGFloat
        if point.x < minX {
            dx = minX - point.x
        } else if point.x > maxX {
            dx = point.x - maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < minY {
            dy = minY - point.y
        } else if point.y > maxY {
            dy = point.y - maxY
        } else {
            dy = 0
        }
        return dx * dx + dy * dy
    }
    func centerDistanceSquared(to point: CGPoint) -> CGFloat {
        let dx = midX - point.x
        let dy = midY - point.y
        return dx * dx + dy * dy
    }
    func frameSimilarityScore(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) + abs(minY - other.minY) + abs(width - other.width) + abs(height - other.height)
    }
}
