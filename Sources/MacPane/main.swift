import AppKit
import ApplicationServices
import Carbon
import QuartzCore
private let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.gigaxel.macpane"
@main
final class MacPaneApp: NSObject, NSApplicationDelegate, HotKeyHandling, NSMenuDelegate {
    private static let sharedDelegate = MacPaneApp()
    private var statusItem: NSStatusItem?
    private let tiler = WindowTiler()
    private let workspaceOverviewOverlay = WorkspaceOverviewOverlay()
    private let workspaceSwitchIndicatorOverlay = WorkspaceSwitchIndicatorOverlay()
    private var isRebuildingMenu = false
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
    func handle(action: HotKeyAction, eventAge: TimeInterval, triggerKeyIsDown: Bool) {
        guard !action.shouldDropWhenStale || eventAge <= 0.12 else { return }
        guard !action.shouldDropWhenTriggerReleased || triggerKeyIsDown || eventAge <= 0.04 else { return }
        perform(action: action, rebuildMenu: false)
    }
    private func perform(action: HotKeyAction, rebuildMenu shouldRebuildMenu: Bool) {
        switch action {
        case .showWorkspaceOverview:
            showWorkspaceOverview()
            return
        case .hideWorkspaceOverview:
            workspaceOverviewOverlay.hide()
            return
        case .overviewSwitchWorkspace(let index):
            workspaceOverviewOverlay.hide()
            tiler.handle(action: .switchWorkspace(index))
            if shouldRebuildMenu {
                rebuildMenu()
            }
            showWorkspaceSwitchIndicatorIfNeeded()
            return
        case .overviewRenameStart:
            HotKeyManager.shared.unregisterWorkspaceOverviewHotKeys()
            let didBeginRename = workspaceOverviewOverlay.beginRename(
                onCommit: { [weak self] name in
                    guard let self else { return }
                    self.tiler.renameActiveWorkspace(to: name)
                    self.showWorkspaceOverview()
                },
                onCancel: { [weak self] in
                    guard let self, let workspaceCount = self.workspaceOverviewOverlay.workspaceCount else { return }
                    HotKeyManager.shared.registerWorkspaceOverviewHotKeys(workspaceCount: workspaceCount)
                }
            )
            if !didBeginRename, let workspaceCount = workspaceOverviewOverlay.workspaceCount {
                HotKeyManager.shared.registerWorkspaceOverviewHotKeys(workspaceCount: workspaceCount)
            }
            return
        default:
            break
        }
        let tilingEnabledBefore: Bool?
        let tilingIndicatorDisplayID: CGDirectDisplayID?
        if case .toggleTiling = action {
            tilingEnabledBefore = tiler.tilingEnabled
            tilingIndicatorDisplayID = tiler.currentDisplayID
        } else {
            tilingEnabledBefore = nil
            tilingIndicatorDisplayID = nil
        }
        tiler.handle(action: action)
        if shouldRebuildMenu {
            rebuildMenu()
        }
        if action.shouldShowWorkspaceSwitchIndicator {
            showWorkspaceSwitchIndicatorIfNeeded()
        }
        if let tilingEnabledBefore, tiler.tilingEnabled != tilingEnabledBefore {
            showTilingStateIndicator(displayID: tilingIndicatorDisplayID)
        }
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
        let menu = statusItem?.menu ?? NSMenu()
        populateMenu(menu)
        statusItem?.menu = menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
    private func populateMenu(_ menu: NSMenu) {
        guard !isRebuildingMenu else { return }
        isRebuildingMenu = true
        defer { isRebuildingMenu = false }
        menu.delegate = self
        menu.removeAllItems()
        let permissionTitle = tiler.hasAccessibilityPermission(prompt: false)
            ? "Accessibility: Enabled"
            : "Accessibility: Needed"
        let permissionItem = NSMenuItem(title: permissionTitle, action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        let tilingItem = NSMenuItem(title: "Tiling: \(tiler.tilingEnabled ? "On" : "Off")", action: nil, keyEquivalent: "")
        tilingItem.isEnabled = false
        menu.addItem(tilingItem)
        let workspaceMenuState = tiler.workspaceMenuState
        let workspaceItem = NSMenuItem(title: workspaceMenuState.statusText, action: nil, keyEquivalent: "")
        workspaceItem.isEnabled = false
        menu.addItem(workspaceItem)
        let switchWorkspaceItem = NSMenuItem(title: "Switch Workspace", action: nil, keyEquivalent: "")
        let switchWorkspaceMenu = NSMenu()
        for index in 0..<workspaceMenuState.count {
            let item = NSMenuItem(title: "Workspace \(index + 1)", action: #selector(switchWorkspaceFromMenu), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = workspaceMenuState.activeIndex == index ? .on : .off
            switchWorkspaceMenu.addItem(item)
        }
        switchWorkspaceItem.submenu = switchWorkspaceMenu
        menu.addItem(switchWorkspaceItem)
        let moveToWorkspaceItem = NSMenuItem(title: "Move Focused Window To", action: nil, keyEquivalent: "")
        let moveToWorkspaceMenu = NSMenu()
        for index in 0..<workspaceMenuState.count {
            let item = NSMenuItem(title: "Workspace \(index + 1)", action: #selector(moveFocusedWindowToWorkspaceFromMenu), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            moveToWorkspaceMenu.addItem(item)
        }
        moveToWorkspaceItem.submenu = moveToWorkspaceMenu
        menu.addItem(moveToWorkspaceItem)
        let createWorkspaceTitle = workspaceMenuState.canCreateMore
            ? "Create Workspace"
            : "Create Workspace (Max \(workspaceMenuState.maximumCount))"
        let createWorkspaceItem = NSMenuItem(title: createWorkspaceTitle, action: #selector(createWorkspace), keyEquivalent: "")
        createWorkspaceItem.target = self
        createWorkspaceItem.isEnabled = workspaceMenuState.canCreateMore
        menu.addItem(createWorkspaceItem)
        let deleteWorkspaceItem = NSMenuItem(
            title: workspaceMenuState.deleteWorkspaceTitle,
            action: #selector(deleteWorkspace),
            keyEquivalent: ""
        )
        deleteWorkspaceItem.target = self
        deleteWorkspaceItem.isEnabled = workspaceMenuState.canDeleteActive
        menu.addItem(deleteWorkspaceItem)
        let overviewItem = NSMenuItem(title: "Show Workspace Overview", action: #selector(showWorkspaceOverviewFromMenu), keyEquivalent: "")
        overviewItem.target = self
        menu.addItem(overviewItem)
        menu.addItem(NSMenuItem.separator())
        let shortcuts = [
            "Cmd+Option+Arrow/HJKL: focus neighbor",
            "Cmd+Shift+Arrow/HJKL: swap with neighbor",
            "Cmd+Ctrl+Arrow/HJKL: resize focused split",
            "Cmd+Option+O: rotate focused split",
            "Cmd+Option+G: toggle focused window floating",
            "Cmd+Option+Y: toggle tiling",
            "Cmd+Option+B: balance current BSP tree",
            "Cmd+Option+1...9: switch MacPane workspace",
            "Cmd+Ctrl+1...9: move focused window to workspace",
            "Cmd+Ctrl+Option+Left/Right or H/L: previous/next workspace",
            "Cmd+Ctrl+Option+=: create MacPane workspace",
            "Cmd+Ctrl+Option+-: delete current empty workspace",
            "Cmd+Ctrl+Option+V: show workspace overview",
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
    @objc private func switchWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        perform(action: .switchWorkspace(index), rebuildMenu: true)
    }
    @objc private func moveFocusedWindowToWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        perform(action: .moveWindowToWorkspace(index), rebuildMenu: true)
    }
    @objc private func createWorkspace() {
        perform(action: .createWorkspace, rebuildMenu: true)
    }
    @objc private func deleteWorkspace() {
        perform(action: .deleteWorkspace, rebuildMenu: true)
    }
    @objc private func showWorkspaceOverviewFromMenu() {
        showWorkspaceOverview()
    }
    private func showWorkspaceOverview() {
        guard let overview = tiler.workspaceOverview() else {
            NSSound.beep()
            return
        }
        workspaceOverviewOverlay.show(overview) {
            HotKeyManager.shared.unregisterWorkspaceOverviewHotKeys()
        }
        HotKeyManager.shared.registerWorkspaceOverviewHotKeys(workspaceCount: overview.workspaceCount)
    }
    private func showWorkspaceSwitchIndicatorIfNeeded() {
        guard let indicator = tiler.consumeWorkspaceSwitchIndicator() else { return }
        workspaceSwitchIndicatorOverlay.show(workspaceNumber: indicator.workspaceIndex + 1, displayID: indicator.displayID)
    }
    private func showTilingStateIndicator(displayID: CGDirectDisplayID?) {
        workspaceSwitchIndicatorOverlay.show(text: tiler.tilingEnabled ? "On" : "Off", displayID: displayID)
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
    @objc private func quit() {
        prepareForTermination()
        NSApplication.shared.terminate(nil)
    }
    private func prepareForTermination() {
        guard !isPreparingToTerminate else { return }
        isPreparingToTerminate = true
        HotKeyManager.shared.stop()
        tiler.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        workspaceOverviewOverlay.close()
        workspaceSwitchIndicatorOverlay.close()
    }
}
protocol HotKeyHandling: AnyObject {
    func handle(action: HotKeyAction, eventAge: TimeInterval, triggerKeyIsDown: Bool)
}
enum HotKeyAction {
    case focus(SnapDirection)
    case swap(SnapDirection)
    case resize(SnapDirection)
    case createWorkspace
    case deleteWorkspace
    case switchWorkspace(Int)
    case moveWindowToWorkspace(Int)
    case cycleWorkspace(Int)
    case showWorkspaceOverview
    case hideWorkspaceOverview
    case overviewSwitchWorkspace(Int)
    case overviewRenameStart
    case toggleOrientation
    case toggleFloating
    case toggleTiling
    case balance
    case retile
    var shouldShowWorkspaceSwitchIndicator: Bool {
        switch self {
        case .createWorkspace, .deleteWorkspace, .switchWorkspace, .cycleWorkspace:
            return true
        default:
            return false
        }
    }
    var shouldDropWhenStale: Bool {
        switch self {
        case .focus, .overviewSwitchWorkspace:
            return true
        default:
            return false
        }
    }
    var shouldDropWhenTriggerReleased: Bool {
        switch self {
        case .focus:
            return true
        default:
            return false
        }
    }
}
private struct RegisteredHotKey {
    let action: HotKeyAction
    let keyCode: UInt32
}
final class HotKeyManager {
    static let shared = HotKeyManager()
    weak var delegate: HotKeyHandling?
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var overviewHotKeyRefs: [EventHotKeyRef?] = []
    private var overviewActionIDs: Set<UInt32> = []
    private var hotKeysByID: [UInt32: RegisteredHotKey] = [:]
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
        unregisterWorkspaceOverviewHotKeys()
        for hotKeyRef in hotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        hotKeyRefs.removeAll()
        hotKeysByID.removeAll()
        nextID = 1
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    func registerWorkspaceOverviewHotKeys(workspaceCount: Int) {
        unregisterWorkspaceOverviewHotKeys()
        for item in workspaceKeyCodes().prefix(min(max(workspaceCount, 0), 9)) {
            registerOverviewHotKey(keyCode: item.keyCode, modifiers: 0, action: .overviewSwitchWorkspace(item.index))
        }
        registerOverviewHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: 0, action: .overviewRenameStart)
        registerOverviewHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(shiftKey), action: .overviewRenameStart)
        registerOverviewHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, action: .hideWorkspaceOverview)
    }
    func unregisterWorkspaceOverviewHotKeys() {
        for hotKeyRef in overviewHotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        overviewHotKeyRefs.removeAll()
        for id in overviewActionIDs {
            hotKeysByID.removeValue(forKey: id)
        }
        overviewActionIDs.removeAll()
    }
    func handleHotKey(id: UInt32, eventAge: TimeInterval) {
        guard let hotKey = hotKeysByID[id] else { return }
        let triggerKeyIsDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(hotKey.keyCode))
        delegate?.handle(action: hotKey.action, eventAge: eventAge, triggerKeyIsDown: triggerKeyIsDown)
    }
    private func registerHotKeys() {
        for item in directionalKeyCodes() {
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey), action: .focus(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | shiftKey), action: .swap(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | controlKey), action: .resize(item.direction))
        }
        for item in workspaceKeyCodes() {
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey), action: .switchWorkspace(item.index))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | controlKey), action: .moveWindowToWorkspace(item.index))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey | controlKey), action: .moveWindowToWorkspace(item.index))
        }
        register(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(-1))
        register(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(1))
        register(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(-1))
        register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(1))
        register(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .createWorkspace)
        register(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .deleteWorkspace)
        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .showWorkspaceOverview)
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
            hotKeysByID[id] = RegisteredHotKey(action: action, keyCode: keyCode)
            hotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("MacPane failed to register hotkey id=\(id) key=\(keyCode) modifiers=\(modifiers): \(status)")
        }
    }
    private func registerOverviewHotKey(keyCode: UInt32, modifiers: UInt32, action: HotKeyAction) {
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
            hotKeysByID[id] = RegisteredHotKey(action: action, keyCode: keyCode)
            overviewActionIDs.insert(id)
            overviewHotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("MacPane failed to register overview hotkey id=\(id) key=\(keyCode) modifiers=\(modifiers): \(status)")
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
    private func workspaceKeyCodes() -> [(keyCode: UInt32, index: Int)] {
        [
            (UInt32(kVK_ANSI_1), 0),
            (UInt32(kVK_ANSI_2), 1),
            (UInt32(kVK_ANSI_3), 2),
            (UInt32(kVK_ANSI_4), 3),
            (UInt32(kVK_ANSI_5), 4),
            (UInt32(kVK_ANSI_6), 5),
            (UInt32(kVK_ANSI_7), 6),
            (UInt32(kVK_ANSI_8), 7),
            (UInt32(kVK_ANSI_9), 8)
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
        let eventAge = max(0, GetCurrentEventTime() - GetEventTime(event))
        HotKeyManager.shared.handleHotKey(id: hotKeyID.id, eventAge: eventAge)
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
private struct WorkspaceMenuState {
    let activeIndex: Int?
    let displayID: CGDirectDisplayID?
    let count: Int
    let maximumCount: Int
    let canDeleteActive: Bool
    let deleteBlockReason: String?
    var canCreateMore: Bool { count < maximumCount }
    var deleteWorkspaceTitle: String {
        if canDeleteActive {
            return "Delete Current Workspace"
        }
        if let deleteBlockReason {
            return "Delete Current Workspace (\(deleteBlockReason))"
        }
        return "Delete Current Workspace"
    }
    var statusText: String {
        guard let activeIndex else {
            return "Workspace: unavailable"
        }
        return "Workspace: \(activeIndex + 1)/\(count)"
    }
}
private struct WorkspaceOverview {
    let displayID: CGDirectDisplayID?
    let displayName: String
    let activeWorkspaceIndex: Int
    let activeWorkspaceName: String?
    let workspaceCount: Int
    let items: [WorkspaceOverviewItem]
}
private struct WorkspaceOverviewItem {
    let index: Int
    let name: String?
    let isActive: Bool
    let windows: [WorkspaceOverviewWindow]
}
private struct WorkspaceOverviewWindow {
    let title: String
    let detail: String?
    let isFocused: Bool
}
private struct WorkspaceContext {
    let screen: ScreenInfo
    let nativeStateKey: String
    let activeWorkspaceIndex: Int
}
private struct WorkspaceSwitchIndicatorState {
    let workspaceIndex: Int
    let displayID: CGDirectDisplayID?
}
private enum WorkspaceSlideDirection {
    case forward
    case backward
}
private enum WorkspaceSlideEdge {
    case left
    case right
}
private struct WorkspaceSlideTransition {
    let window: ManagedWindow
    let startFrame: CGRect
    let endFrame: CGRect
    let needsInitialFrame: Bool
}
private final class WorkspaceSlideAnimator: NSObject {
    private let duration: TimeInterval
    private let frameRate: Int
    private let screen: NSScreen?
    private let shouldContinue: () -> Bool
    private let onFrame: (CGFloat) -> Void
    private let onFinish: () -> Void
    private var displayLink: NSObject?
    private var timer: Timer?
    private var startTime = CACurrentMediaTime()
    private var didFinish = false
    init(
        duration: TimeInterval,
        frameRate: Int,
        screen: NSScreen?,
        shouldContinue: @escaping () -> Bool,
        onFrame: @escaping (CGFloat) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.duration = duration
        self.frameRate = frameRate
        self.screen = screen
        self.shouldContinue = shouldContinue
        self.onFrame = onFrame
        self.onFinish = onFinish
    }
    func start() {
        startTime = CACurrentMediaTime()
        if #available(macOS 14.0, *), let screen {
            let displayLink = screen.displayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
            let rate = Float(max(frameRate, 1))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
            return
        }
        let interval = 1 / TimeInterval(max(frameRate, 1))
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(timerDidTick(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func finishImmediately() {
        guard !didFinish else { return }
        invalidate()
        onFrame(1)
        finish()
    }
    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        invalidate()
    }
    @available(macOS 14.0, *)
    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        tick(now: CACurrentMediaTime())
    }
    @objc private func timerDidTick(_ timer: Timer) {
        tick(now: CACurrentMediaTime())
    }
    private func tick(now: CFTimeInterval) {
        guard !didFinish else { return }
        guard shouldContinue() else {
            cancel()
            return
        }
        let progress = min(max((now - startTime) / duration, 0), 1)
        onFrame(CGFloat(progress))
        if progress >= 1 {
            finish()
        }
    }
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        invalidate()
        onFinish()
    }
    private func invalidate() {
        if #available(macOS 14.0, *), let displayLink = displayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }
    deinit {
        invalidate()
    }
}
final class WindowTiler {
    private let gapDefaultsKey = "gapPixels"
    private let workspaceCountDefaultsKey = "virtualWorkspaceCount"
    private let tilingEnabledDefaultsKey = "tilingEnabled"
    private let workspaceNamesDefaultsKey = "workspaceNamesByDisplay"
    private let accessibilityPromptedDefaultsKey = "accessibilityPrompted"
    private let defaultGap = 8
    private let maximumGap = 48
    private let defaultWorkspaceCount = 4
    private let maximumWorkspaceCount = 9
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
    private let maximumAnimatedWorkspaceTransitionWindows = 8
    private let defaultWorkspaceSlideFrameRate = 60
    private let windowDiscoveryReconcileOffsets: [TimeInterval] = [0, 0.10, 0.28, 0.70, 1.50]
    private let accessibilityMessagingTimeout: Float = 0.15
    private let accessibilityPermissionCacheDuration: TimeInterval = 0.50
    private var cachedAccessibilityPermission: (granted: Bool, createdAt: Date)?
    private var screenStates: [String: ScreenTileState] = [:]
    private var activeWorkspaceIndexByNativeStateKey: [String: Int] = [:]
    private var activeWorkspaceIndexByDisplayKey: [String: Int] = [:]
    private var lastAppliedWorkspaceIndexByNativeStateKey: [String: Int] = [:]
    private var lastWorkspaceSwitchContext: WorkspaceContext?
    private var shouldMigrateWorkspaceStatesAfterScreenChange = false
    private var lastKnownScreenNativeStateKeys: Set<String> = []
    private var disconnectedNativeStateKeysPendingMigration: Set<String> = []
    private var pendingWorkspaceSwitchIndicator: WorkspaceSwitchIndicatorState?
    private var frozenSystemUIScreenStates: [String: ScreenTileState]?
    private var frozenSystemUIActiveStateKeys: Set<String>?
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
    private let visibilityScanInterval: TimeInterval = 2.0
    private let observerRecoveryInterval: TimeInterval = 15.0
    private var lastVisibleWindowSignature = VisibleWindowSignature()
    private var lastSyncedVisibleWindowSignature = VisibleWindowSignature()
    private var lastAppliedFrameByWindowID: [WindowIdentity: CGRect] = [:]
    private var lastKnownFocusedWindowID: WindowIdentity?
    private var lastObserverRefresh = Date.distantPast
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
    var workspaceCount: Int {
        let stored = UserDefaults.standard.object(forKey: workspaceCountDefaultsKey) as? Int
        return min(max(stored ?? defaultWorkspaceCount, 1), maximumWorkspaceCount)
    }
    fileprivate var workspaceMenuState: WorkspaceMenuState {
        let context = currentWorkspaceContext()
        let deletion = context.map { workspaceDeletionAvailability(index: $0.activeWorkspaceIndex) }
        return WorkspaceMenuState(
            activeIndex: context?.activeWorkspaceIndex,
            displayID: context?.screen.displayID,
            count: workspaceCount,
            maximumCount: maximumWorkspaceCount,
            canDeleteActive: deletion?.canDelete ?? false,
            deleteBlockReason: deletion?.reason
        )
    }
    var currentWorkspaceIndex: Int? {
        currentWorkspaceContext()?.activeWorkspaceIndex
    }
    fileprivate var currentDisplayID: CGDirectDisplayID? {
        currentWorkspaceContext()?.screen.displayID
    }
    var workspaceStatusText: String {
        workspaceMenuState.statusText
    }
    var tilingEnabled: Bool {
        if UserDefaults.standard.object(forKey: tilingEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: tilingEnabledDefaultsKey)
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
        restoreAllWorkspacesBeforeStopping()
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
        pendingWorkspaceSwitchApply?.cancel()
        pendingWorkspaceSwitchApply = nil
        cancelPendingWorkspaceSlideAnimation(finalize: false)
        workspaceSwitchApplyGeneration += 1
        windowDiscoveryReconcileGeneration += 1
        managedWindowCache = nil
        cachedAccessibilityPermission = nil
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
        activeWorkspaceIndexByNativeStateKey.removeAll()
        activeWorkspaceIndexByDisplayKey.removeAll()
        lastAppliedWorkspaceIndexByNativeStateKey.removeAll()
        lastWorkspaceSwitchContext = nil
        shouldMigrateWorkspaceStatesAfterScreenChange = false
        lastKnownScreenNativeStateKeys.removeAll()
        disconnectedNativeStateKeysPendingMigration.removeAll()
        pendingWorkspaceSwitchIndicator = nil
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        resetSystemUIWindowSnapshotStability()
        floatingWindowIDs.removeAll()
        floatingWindowStateKeys.removeAll()
        layoutIdentityByWindowID.removeAll()
        persistedLayoutsByStateKey.removeAll()
        lastVisibleWindowSignature = VisibleWindowSignature()
        lastSyncedVisibleWindowSignature = VisibleWindowSignature()
        lastAppliedFrameByWindowID.removeAll()
        lastKnownFocusedWindowID = nil
        lastObserverRefresh = Date.distantPast
        knownNonObservablePIDs.removeAll()
        isApplyingLayout = false
        isWatching = false
    }
    private func restoreAllWorkspacesBeforeStopping() {
        guard hasAccessibilityPermission(prompt: false) else { return }
        cancelPendingWorkspaceSwitchApply()
        refreshAppObservers()
        var allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
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
        UserDefaults.standard.set(true, forKey: accessibilityPromptedDefaultsKey)
        cachedAccessibilityPermission = nil
        return hasAccessibilityPermission(prompt: true)
    }
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
    fileprivate func consumeWorkspaceSwitchIndicator() -> WorkspaceSwitchIndicatorState? {
        defer { pendingWorkspaceSwitchIndicator = nil }
        return pendingWorkspaceSwitchIndicator
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
    fileprivate func workspaceOverview() -> WorkspaceOverview? {
        guard !isStopping else { return nil }
        guard hasAccessibilityPermission(prompt: false) else { return nil }
        startWatching()
        var allWindows = managedWindows()
        var focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        if migrateWorkspaceStatesAfterScreenChangeIfNeeded(windows: allWindows, focusedID: focusedID) {
            invalidateManagedWindowCache(clearAppliedFrames: true)
            allWindows = managedWindows()
            focusedID = focusedWindowID(in: allWindows)
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
                name: workspaceName(forNativeStateKey: context.nativeStateKey, workspaceIndex: index),
                isActive: index == context.activeWorkspaceIndex,
                windows: windows
            )
        }
        return WorkspaceOverview(
            displayID: context.screen.displayID,
            displayName: displayName(for: context.screen),
            activeWorkspaceIndex: context.activeWorkspaceIndex,
            activeWorkspaceName: workspaceName(
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
        setWorkspaceName(name, forNativeStateKey: context.nativeStateKey, workspaceIndex: context.activeWorkspaceIndex)
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
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: onScreenWindowSnapshot())
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
        for app in NSWorkspace.shared.runningApplications.filter(isObservableApp) {
            registerWindowNotifications(for: app)
        }
    }
    private func registerWindowNotifications(for app: NSRunningApplication) {
        guard !isStopping else { return }
        guard let registration = appObservers[app.processIdentifier] else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
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
        guard tilingEnabled else { return }
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
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiled, focusedID: focusedID)
        applyLayout(to: allWindows)
    }
    private func rememberFocusedWindowOnly() {
        guard !isStopping else { return }
        guard hasAccessibilityPermission(prompt: false) else { return }
        guard tilingEnabled else { return }
        guard !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else { return }
        let snapshot = onScreenWindowSnapshot()
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
        guard let focusedID = focusedWindowID(in: windows) else { return }
        lastKnownFocusedWindowID = focusedID
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
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        let activeWindows = windows.filter { activeStateKeys.contains($0.screen.stateKey) }
        let grouped = Dictionary(grouping: activeWindows, by: { $0.screen.stateKey })
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
    private func hasLikelyPartialHotKeySnapshot(_ windows: [ManagedWindow]) -> Bool {
        let activeStateKeys = Set(currentScreenInfos().map(\.stateKey))
        for key in activeStateKeys {
            if hasLikelyPartialHotKeySnapshot(forStateKey: key, windows: windows) {
                return true
            }
        }
        return false
    }
    private func hasLikelyPartialHotKeySnapshot(
        forStateKey key: String,
        windows: [ManagedWindow]
    ) -> Bool {
        guard let state = screenStates[key], !state.isEmpty else { return false }
        let observedCount = windows.reduce(into: 0) { count, window in
            if window.screen.stateKey == key {
                count += 1
            }
        }
        return observedCount < state.windowIDs.count
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
    @discardableResult
    private func performHotKeyActionWithRetry(
        _ action: (_ windows: [ManagedWindow], _ focusedID: WindowIdentity?) -> Bool
    ) -> Bool {
        let initialWindows = interactiveManagedWindows()
        if !initialWindows.isEmpty {
            let initialFocusedID = resolvedHotKeyFocusedID(
                in: initialWindows,
                preferredFocusedID: focusedWindowIDForHotKey(in: initialWindows)
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
            preferredFocusedID: focusedWindowIDForHotKey(in: refreshedWindows)
        )
        let refreshedTiled = tiledWindows(from: refreshedWindows)
        if hasLikelyPartialHotKeySnapshot(refreshedTiled) {
            scheduleReconcile(delay: 0.01)
            let initialFallbackFocusedID = resolvedHotKeyFocusedID(
                in: initialWindows,
                preferredFocusedID: focusedWindowIDForHotKey(in: initialWindows)
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
        let visibleIDs = Set(windows.map(\.id))
        if let preferredFocusedID, visibleIDs.contains(preferredFocusedID) {
            lastKnownFocusedWindowID = preferredFocusedID
            return preferredFocusedID
        }
        if let lastKnownFocusedWindowID, visibleIDs.contains(lastKnownFocusedWindowID) {
            return lastKnownFocusedWindowID
        }
        if let context = currentWorkspaceContext(windows: windows, focusedID: preferredFocusedID) {
            let activeStateKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: context.nativeStateKey,
                workspaceIndex: context.activeWorkspaceIndex
            )
            if let fallbackID = screenStates[activeStateKey]?.lastFocusedOrLargestID,
               visibleIDs.contains(fallbackID) {
                lastKnownFocusedWindowID = fallbackID
                return fallbackID
            }
        }
        for state in screenStates.values {
            if let fallbackID = state.lastFocusedOrLargestID, visibleIDs.contains(fallbackID) {
                lastKnownFocusedWindowID = fallbackID
                return fallbackID
            }
        }
        let cursor = currentCursorPoint()
        if let context = currentWorkspaceContext(windows: windows, focusedID: nil) {
            let activeStateKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: context.nativeStateKey,
                workspaceIndex: context.activeWorkspaceIndex
            )
            if let fallback = windows
                .filter({ $0.screen.stateKey == activeStateKey && !floatingWindowIDs.contains($0.id) })
                .min(by: { $0.frame.distanceSquared(to: cursor) < $1.frame.distanceSquared(to: cursor) }) {
                lastKnownFocusedWindowID = fallback.id
                return fallback.id
            }
        }
        if let fallback = windows
            .filter({ !floatingWindowIDs.contains($0.id) })
            .min(by: { $0.frame.distanceSquared(to: cursor) < $1.frame.distanceSquared(to: cursor) }) {
            lastKnownFocusedWindowID = fallback.id
            return fallback.id
        }
        return nil
    }
    private func resolvedHotKeyStateKey(
        for focusedID: WindowIdentity,
        windows: [ManagedWindow]
    ) -> String? {
        if let key = stateKey(containing: focusedID),
           screenStates[key] != nil {
            return key
        }
        guard let focusedWindow = windows.first(where: { $0.id == focusedID }) else { return nil }
        let candidateKey = focusedWindow.screen.stateKey
        if screenStates[candidateKey] != nil {
            return candidateKey
        }
        if hasLikelyPartialHotKeySnapshot(forStateKey: candidateKey, windows: windows) {
            return nil
        }
        let candidateIDs = windows
            .filter { $0.screen.stateKey == candidateKey && !floatingWindowIDs.contains($0.id) }
            .map(\.id)
        guard !candidateIDs.isEmpty else { return nil }
        var state = screenStates[candidateKey] ?? ScreenTileState()
        state.sync(windowIDs: candidateIDs, focusedID: candidateIDs.contains(focusedID) ? focusedID : nil)
        screenStates[candidateKey] = state
        return candidateKey
    }
    private func synchronizeHotKeyState(
        key: String,
        focusedID: WindowIdentity,
        windows: [ManagedWindow]
    ) -> ScreenTileState? {
        guard var state = screenStates[key] else { return nil }
        let candidateIDs = windows
            .filter { $0.screen.stateKey == key && !floatingWindowIDs.contains($0.id) }
            .map(\.id)
        guard !candidateIDs.isEmpty else { return nil }
        let candidateSet = Set(candidateIDs)
        if candidateSet.count < state.windowIDs.count {
            // Hotkey paths can observe transiently incomplete AX snapshots during rapid resizes.
            // Avoid shrinking the tree in that case; a scheduled reconcile will heal once stable.
            if !state.contains(focusedID) {
                return nil
            }
            state.markFocusedIfKnown(focusedID)
            screenStates[key] = state
            return state
        }
        if state.windowIDs != candidateSet {
            state.sync(windowIDs: candidateIDs, focusedID: candidateSet.contains(focusedID) ? focusedID : nil)
            screenStates[key] = state
        } else if candidateSet.contains(focusedID) {
            state.markFocusedIfKnown(focusedID)
            screenStates[key] = state
        }
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
                    ?? self.frameBasedNeighborID(from: focusedID, direction: direction, windows: allWindows)
            } else {
                targetID = self.frameBasedNeighborID(from: focusedID, direction: direction, windows: allWindows)
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
    private func frameBasedNeighborID(
        from focusedID: WindowIdentity,
        direction: SnapDirection,
        windows: [ManagedWindow]
    ) -> WindowIdentity? {
        guard let focusedWindow = windows.first(where: { $0.id == focusedID }) else { return nil }
        let sourceFrame = focusedWindow.frame
        let sourcePoint = frameSideCenter(of: sourceFrame, leaving: direction)
        var best: (id: WindowIdentity, score: CGFloat, overlap: CGFloat)?
        for candidate in windows where candidate.id != focusedID {
            guard !floatingWindowIDs.contains(candidate.id),
                  candidate.screen.stateKey == focusedWindow.screen.stateKey,
                  isFrameCandidate(candidate.frame, from: sourceFrame, direction: direction) else {
                continue
            }
            let targetPoint = frameSideCenter(of: candidate.frame, enteringFrom: direction)
            let dx = sourcePoint.x - targetPoint.x
            let dy = sourcePoint.y - targetPoint.y
            let distanceSquared = dx * dx + dy * dy
            let overlap = framePerpendicularOverlap(sourceFrame, candidate.frame, direction: direction)
            let score = distanceSquared - overlap * overlap * 0.25
            if best == nil || score < best!.score - TileLayout.epsilon ||
                (abs(score - best!.score) <= TileLayout.epsilon && overlap > best!.overlap) {
                best = (candidate.id, score, overlap)
            }
        }
        return best?.id
    }
    private func frameSideCenter(of frame: CGRect, leaving direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.minY)
        case .down: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }
    private func frameSideCenter(of frame: CGRect, enteringFrom direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: frame.maxX, y: frame.midY)
        case .right: return CGPoint(x: frame.minX, y: frame.midY)
        case .up: return CGPoint(x: frame.midX, y: frame.maxY)
        case .down: return CGPoint(x: frame.midX, y: frame.minY)
        }
    }
    private func isFrameCandidate(_ candidate: CGRect, from focused: CGRect, direction: SnapDirection) -> Bool {
        switch direction {
        case .left: return candidate.midX < focused.midX - TileLayout.epsilon
        case .right: return candidate.midX > focused.midX + TileLayout.epsilon
        case .up: return candidate.midY < focused.midY - TileLayout.epsilon
        case .down: return candidate.midY > focused.midY + TileLayout.epsilon
        }
    }
    private func framePerpendicularOverlap(_ lhs: CGRect, _ rhs: CGRect, direction: SnapDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        case .up, .down:
            return max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        }
    }
    private func scheduleHotKeyReconcileBurst() {
        scheduleReconcile(delay: 0.03)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.scheduleReconcile(delay: 0.01)
        }
    }
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
    private func cycleVirtualWorkspace(by delta: Int) {
        guard let context = workspaceSwitchContextFast() else {
            NSSound.beep()
            return
        }
        switchVirtualWorkspaceFast(
            to: wrappedWorkspaceIndex(context.activeWorkspaceIndex + delta),
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
        guard let targetIndex = availableWorkspaceIndex(requestedIndex) else {
            NSSound.beep()
            return
        }
        let currentIndex = activeWorkspaceIndex(forNativeStateKey: context.nativeStateKey)
        guard targetIndex != currentIndex else { return }
        cancelPendingWorkspaceSwitchApply()
        let visibleIndex = lastAppliedWorkspaceIndexByNativeStateKey[context.nativeStateKey] ?? currentIndex
        setActiveWorkspaceIndex(targetIndex, forNativeStateKey: context.nativeStateKey)
        let activeScreen = ScreenInfo(
            key: context.screen.key,
            frame: context.screen.frame,
            displayID: context.screen.displayID,
            workspaceIndex: targetIndex
        )
        lastWorkspaceSwitchContext = WorkspaceContext(
            screen: activeScreen,
            nativeStateKey: context.nativeStateKey,
            activeWorkspaceIndex: targetIndex
        )
        pendingWorkspaceSwitchIndicator = WorkspaceSwitchIndicatorState(
            workspaceIndex: targetIndex,
            displayID: context.screen.displayID
        )
        suppressExternalChanges(for: 0.20)
        guard targetIndex != visibleIndex else { return }
        let generation = workspaceSwitchApplyGeneration
        let slideDirection = workspaceSlideDirection(
            from: visibleIndex,
            to: targetIndex,
            directionHint: directionHint
        )
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishWorkspaceSwitchApply(
                nativeStateKey: context.nativeStateKey,
                displayID: context.screen.displayID,
                visibleIndex: visibleIndex,
                targetIndex: targetIndex,
                slideDirection: slideDirection,
                generation: generation
            )
        }
        pendingWorkspaceSwitchApply = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + workspaceSwitchApplyDelay, execute: workItem)
    }
    private func workspaceSlideDirection(
        from visibleIndex: Int,
        to targetIndex: Int,
        directionHint: Int?
    ) -> WorkspaceSlideDirection {
        if let directionHint, directionHint != 0 {
            return directionHint > 0 ? .forward : .backward
        }
        return targetIndex > visibleIndex ? .forward : .backward
    }
    private func workspaceSwitchContextFast() -> WorkspaceContext? {
        if let lastKnownFocusedWindowID,
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
            let activeIndex = activeWorkspaceIndex(forNativeStateKey: cached.nativeStateKey)
            return WorkspaceContext(screen: cached.screen, nativeStateKey: cached.nativeStateKey, activeWorkspaceIndex: activeIndex)
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
    private func completeWorkspaceSwitchApply(
        allWindows: [ManagedWindow],
        nativeStateKey: String,
        targetStateKey: String,
        targetIndex: Int,
        stateKeys: Set<String>
    ) {
        suppressExternalChanges(for: 0.45)
        applyLayout(to: allWindows, limitingToStateKeys: stateKeys)
        lastAppliedWorkspaceIndexByNativeStateKey[nativeStateKey] = targetIndex
        if let targetState = screenStates[targetStateKey],
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
        let transitions = workspaceSlideTransitions(
            allWindows: allWindows,
            screen: screen,
            visibleStateKey: visibleStateKey,
            targetStateKey: targetStateKey,
            direction: direction
        )
        guard !transitions.isEmpty,
              transitions.count <= maximumAnimatedWorkspaceTransitionWindows else {
            return false
        }
        suppressExternalChanges(for: workspaceSlideAnimationDuration + 0.55)
        applyWorkspaceSlideInitialFrames(transitions)
        let animator = WorkspaceSlideAnimator(
            duration: workspaceSlideAnimationDuration,
            frameRate: workspaceSlideFrameRate(for: screen),
            screen: nsScreen(for: screen),
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
    private func workspaceSlideFrameRate(for screen: ScreenInfo) -> Int {
        max(
            nsScreen(for: screen)?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? defaultWorkspaceSlideFrameRate,
            defaultWorkspaceSlideFrameRate
        )
    }
    private func nsScreen(for screen: ScreenInfo) -> NSScreen? {
        if let displayID = screen.displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return matchingScreen
        }
        return NSScreen.screens.first { ScreenInfo.displayKey(for: $0.displayID, frame: $0.frame) == screen.key }
    }
    private func workspaceSlideTransitions(
        allWindows: [ManagedWindow],
        screen: ScreenInfo,
        visibleStateKey: String,
        targetStateKey: String,
        direction: WorkspaceSlideDirection
    ) -> [WorkspaceSlideTransition] {
        let windowsByID = Dictionary(allWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let screens = currentScreenInfos()
        var transitions: [WorkspaceSlideTransition] = []
        if let visibleState = screenStates[visibleStateKey], !visibleState.isEmpty {
            guard visibleState.windowIDs.allSatisfy({ windowsByID[$0] != nil || floatingWindowIDs.contains($0) }) else {
                return []
            }
            for id in visibleState.windowIDs {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let startFrame = sanitizedFrame(window.frame)
                let endFrame = slideHiddenFrame(
                    matching: startFrame,
                    on: screen,
                    edge: direction == .forward ? .left : .right
                )
                guard slideHiddenFrameDoesNotCoverAnotherScreen(endFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: false
                ))
            }
        }
        if let targetState = screenStates[targetStateKey], !targetState.isEmpty {
            guard targetState.windowIDs.allSatisfy({ windowsByID[$0] != nil || floatingWindowIDs.contains($0) }) else {
                return []
            }
            for (id, slot) in targetState.slotList {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let endFrame = sanitizedFrame(slot.frame(in: screen.frame, gap: CGFloat(gapPixels), smartOuterGap: true))
                let startFrame = slideHiddenFrame(
                    matching: endFrame,
                    on: screen,
                    edge: direction == .forward ? .right : .left
                )
                guard slideHiddenFrameDoesNotCoverAnotherScreen(startFrame, source: screen, screens: screens) else {
                    return []
                }
                transitions.append(WorkspaceSlideTransition(
                    window: window,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    needsInitialFrame: true
                ))
            }
        }
        return transitions
    }
    private func slideHiddenFrameDoesNotCoverAnotherScreen(
        _ frame: CGRect,
        source: ScreenInfo,
        screens: [ScreenInfo]
    ) -> Bool {
        !screens.contains { screen in
            screen.key != source.key && screen.frame.intersects(frame)
        }
    }
    private func slideHiddenFrame(
        matching frame: CGRect,
        on screen: ScreenInfo,
        edge: WorkspaceSlideEdge
    ) -> CGRect {
        let x: CGFloat
        switch edge {
        case .left:
            x = screen.frame.minX - frame.width + 1
        case .right:
            x = screen.frame.maxX - 1
        }
        return sanitizedFrame(CGRect(
            x: x,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        ))
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
            applyFrame(transition.startFrame, to: transition.window.element)
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
        let easedProgress = easedWorkspaceSlideProgress(progress)
        for transition in transitions {
            let frame = interpolatedFrame(from: transition.startFrame, to: transition.endFrame, progress: easedProgress)
            applyPosition(frame.origin, to: transition.window.element)
            lastAppliedFrameByWindowID[transition.window.id] = frame
            appliedFramesByID[transition.window.id] = frame
        }
    }
    private func easedWorkspaceSlideProgress(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
    private func interpolatedFrame(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        sanitizedFrame(CGRect(
            x: start.minX + ((end.minX - start.minX) * progress),
            y: start.minY + ((end.minY - start.minY) * progress),
            width: start.width + ((end.width - start.width) * progress),
            height: start.height + ((end.height - start.height) * progress)
        ))
    }
    private func finishWorkspaceSwitchApply(
        nativeStateKey: String,
        displayID: CGDirectDisplayID?,
        visibleIndex: Int,
        targetIndex: Int,
        slideDirection: WorkspaceSlideDirection,
        generation: Int
    ) {
        guard !isStopping, workspaceSwitchApplyGeneration == generation else { return }
        guard hasAccessibilityPermission(prompt: false), tilingEnabled else { return }
        guard !shouldPauseLayoutForSystemUI(), frozenSystemUIScreenStates == nil else {
            scheduleReconcile(delay: 0.08)
            return
        }
        let allWindows = interactiveManagedWindows()
        let focusedID = focusedWindowIDForHotKey(in: allWindows)
        syncStatesForHotKeyIfNeeded(with: allWindows, focusedID: focusedID)
        let visibleStateKey = ScreenInfo.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: visibleIndex)
        let targetStateKey = ScreenInfo.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: targetIndex)
        suppressExternalChanges(for: 0.45)
        let completion: () -> Void = { [weak self] in
            self?.completeWorkspaceSwitchApply(
                allWindows: allWindows,
                nativeStateKey: nativeStateKey,
                targetStateKey: targetStateKey,
                targetIndex: targetIndex,
                stateKeys: [visibleStateKey, targetStateKey]
            )
        }
        guard animateWorkspaceSwitchIfPossible(
            allWindows: allWindows,
            nativeStateKey: nativeStateKey,
            visibleStateKey: visibleStateKey,
            targetStateKey: targetStateKey,
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
        guard workspaceCount < maximumWorkspaceCount else {
            NSSound.beep()
            return
        }
        guard let context = currentWorkspaceContext() else {
            NSSound.beep()
            return
        }
        let allWindows = managedWindows()
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        let newWorkspaceIndex = workspaceCount
        UserDefaults.standard.set(newWorkspaceIndex + 1, forKey: workspaceCountDefaultsKey)
        setActiveWorkspaceIndex(newWorkspaceIndex, forNativeStateKey: context.nativeStateKey)
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
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        let deletingIndex = context.activeWorkspaceIndex
        guard workspaceDeletionAvailability(index: deletingIndex).canDelete else {
            NSSound.beep()
            return
        }
        let newWorkspaceCount = workspaceCount - 1
        let nextActiveIndex = shiftedActiveWorkspaceIndex(
            context.activeWorkspaceIndex,
            deletingWorkspaceIndex: deletingIndex,
            newWorkspaceCount: newWorkspaceCount
        )
        screenStates = shiftedScreenStates(deletingWorkspaceIndex: deletingIndex)
        persistedLayoutsByStateKey = shiftedPersistedLayouts(deletingWorkspaceIndex: deletingIndex)
        floatingWindowStateKeys = floatingWindowStateKeys.compactMapValues {
            shiftedWorkspaceStateKey($0, deletingWorkspaceIndex: deletingIndex)
        }
        shiftWorkspaceNames(deletingWorkspaceIndex: deletingIndex)
        activeWorkspaceIndexByNativeStateKey = activeWorkspaceIndexByNativeStateKey.mapValues {
            shiftedActiveWorkspaceIndex($0, deletingWorkspaceIndex: deletingIndex, newWorkspaceCount: newWorkspaceCount)
        }
        activeWorkspaceIndexByDisplayKey = activeWorkspaceIndexByDisplayKey.mapValues {
            shiftedActiveWorkspaceIndex($0, deletingWorkspaceIndex: deletingIndex, newWorkspaceCount: newWorkspaceCount)
        }
        UserDefaults.standard.set(newWorkspaceCount, forKey: workspaceCountDefaultsKey)
        activeWorkspaceIndexByNativeStateKey[context.nativeStateKey] = nextActiveIndex
        activeWorkspaceIndexByDisplayKey[displayKeyComponent(of: context.nativeStateKey)] = nextActiveIndex
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
        let focusedID = focusedWindowID(in: allWindows)
        syncStates(with: tiledWindows(from: allWindows), focusedID: focusedID)
        guard let focusedID,
              let focusedWindow = allWindows.first(where: { $0.id == focusedID }),
              let sourceKey = stateKey(containing: focusedID),
              var sourceState = screenStates[sourceKey] else {
            NSSound.beep()
            return
        }
        let nativeStateKey = nativeStateKeyComponent(of: sourceKey)
        guard let targetIndex = availableWorkspaceIndex(requestedIndex) else {
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
            workspaceIndex: activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
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
        cancelPendingWorkspaceSwitchApply()
        UserDefaults.standard.set(!tilingEnabled, forKey: tilingEnabledDefaultsKey)
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
            lastKnownFocusedWindowID = focusedID
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
            let targetIndex = activeWorkspaceIndex(forNativeStateKey: screen.nativeStateKey)
            let targetKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: screen.nativeStateKey,
                workspaceIndex: targetIndex
            )
            merged = mergeWorkspaceStates(
                inNativeStateKey: screen.nativeStateKey,
                into: targetKey,
                focusedID: focusedID
            ) || merged
            merged = moveFloatingWindowStateKeys(inNativeStateKey: screen.nativeStateKey, to: targetKey) || merged
        }
        return merged
    }
    private func mergeWorkspaceStates(
        inNativeStateKey nativeStateKey: String,
        into targetKey: String,
        focusedID: WindowIdentity?
    ) -> Bool {
        let sourceKeys = screenStates.keys
            .filter { key in
                key != targetKey && nativeStateKeyComponent(of: key) == nativeStateKey
            }
            .sorted()
        var merged = false
        for sourceKey in sourceKeys {
            merged = migrateScreenState(from: sourceKey, to: targetKey, focusedID: focusedID) || merged
        }
        return merged
    }
    private func moveFloatingWindowStateKeys(inNativeStateKey nativeStateKey: String, to targetKey: String) -> Bool {
        var moved = false
        for (id, stateKey) in floatingWindowStateKeys where stateKey != targetKey && nativeStateKeyComponent(of: stateKey) == nativeStateKey {
            floatingWindowStateKeys[id] = targetKey
            moved = true
        }
        return moved
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
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentScreens = currentScreenInfos()
        let screens = Dictionary(uniqueKeysWithValues: currentScreens.map { ($0.stateKey, $0) })
        let screensByNativeStateKey = Dictionary(currentScreens.map { ($0.nativeStateKey, $0) }, uniquingKeysWith: { first, _ in first })
        let activeStateKeys = Set(screens.keys)
        let statesToApply: [(key: String, state: ScreenTileState)]
        if let stateKeyLimit {
            statesToApply = stateKeyLimit.compactMap { key in
                guard let state = screenStates[key], !state.isEmpty else { return nil }
                return (key: key, state: state)
            }
        } else {
            statesToApply = screenStates.compactMap { key, state in
                state.isEmpty ? nil : (key: key, state: state)
            }
        }
        pendingMove?.cancel()
        pendingResize?.cancel()
        suppressExternalChanges(for: 0.45)
        isApplyingLayout = true
        var appliedFramesByID: [WindowIdentity: CGRect] = [:]
        var skippedIncompleteState = false
        defer {
            isApplyingLayout = false
            updateManagedWindowCache(withAppliedFrames: appliedFramesByID)
            updateLastAppliedWorkspaceIndices(using: currentScreens)
            suppressExternalChanges(for: 0.45)
            if skippedIncompleteState {
                scheduleReconcile(delay: 0.01)
            }
        }
        for (screenKey, state) in statesToApply {
            if activeStateKeys.contains(screenKey) {
                guard let screen = screens[screenKey] ?? windows.first(where: { $0.screen.stateKey == screenKey })?.screen else {
                    continue
                }
                let hasCompleteWindowSet = state.windowIDs.allSatisfy { id in
                    windowsByID[id] != nil || floatingWindowIDs.contains(id)
                }
                guard hasCompleteWindowSet else {
                    skippedIncompleteState = true
                    continue
                }
                for (id, slot) in state.slots {
                    guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                    let frame = slot.frame(in: screen.frame, gap: CGFloat(gapPixels), smartOuterGap: true)
                    if let appliedFrame = set(window: window, frame: frame) {
                        appliedFramesByID[id] = appliedFrame
                    }
                }
                continue
            }
            let nativeStateKey = nativeStateKeyComponent(of: screenKey)
            guard let screen = screensByNativeStateKey[nativeStateKey] ?? windows.first(where: { $0.screen.stateKey == screenKey })?.screen else {
                continue
            }
            for id in state.windowIDs {
                guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { continue }
                let frame = hiddenFrame(for: window, on: screen)
                if let appliedFrame = set(window: window, frame: frame) {
                    appliedFramesByID[id] = appliedFrame
                }
            }
        }
        rememberPersistedLayouts(using: windows, limitingToStateKeys: stateKeyLimit)
    }
    private func updateLastAppliedWorkspaceIndices(using screens: [ScreenInfo]? = nil) {
        for screen in screens ?? currentScreenInfos() {
            lastAppliedWorkspaceIndexByNativeStateKey[screen.nativeStateKey] = activeWorkspaceIndex(forNativeStateKey: screen.nativeStateKey)
        }
    }
    private func hiddenFrame(for window: ManagedWindow, on screen: ScreenInfo) -> CGRect {
        let size = CGSize(
            width: max(window.frame.width, TileLayout.minimumWindowFrameSize.width),
            height: max(window.frame.height, TileLayout.minimumWindowFrameSize.height)
        )
        return CGRect(
            x: screen.frame.maxX - 1,
            y: screen.frame.maxY - 1,
            width: size.width,
            height: size.height
        )
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
        cancelPendingWorkspaceSwitchApply()
        if preserveLayout {
            scheduleSystemUISettleCheck(delay: max(0.35, duration + 0.10))
        }
    }
    private func shouldPauseLayoutForSystemUI() -> Bool {
        Date() < systemUILayoutPausedUntil
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
        if Date() < systemUILayoutPausedUntil {
            pauseLayoutForSystemUI(duration: 0.80, preserveLayout: true)
            return
        }
        refreshAppObservers()
        var allWindows = managedWindows()
        var tiled = tiledWindows(from: allWindows)
        guard isSystemUIWindowSnapshotStable(tiled) else {
            scheduleSystemUISettleCheck(delay: 0.35)
            return
        }
        let restoredFrozenLayout = restoreFrozenStatesIfWindowSetUnchanged(using: tiled)
        let restoredIdentityLayout = restoreKnownLayoutIdentities(using: tiled, sourceStates: frozenSystemUIScreenStates)
        let restoredPersistedLayout = restorePersistedLayouts(using: tiled)
        let focusedID = focusedWindowID(in: allWindows)
        let migratedWorkspaceStates = migrateWorkspaceStatesAfterScreenChangeIfNeeded(windows: allWindows, focusedID: focusedID)
        if migratedWorkspaceStates {
            invalidateManagedWindowCache(clearAppliedFrames: true)
            allWindows = managedWindows()
            tiled = tiledWindows(from: allWindows)
        }
        frozenSystemUIScreenStates = nil
        frozenSystemUIActiveStateKeys = nil
        resetSystemUIWindowSnapshotStability()
        if hasWindowSetChanged(tiled) {
            scheduleReconcile(delay: 0.05)
        } else if restoredFrozenLayout || restoredIdentityLayout || restoredPersistedLayout || migratedWorkspaceStates {
            applyLayout(to: allWindows)
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
            guard let fallback = frozenSystemUIScreenStates.first(where: { frozenKey, frozenState in
                    canMigrateState(from: frozenKey, to: key) && frozenState.windowIDs == ids
                  }) else {
                continue
            }
            if shouldRemoveStateAfterRestore(from: fallback.key, to: key) {
                screenStates.removeValue(forKey: fallback.key)
            }
            screenStates[key] = fallback.value
            restored = true
        }
        return restored
    }
    private func nativeStateKeyComponent(of stateKey: String) -> String {
        guard let range = stateKey.range(of: ScreenInfo.workspaceStateSeparator) else { return stateKey }
        return String(stateKey[..<range.lowerBound])
    }
    private func displayKeyComponent(of stateKey: String) -> String {
        nativeStateKeyComponent(of: stateKey)
    }
    private func canMigrateState(from storedKey: String, to currentKey: String) -> Bool {
        guard storedKey != currentKey else { return true }
        guard displayKeyComponent(of: storedKey) == displayKeyComponent(of: currentKey) else { return false }
        let storedWorkspaceIndex = ScreenInfo.workspaceIndex(from: storedKey)
        let currentWorkspaceIndex = ScreenInfo.workspaceIndex(from: currentKey)
        return storedWorkspaceIndex == nil || currentWorkspaceIndex == nil || storedWorkspaceIndex == currentWorkspaceIndex
    }
    private func shouldRemoveStateAfterRestore(from storedKey: String, to currentKey: String) -> Bool {
        storedKey != currentKey && canMigrateState(from: storedKey, to: currentKey)
    }
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
            migrated = migrateWorkspaceStates(toNativeStateKey: screen.nativeStateKey) || migrated
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
        let orphanedNativeStateKeys = orphanedNativeStateKeys(currentNativeStateKeys: currentNativeStateKeys)
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
    private func orphanedNativeStateKeys(currentNativeStateKeys: Set<String>) -> Set<String> {
        var keys: Set<String> = []
        for stateKey in screenStates.keys {
            let nativeStateKey = nativeStateKeyComponent(of: stateKey)
            if !currentNativeStateKeys.contains(nativeStateKey) {
                keys.insert(nativeStateKey)
            }
        }
        for snapshot in persistedLayoutsByStateKey.values {
            let nativeStateKey = nativeStateKeyComponent(of: snapshot.stateKey)
            if !currentNativeStateKeys.contains(nativeStateKey) {
                keys.insert(nativeStateKey)
            }
        }
        for stateKey in floatingWindowStateKeys.values {
            let nativeStateKey = nativeStateKeyComponent(of: stateKey)
            if !currentNativeStateKeys.contains(nativeStateKey) {
                keys.insert(nativeStateKey)
            }
        }
        for nativeStateKey in disconnectedNativeStateKeysPendingMigration
            where !currentNativeStateKeys.contains(nativeStateKey) && hasWorkspaceMetadata(forNativeStateKey: nativeStateKey) {
            keys.insert(nativeStateKey)
        }
        return keys
    }
    private func hasWorkspaceMetadata(forNativeStateKey nativeStateKey: String) -> Bool {
        if activeWorkspaceIndexByNativeStateKey[nativeStateKey] != nil ||
            activeWorkspaceIndexByDisplayKey[displayKeyComponent(of: nativeStateKey)] != nil {
            return true
        }
        return workspaceNames().keys.contains { nameKey in
            workspaceNameDisplayKey(from: nameKey) == displayKeyComponent(of: nativeStateKey)
        }
    }
    private func workspaceNameDisplayKey(from nameKey: String) -> String? {
        guard let separator = nameKey.lastIndex(of: ":") else { return nil }
        return String(nameKey[..<separator])
    }
    private func targetNativeStateKeyForOrphanedDisplay(
        _ sourceNativeStateKey: String,
        currentScreens: [ScreenInfo],
        windows: [ManagedWindow]?
    ) -> String? {
        if currentScreens.count == 1 {
            return currentScreens.first?.nativeStateKey
        }
        let sourceWindowIDs = windowIDs(inNativeStateKey: sourceNativeStateKey)
        if !sourceWindowIDs.isEmpty, let windows {
            let countsByNativeStateKey = windows.reduce(into: [String: Int]()) { counts, window in
                guard sourceWindowIDs.contains(window.id) else { return }
                let physicalScreen = screenInfo(for: window.frame, screens: currentScreens)
                counts[physicalScreen.nativeStateKey, default: 0] += 1
            }
            let rankedTargets = countsByNativeStateKey
                .filter { nativeStateKey, _ in
                    currentScreens.contains { $0.nativeStateKey == nativeStateKey }
                }
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
            if let first = rankedTargets.first,
               rankedTargets.dropFirst().first?.value != first.value {
                return first.key
            }
        }
        if let cursorScreen = screenContainingCursor() {
            let cursorInfo = screenInfo(forScreen: cursorScreen)
            if currentScreens.contains(where: { $0.nativeStateKey == cursorInfo.nativeStateKey }) {
                return cursorInfo.nativeStateKey
            }
        }
        if let main = NSScreen.main {
            let mainInfo = screenInfo(forScreen: main)
            if currentScreens.contains(where: { $0.nativeStateKey == mainInfo.nativeStateKey }) {
                return mainInfo.nativeStateKey
            }
        }
        return currentScreens.first?.nativeStateKey
    }
    private func windowIDs(inNativeStateKey nativeStateKey: String) -> Set<WindowIdentity> {
        var ids = Set(screenStates
            .filter { key, _ in nativeStateKeyComponent(of: key) == nativeStateKey }
            .values
            .flatMap(\.windowIDs))
        ids.formUnion(floatingWindowStateKeys.compactMap { id, stateKey in
            nativeStateKeyComponent(of: stateKey) == nativeStateKey ? id : nil
        })
        return ids
    }
    private func migrateOrphanedWorkspaceStates(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        focusedID: WindowIdentity?
    ) -> Bool {
        guard sourceNativeStateKey != targetNativeStateKey else { return false }
        let targetHadState = nativeStateKeyHasAnyScreenState(targetNativeStateKey)
        let sourceActiveIndex = storedActiveWorkspaceIndex(forNativeStateKey: sourceNativeStateKey)
        var focusedWorkspaceIndex: Int?
        var migrated = false
        for index in 0..<workspaceCount {
            let sourceKey = ScreenInfo.workspaceStateKey(nativeStateKey: sourceNativeStateKey, workspaceIndex: index)
            let targetKey = ScreenInfo.workspaceStateKey(nativeStateKey: targetNativeStateKey, workspaceIndex: index)
            if let focusedID, screenStates[sourceKey]?.contains(focusedID) == true {
                focusedWorkspaceIndex = index
            }
            migrated = migrateScreenState(from: sourceKey, to: targetKey, focusedID: focusedID) || migrated
            migrated = migratePersistedLayout(from: sourceKey, to: targetKey) || migrated
        }
        migrated = migrateFloatingWorkspaceStateKeys(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey,
            focusedWorkspaceIndex: &focusedWorkspaceIndex,
            focusedID: focusedID
        ) || migrated
        migrated = migrateActiveWorkspaceIndex(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey,
            sourceActiveIndex: sourceActiveIndex,
            focusedWorkspaceIndex: focusedWorkspaceIndex,
            targetHadState: targetHadState
        ) || migrated
        migrated = migrateWorkspaceNames(fromNativeStateKey: sourceNativeStateKey, toNativeStateKey: targetNativeStateKey) || migrated
        return migrated
    }
    private func nativeStateKeyHasAnyScreenState(_ nativeStateKey: String) -> Bool {
        screenStates.contains { stateKey, state in
            nativeStateKeyComponent(of: stateKey) == nativeStateKey && !state.isEmpty
        }
    }
    private func storedActiveWorkspaceIndex(forNativeStateKey nativeStateKey: String) -> Int? {
        let index = activeWorkspaceIndexByNativeStateKey[nativeStateKey]
            ?? activeWorkspaceIndexByDisplayKey[displayKeyComponent(of: nativeStateKey)]
        return index.map(clampedWorkspaceIndex)
    }
    private func migrateScreenState(from sourceKey: String, to targetKey: String, focusedID: WindowIdentity?) -> Bool {
        guard let sourceState = screenStates.removeValue(forKey: sourceKey) else { return false }
        guard !sourceState.isEmpty else { return true }
        let preferSourceFocus = focusedID.map { sourceState.contains($0) } ?? false
        if var targetState = screenStates[targetKey], !targetState.isEmpty {
            targetState.merge(sourceState, preferSourceFocus: preferSourceFocus)
            screenStates[targetKey] = targetState
        } else {
            screenStates[targetKey] = sourceState
        }
        return true
    }
    private func migratePersistedLayout(from sourceKey: String, to targetKey: String) -> Bool {
        guard let sourceSnapshot = persistedLayoutsByStateKey.removeValue(forKey: sourceKey) else { return false }
        if let targetSnapshot = persistedLayoutsByStateKey[targetKey] {
            persistedLayoutsByStateKey[targetKey] = mergedPersistedLayout(
                targetSnapshot,
                with: sourceSnapshot,
                targetKey: targetKey
            )
        } else {
            persistedLayoutsByStateKey[targetKey] = PersistedScreenLayout(
                stateKey: targetKey,
                displayKey: displayKeyComponent(of: targetKey),
                tree: sourceSnapshot.tree,
                entriesByID: sourceSnapshot.entriesByID,
                lastFocusedEntryID: sourceSnapshot.lastFocusedEntryID,
                lastUpdated: sourceSnapshot.lastUpdated
            )
        }
        return true
    }
    private func mergedPersistedLayout(
        _ target: PersistedScreenLayout,
        with source: PersistedScreenLayout,
        targetKey: String
    ) -> PersistedScreenLayout {
        var tree = target.tree
        var entriesByID = target.entriesByID
        var nextEntryID = (entriesByID.keys.max() ?? 0) + 1
        var sourceEntryIDReplacements: [Int: Int] = [:]
        for sourceEntryID in source.tree.ids {
            guard let sourceEntry = source.entriesByID[sourceEntryID] else { continue }
            let replacementEntryID = nextEntryID
            nextEntryID += 1
            sourceEntryIDReplacements[sourceEntryID] = replacementEntryID
            entriesByID[replacementEntryID] = PersistedWindowLayoutEntry(
                id: replacementEntryID,
                pid: sourceEntry.pid,
                bundleIdentifier: sourceEntry.bundleIdentifier,
                layoutIdentity: sourceEntry.layoutIdentity,
                orderRank: sourceEntry.orderRank,
                scanIndex: sourceEntry.scanIndex
            )
        }
        if tree.isEmpty,
           let sourceTree = source.tree.compactMapIDs({ sourceEntryIDReplacements[$0] }) {
            tree = sourceTree
        } else {
            var insertionTarget = target.lastFocusedEntryID ?? tree.largestLeafID() ?? tree.firstID
            for sourceEntryID in source.tree.ids {
                guard let replacementEntryID = sourceEntryIDReplacements[sourceEntryID] else { continue }
                tree.insert(replacementEntryID, near: insertionTarget, placement: .automatic)
                insertionTarget = replacementEntryID
            }
        }
        let sourceFocusedEntryID = source.lastFocusedEntryID.flatMap { sourceEntryIDReplacements[$0] }
        return PersistedScreenLayout(
            stateKey: targetKey,
            displayKey: displayKeyComponent(of: targetKey),
            tree: tree,
            entriesByID: entriesByID,
            lastFocusedEntryID: target.lastFocusedEntryID ?? sourceFocusedEntryID,
            lastUpdated: max(target.lastUpdated, source.lastUpdated)
        )
    }
    private func migrateFloatingWorkspaceStateKeys(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        focusedWorkspaceIndex: inout Int?,
        focusedID: WindowIdentity?
    ) -> Bool {
        var migrated = false
        for (id, sourceKey) in floatingWindowStateKeys {
            guard nativeStateKeyComponent(of: sourceKey) == sourceNativeStateKey,
                  let workspaceIndex = ScreenInfo.workspaceIndex(from: sourceKey),
                  workspaceIndex < workspaceCount else {
                continue
            }
            if id == focusedID {
                focusedWorkspaceIndex = workspaceIndex
            }
            floatingWindowStateKeys[id] = ScreenInfo.workspaceStateKey(
                nativeStateKey: targetNativeStateKey,
                workspaceIndex: workspaceIndex
            )
            migrated = true
        }
        return migrated
    }
    private func migrateActiveWorkspaceIndex(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        sourceActiveIndex: Int?,
        focusedWorkspaceIndex: Int?,
        targetHadState: Bool
    ) -> Bool {
        var migrated = false
        if activeWorkspaceIndexByNativeStateKey.removeValue(forKey: sourceNativeStateKey) != nil {
            migrated = true
        }
        if activeWorkspaceIndexByDisplayKey.removeValue(forKey: displayKeyComponent(of: sourceNativeStateKey)) != nil {
            migrated = true
        }
        if let focusedWorkspaceIndex {
            setActiveWorkspaceIndex(focusedWorkspaceIndex, forNativeStateKey: targetNativeStateKey)
            return true
        }
        if !targetHadState, let sourceActiveIndex {
            setActiveWorkspaceIndex(sourceActiveIndex, forNativeStateKey: targetNativeStateKey)
            return true
        }
        return migrated
    }
    private func migrateWorkspaceNames(fromNativeStateKey sourceNativeStateKey: String, toNativeStateKey targetNativeStateKey: String) -> Bool {
        var names = workspaceNames()
        var migrated = false
        for index in 0..<workspaceCount {
            let sourceKey = workspaceNameKey(forNativeStateKey: sourceNativeStateKey, workspaceIndex: index)
            let targetKey = workspaceNameKey(forNativeStateKey: targetNativeStateKey, workspaceIndex: index)
            guard let sourceName = names[sourceKey], names[targetKey] == nil else { continue }
            names[targetKey] = sourceName
            names.removeValue(forKey: sourceKey)
            migrated = true
        }
        if migrated {
            UserDefaults.standard.set(names, forKey: workspaceNamesDefaultsKey)
        }
        return migrated
    }
    private func migrateWorkspaceStates(toNativeStateKey targetNativeStateKey: String) -> Bool {
        var migrated = false
        for index in 0..<workspaceCount {
            let targetKey = ScreenInfo.workspaceStateKey(nativeStateKey: targetNativeStateKey, workspaceIndex: index)
            migrated = migrateScreenState(to: targetKey) || migrated
            migrated = migratePersistedLayout(to: targetKey) || migrated
        }
        migrated = migrateFloatingWorkspaceStateKeys(toNativeStateKey: targetNativeStateKey) || migrated
        return migrated
    }
    private func migrateScreenState(to targetKey: String) -> Bool {
        guard screenStates[targetKey] == nil else { return false }
        let candidates = screenStates.filter { sourceKey, state in
            sourceKey != targetKey && canMigrateState(from: sourceKey, to: targetKey) && !state.isEmpty
        }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        screenStates[targetKey] = candidate.value
        screenStates.removeValue(forKey: candidate.key)
        return true
    }
    private func migratePersistedLayout(to targetKey: String) -> Bool {
        guard persistedLayoutsByStateKey[targetKey] == nil else { return false }
        let candidates = persistedLayoutsByStateKey.values
            .filter { $0.stateKey != targetKey && canMigrateState(from: $0.stateKey, to: targetKey) }
            .sorted { lhs, rhs in
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                return lhs.stateKey < rhs.stateKey
            }
        guard let snapshot = candidates.first else { return false }
        persistedLayoutsByStateKey.removeValue(forKey: snapshot.stateKey)
        persistedLayoutsByStateKey[targetKey] = PersistedScreenLayout(
            stateKey: targetKey,
            displayKey: displayKeyComponent(of: targetKey),
            tree: snapshot.tree,
            entriesByID: snapshot.entriesByID,
            lastFocusedEntryID: snapshot.lastFocusedEntryID,
            lastUpdated: snapshot.lastUpdated
        )
        return true
    }
    private func migrateFloatingWorkspaceStateKeys(toNativeStateKey targetNativeStateKey: String) -> Bool {
        var migrated = false
        for (id, sourceKey) in floatingWindowStateKeys {
            guard let workspaceIndex = ScreenInfo.workspaceIndex(from: sourceKey),
                  workspaceIndex < workspaceCount else {
                continue
            }
            let targetKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: targetNativeStateKey,
                workspaceIndex: workspaceIndex
            )
            guard sourceKey != targetKey, canMigrateState(from: sourceKey, to: targetKey) else { continue }
            floatingWindowStateKeys[id] = targetKey
            migrated = true
        }
        return migrated
    }
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
                if shouldRemoveStateAfterRestore(from: storedKey, to: currentKey) {
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
        let currentLayoutIdentities = layoutIdentityItems(forWindows: windows)
        guard !currentLayoutIdentities.isEmpty else { return nil }
        var bestMatch: (key: String, count: Int)?
        var hasAmbiguousBestMatch = false
        for (storedKey, state) in states where canMigrateState(from: storedKey, to: currentKey) {
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
                if shouldRemoveStateAfterRestore(from: snapshot.stateKey, to: currentKey) {
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
        let fallbackCandidates = persistedLayoutsByStateKey.values
            .filter { $0.stateKey != currentKey && canMigrateState(from: $0.stateKey, to: currentKey) }
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
    private func rememberPersistedLayouts(using windows: [ManagedWindow], limitingToStateKeys stateKeyLimit: Set<String>? = nil) {
        guard !windows.isEmpty else { return }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (stateKey, state) in screenStates where !state.isEmpty {
            if let stateKeyLimit, !stateKeyLimit.contains(stateKey) { continue }
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
    private func workspaceDeletionAvailability(index: Int) -> (canDelete: Bool, reason: String?) {
        guard workspaceCount > 1 else {
            return (false, "Only Workspace")
        }
        guard index >= 0, index < workspaceCount else {
            return (false, "Unavailable")
        }
        guard workspaceIsEmptyEverywhere(index: index) else {
            return (false, "Not Empty")
        }
        return (true, nil)
    }
    private func workspaceIsEmptyEverywhere(index: Int) -> Bool {
        let hasTiledWindows = screenStates.contains { key, state in
            ScreenInfo.workspaceIndex(from: key) == index && !state.isEmpty
        }
        let hasFloatingWindows = floatingWindowStateKeys.values.contains { stateKey in
            ScreenInfo.workspaceIndex(from: stateKey) == index
        }
        return !hasTiledWindows && !hasFloatingWindows
    }
    private func shiftedScreenStates(deletingWorkspaceIndex index: Int) -> [String: ScreenTileState] {
        var shifted: [String: ScreenTileState] = [:]
        for (stateKey, state) in screenStates where !state.isEmpty {
            guard let shiftedKey = shiftedWorkspaceStateKey(stateKey, deletingWorkspaceIndex: index) else { continue }
            shifted[shiftedKey] = state
        }
        return shifted
    }
    private func shiftedPersistedLayouts(deletingWorkspaceIndex index: Int) -> [String: PersistedScreenLayout] {
        var shifted: [String: PersistedScreenLayout] = [:]
        for snapshot in persistedLayoutsByStateKey.values {
            guard let shiftedKey = shiftedWorkspaceStateKey(snapshot.stateKey, deletingWorkspaceIndex: index) else {
                continue
            }
            let shiftedSnapshot = PersistedScreenLayout(
                stateKey: shiftedKey,
                displayKey: displayKeyComponent(of: shiftedKey),
                tree: snapshot.tree,
                entriesByID: snapshot.entriesByID,
                lastFocusedEntryID: snapshot.lastFocusedEntryID,
                lastUpdated: snapshot.lastUpdated
            )
            if let existing = shifted[shiftedKey], existing.lastUpdated > shiftedSnapshot.lastUpdated {
                continue
            }
            shifted[shiftedKey] = shiftedSnapshot
        }
        return shifted
    }
    private func shiftedWorkspaceStateKey(_ stateKey: String, deletingWorkspaceIndex index: Int) -> String? {
        guard let workspaceIndex = ScreenInfo.workspaceIndex(from: stateKey) else { return stateKey }
        if workspaceIndex == index {
            return nil
        }
        guard workspaceIndex > index else { return stateKey }
        return ScreenInfo.workspaceStateKey(
            nativeStateKey: nativeStateKeyComponent(of: stateKey),
            workspaceIndex: workspaceIndex - 1
        )
    }
    private func shiftedActiveWorkspaceIndex(
        _ activeIndex: Int,
        deletingWorkspaceIndex index: Int,
        newWorkspaceCount: Int
    ) -> Int {
        let shifted = activeIndex > index ? activeIndex - 1 : min(activeIndex, newWorkspaceCount - 1)
        return min(max(shifted, 0), max(newWorkspaceCount - 1, 0))
    }
    private func clampedWorkspaceIndex(_ index: Int) -> Int {
        min(max(index, 0), workspaceCount - 1)
    }
    private func availableWorkspaceIndex(_ index: Int) -> Int? {
        guard index >= 0, index < workspaceCount else { return nil }
        return index
    }
    private func wrappedWorkspaceIndex(_ index: Int) -> Int {
        let count = max(1, workspaceCount)
        return ((index % count) + count) % count
    }
    private func activeWorkspaceIndex(forNativeStateKey nativeStateKey: String) -> Int {
        let displayKey = displayKeyComponent(of: nativeStateKey)
        let fallbackIndex = activeWorkspaceIndexByDisplayKey[displayKey]
            ?? activeWorkspaceIndexByNativeStateKey.first { displayKeyComponent(of: $0.key) == displayKey }?.value
            ?? 0
        let index = clampedWorkspaceIndex(activeWorkspaceIndexByNativeStateKey[nativeStateKey] ?? fallbackIndex)
        activeWorkspaceIndexByNativeStateKey[nativeStateKey] = index
        activeWorkspaceIndexByDisplayKey[displayKey] = index
        return index
    }
    private func setActiveWorkspaceIndex(_ index: Int, forNativeStateKey nativeStateKey: String) {
        let index = clampedWorkspaceIndex(index)
        activeWorkspaceIndexByNativeStateKey[nativeStateKey] = index
        activeWorkspaceIndexByDisplayKey[displayKeyComponent(of: nativeStateKey)] = index
    }
    private func workspaceName(forNativeStateKey nativeStateKey: String, workspaceIndex: Int) -> String? {
        workspaceNames()[workspaceNameKey(forNativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)]
    }
    private func setWorkspaceName(_ name: String, forNativeStateKey nativeStateKey: String, workspaceIndex: Int) {
        var names = workspaceNames()
        let key = workspaceNameKey(forNativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty {
            names.removeValue(forKey: key)
        } else {
            names[key] = String(normalizedName.prefix(48))
        }
        UserDefaults.standard.set(names, forKey: workspaceNamesDefaultsKey)
    }
    private func workspaceNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: workspaceNamesDefaultsKey) as? [String: String] ?? [:]
    }
    private func workspaceNameKey(forNativeStateKey nativeStateKey: String, workspaceIndex: Int) -> String {
        "\(displayKeyComponent(of: nativeStateKey)):\(workspaceIndex)"
    }
    private func shiftWorkspaceNames(deletingWorkspaceIndex deletingIndex: Int) {
        var shiftedNames: [String: String] = [:]
        for (key, name) in workspaceNames() {
            guard let separator = key.lastIndex(of: ":"),
                  let index = Int(key[key.index(after: separator)...]) else {
                shiftedNames[key] = name
                continue
            }
            if index == deletingIndex {
                continue
            }
            let displayKey = String(key[..<separator])
            let nextIndex = index > deletingIndex ? index - 1 : index
            shiftedNames["\(displayKey):\(nextIndex)"] = name
        }
        UserDefaults.standard.set(shiftedNames, forKey: workspaceNamesDefaultsKey)
    }
    private func currentWorkspaceContext(
        windows providedWindows: [ManagedWindow]? = nil,
        focusedID providedFocusedID: WindowIdentity? = nil
    ) -> WorkspaceContext? {
        if hasAccessibilityPermission(prompt: false) {
            let windows = providedWindows ?? managedWindows()
            let focusedID = providedFocusedID ?? focusedWindowID(in: windows)
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
        let activeIndex = activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
        let activeScreen = ScreenInfo(
            key: screen.key,
            frame: screen.frame,
            displayID: screen.displayID,
            workspaceIndex: activeIndex
        )
        return WorkspaceContext(screen: activeScreen, nativeStateKey: nativeStateKey, activeWorkspaceIndex: activeIndex)
    }
    private func screenInfo(forScreen screen: NSScreen) -> ScreenInfo {
        let displayID = screen.displayID
        let displayKey = ScreenInfo.displayKey(for: displayID, frame: screen.frame)
        let nativeStateKey = ScreenInfo.nativeStateKey(displayKey: displayKey)
        return ScreenInfo(
            key: displayKey,
            frame: accessibilityVisibleFrame(for: screen),
            displayID: displayID,
            workspaceIndex: activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
        )
    }
    private func screenContainingCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) }
    }
    private func displayName(for screen: ScreenInfo) -> String {
        guard let displayID = screen.displayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            return "Current Display"
        }
        return screen.localizedName
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
            ?? normalizedWindowString(window?.bundleIdentifier)
            ?? layoutIdentity?.bundleIdentifier
        let title = normalizedWindowString(window?.title)
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
        let nativeStateKey = nativeStateKeyComponent(of: stateKey)
        let screens = currentScreenInfos()
        if let screen = screens.first(where: { $0.nativeStateKey == nativeStateKey }) {
            return screen.withStateKeyOverride(stateKey)
        }
        let displayKey = displayKeyComponent(of: stateKey)
        let workspaceIndex = ScreenInfo.workspaceIndex(from: stateKey)
        if let screen = screens.first(where: { screen in
            displayKeyComponent(of: screen.nativeStateKey) == displayKey &&
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
    private func managedWindows(useCache: Bool = false, cacheDuration: TimeInterval? = nil) -> [ManagedWindow] {
        let now = Date()
        let allowedCacheAge = cacheDuration ?? defaultWindowCacheDuration
        if useCache,
           let managedWindowCache,
           now.timeIntervalSince(managedWindowCache.createdAt) <= allowedCacheAge {
            return managedWindowCache.windows
        }
        let windows = managedWindows(snapshot: onScreenWindowSnapshot())
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
            guard let frame = lastAppliedFrameByWindowID[window.id], !approximatelyEqual(frame, window.frame) else { continue }
            lastAppliedFrameByWindowID.removeValue(forKey: window.id)
        }
    }
    private func managedWindows(snapshot: OnScreenWindowSnapshot) -> [ManagedWindow] {
        lastVisibleWindowSignature = VisibleWindowSignature(snapshot: snapshot)
        let screens = currentScreenInfos()
        let apps = NSWorkspace.shared.runningApplications
            .filter(isManageableApp)
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }
        var candidates: [ManagedWindowCandidate] = []
        var scanIndex = 0
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
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
                guard frameIntersectsAnyVisibleScreen(frame, screens: screens),
                      isManageableWindow(window, app: app, frame: frame, title: title) else {
                    continue
                }
                let screen = screenInfo(for: frame, screens: screens)
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
        let activeStateKeys = Set(screens.map(\.stateKey))
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
            let screen = stateKey(containing: id, activeStateKeys: activeStateKeys)
                .map { screenInfo(forKnownStateKey: $0, fallback: candidate.screen) }
                ?? candidate.screen
            windows.append(ManagedWindow(
                id: id,
                windowNumber: candidate.windowNumber,
                element: candidate.element,
                screen: screen,
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
        refreshLastAppliedFrames(using: windows, retaining: retainedIDs)
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
        return true
    }
    private func focusedWindowIDForHotKey(in windows: [ManagedWindow]) -> WindowIdentity? {
        if let lastKnownFocusedWindowID,
           windows.contains(where: { $0.id == lastKnownFocusedWindowID }) {
            return lastKnownFocusedWindowID
        }
        let focusedID = focusedWindowID(in: windows)
        if let focusedID {
            lastKnownFocusedWindowID = focusedID
        }
        return focusedID
    }
    private func focusedWindowID(in windows: [ManagedWindow]) -> WindowIdentity? {
        guard let focusedWindow = focusedWindow() else { return nil }
        if let exactMatch = windows.first(where: { CFEqual($0.element, focusedWindow) }) {
            lastKnownFocusedWindowID = exactMatch.id
            return exactMatch.id
        }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &focusedPID) == .success else { return nil }
        if let number = copyInt(focusedWindow, attribute: "AXWindowNumber") ?? copyInt(focusedWindow, attribute: "_AXWindowNumber") {
            let focusedID = windows.first { $0.id.pid == focusedPID && $0.windowNumber == number }?.id
            if let focusedID { lastKnownFocusedWindowID = focusedID }
            return focusedID
        }
        let focusedID = windows.first { candidate in
            candidate.id.pid == focusedPID && windowsRepresentSameWindow(candidate.element, focusedWindow)
        }?.id
        if let focusedID { lastKnownFocusedWindowID = focusedID }
        return focusedID
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
        AXUIElementSetMessagingTimeout(axApp, accessibilityMessagingTimeout)
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
        lastKnownFocusedWindowID = window.id
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.id.pid,
           let app = NSRunningApplication(processIdentifier: window.id.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let appElement = AXUIElementCreateApplication(window.id.pid)
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if updateTreeFocus, let key = stateKey(containing: window.id), var state = screenStates[key] {
            state.markFocused(window.id)
            screenStates[key] = state
        }
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
    @discardableResult
    private func set(window: ManagedWindow, frame: CGRect) -> CGRect? {
        let frame = sanitizedFrame(frame)
        if approximatelyEqual(window.frame, frame) {
            lastAppliedFrameByWindowID[window.id] = frame
            return nil
        }
        // Do not synchronously read the AX frame here. AX reads are one of the slowest
        // operations on the hot resize/workspace paths; a later window scan refreshes
        // this cache and will re-apply if the app rejected the write.
        applyFrame(frame, to: window.element)
        lastAppliedFrameByWindowID[window.id] = frame
        return frame
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
    private func applyPosition(_ origin: CGPoint, to window: AXUIElement) {
        var origin = CGPoint(
            x: origin.x.rounded(.toNearestOrAwayFromZero),
            y: origin.y.rounded(.toNearestOrAwayFromZero)
        )
        guard let positionValue = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }
    private func sanitizedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
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
        NSScreen.screens.map { screen in
            let displayID = screen.displayID
            let displayKey = ScreenInfo.displayKey(for: displayID, frame: screen.frame)
            let nativeStateKey = ScreenInfo.nativeStateKey(displayKey: displayKey)
            return ScreenInfo(
                key: displayKey,
                frame: accessibilityVisibleFrame(for: screen),
                displayID: displayID,
                workspaceIndex: activeWorkspaceIndex(forNativeStateKey: nativeStateKey)
            )
        }
    }
    private func screenInfo(for windowRect: CGRect, screens: [ScreenInfo]) -> ScreenInfo {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if let bestIndex = ScreenGeometry.bestScreenIndex(for: windowRect, screens: screens.map(\.frame)) {
            return screens[bestIndex]
        }
        if let containingScreen = screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen
        }
        return screens.min { lhs, rhs in
            lhs.frame.distanceSquared(to: center) < rhs.frame.distanceSquared(to: center)
        } ?? ScreenInfo(
            key: "fallback",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            displayID: nil,
            workspaceIndex: 0
        )
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
    private func frameIntersectsAnyVisibleScreen(_ frame: CGRect, screens: [ScreenInfo]) -> Bool {
        screens.contains { $0.frame.intersects(frame) }
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
    static let workspaceStateSeparator = ":workspace:"
    let key: String
    let frame: CGRect
    let displayID: CGDirectDisplayID?
    let workspaceIndex: Int
    private let stateKeyOverride: String?
    init(
        key: String,
        frame: CGRect,
        displayID: CGDirectDisplayID?,
        workspaceIndex: Int,
        stateKeyOverride: String? = nil
    ) {
        self.key = key
        self.frame = frame
        self.displayID = displayID
        self.workspaceIndex = workspaceIndex
        self.stateKeyOverride = stateKeyOverride
    }
    var nativeStateKey: String {
        Self.nativeStateKey(displayKey: key)
    }
    var stateKey: String {
        stateKeyOverride ?? Self.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)
    }
    func withStateKeyOverride(_ stateKey: String) -> ScreenInfo {
        ScreenInfo(
            key: key,
            frame: frame,
            displayID: displayID,
            workspaceIndex: Self.workspaceIndex(from: stateKey) ?? workspaceIndex,
            stateKeyOverride: stateKey
        )
    }
    func withoutStateKeyOverride() -> ScreenInfo {
        ScreenInfo(
            key: key,
            frame: frame,
            displayID: displayID,
            workspaceIndex: workspaceIndex
        )
    }
    static func nativeStateKey(displayKey: String) -> String {
        displayKey
    }
    static func workspaceStateKey(nativeStateKey: String, workspaceIndex: Int) -> String {
        "\(nativeStateKey)\(workspaceStateSeparator)\(workspaceIndex)"
    }
    static func workspaceIndex(from stateKey: String) -> Int? {
        guard let range = stateKey.range(of: workspaceStateSeparator) else { return nil }
        return Int(stateKey[range.upperBound...])
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
    func withFrame(_ frame: CGRect) -> ManagedWindow {
        ManagedWindow(
            id: id,
            windowNumber: windowNumber,
            element: element,
            screen: screen,
            layoutIdentity: layoutIdentity,
            frame: frame,
            bundleIdentifier: bundleIdentifier,
            title: title,
            orderRank: orderRank,
            scanIndex: scanIndex
        )
    }
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
    mutating func merge(_ source: ScreenTileState, preferSourceFocus: Bool) {
        guard !source.isEmpty else { return }
        guard !isEmpty else {
            self = source
            return
        }
        let preservedFocus = focusedWindowID
        var insertionTarget = lastFocusedOrLargestID
        for item in source.slotList {
            guard !tree.contains(item.id) else { continue }
            tree.insert(item.id, near: insertionTarget, placement: .automatic)
            insertionTarget = item.id
        }
        if preferSourceFocus, let sourceFocus = source.focusedWindowID ?? source.lastFocusedOrLargestID {
            markFocusedIfKnown(sourceFocus)
        } else if let preservedFocus {
            markFocusedIfKnown(preservedFocus)
        } else if let insertionTarget {
            markFocusedIfKnown(insertionTarget)
        }
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
private final class WorkspaceOverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextFrame(for: super.drawingRect(forBounds: rect), bounds: rect)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredTextFrame(for: rect, bounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredTextFrame(for: rect, bounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    private func centeredTextFrame(for frame: NSRect, bounds: NSRect) -> NSRect {
        let textHeight = min(cellSize(forBounds: bounds).height, frame.height)
        let yOffset = max(0, floor((frame.height - textHeight) / 2))
        return NSRect(
            x: frame.minX,
            y: frame.minY + yOffset,
            width: frame.width,
            height: textHeight
        )
    }
}
private final class WorkspaceOverviewOverlay {
    private var panel: WorkspaceOverviewPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var onDismiss: (() -> Void)?
    private var overview: WorkspaceOverview?
    var workspaceCount: Int? {
        overview?.workspaceCount
    }
    func show(_ overview: WorkspaceOverview, onDismiss: @escaping () -> Void) {
        hide(notify: true)
        self.overview = overview
        self.onDismiss = onDismiss
        let panel = ensurePanel()
        let frame = Self.panelFrame(for: overview)
        panel.setFrame(frame, display: true)
        let view = WorkspaceOverviewView(overview: overview)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }
    @discardableResult
    func beginRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> Bool {
        guard let overview, let view = overviewView else { return false }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = ensurePanel()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        view.beginRenaming(
            text: overview.activeWorkspaceName ?? "",
            onCommit: { [weak self] name in
                self?.finishRenameMode()
                onCommit(name)
            },
            onCancel: { [weak self] in
                self?.finishRenameMode()
                onCancel()
            }
        )
        return true
    }
    private var overviewView: WorkspaceOverviewView? {
        panel?.contentView as? WorkspaceOverviewView
    }
    private func finishRenameMode() {
        overviewView?.endRenaming()
        panel?.ignoresMouseEvents = true
        scheduleAutoHide()
    }
    private func scheduleAutoHide() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: workItem)
    }
    func hide() {
        hide(notify: true)
    }
    private func hide(notify: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        overviewView?.endRenaming()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        guard notify else { return }
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        overview = nil
        onDismiss?()
    }
    func close() {
        hide(notify: true)
        panel?.close()
        panel = nil
    }
    private func ensurePanel() -> WorkspaceOverviewPanel {
        if let panel { return panel }
        let panel = WorkspaceOverviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        self.panel = panel
        return panel
    }
    private static func panelFrame(for overview: WorkspaceOverview) -> CGRect {
        let screen = overview.displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 760, height: 520)
        let columns = min(3, max(1, overview.items.count))
        let rows = max(1, Int(ceil(Double(max(1, overview.items.count)) / Double(columns))))
        let idealWidth = CGFloat(columns) * 184 + CGFloat(max(0, columns - 1)) * 10 + 48
        let idealHeight = 86 + CGFloat(rows) * 116 + CGFloat(max(0, rows - 1)) * 10 + 40
        let width = min(max(380, idealWidth), max(320, visibleFrame.width - 56))
        let height = min(max(240, idealHeight), max(200, visibleFrame.height - 56))
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
private final class WorkspaceOverviewView: NSView, NSTextFieldDelegate {
    private let overview: WorkspaceOverview
    private weak var activeHeaderLabel: NSTextField?
    private weak var activeRenameField: NSTextField?
    private var activeDetailViews: [NSView] = []
    private var onRenameCommit: ((String) -> Void)?
    private var onRenameCancel: (() -> Void)?
    init(overview: WorkspaceOverview) {
        self.overview = overview
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    private func buildView() {
        activeDetailViews.removeAll()
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        let title = label(
            "MacPane Workspaces",
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: .labelColor
        )
        let subtitle = label(
            "\(overview.displayName) - Workspace \(overview.activeWorkspaceIndex + 1)/\(overview.workspaceCount)",
            font: .systemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor
        )
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        root.addArrangedSubview(titleStack)
        let grid = workspaceGrid()
        root.addArrangedSubview(grid)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            contentView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            titleStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            grid.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }
    private func workspaceGrid() -> NSStackView {
        let columns = min(3, max(1, overview.items.count))
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .width
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < overview.items.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            for _ in 0..<columns {
                if index < overview.items.count {
                    row.addArrangedSubview(card(for: overview.items[index]))
                    index += 1
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }
    private func card(for item: WorkspaceOverviewItem) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = item.isActive ? 2 : 1
        card.layer?.borderColor = (item.isActive ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        card.layer?.backgroundColor = (item.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.72)).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 116).isActive = true
        let numberBackdrop = workspaceNumberBackdrop(for: item)
        card.addSubview(numberBackdrop)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        let header = label(
            workspaceTitle(for: item),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        stack.addArrangedSubview(header)
        if item.isActive {
            activeHeaderLabel = header
            let renameField = renameTextField()
            renameField.isHidden = true
            activeRenameField = renameField
            stack.addArrangedSubview(renameField)
        }
        if item.windows.isEmpty {
            let emptyLabel = label(
                "No tiled windows",
                font: .systemFont(ofSize: 12, weight: .regular),
                color: .tertiaryLabelColor
            )
            stack.addArrangedSubview(emptyLabel)
            if item.isActive {
                activeDetailViews.append(emptyLabel)
            }
        } else {
            for window in item.windows.prefix(4) {
                let label = windowLabel(for: window)
                stack.addArrangedSubview(label)
                if item.isActive {
                    activeDetailViews.append(label)
                }
            }
            if item.windows.count > 4 {
                let moreLabel = label(
                    "+\(item.windows.count - 4) more",
                    font: .systemFont(ofSize: 11, weight: .regular),
                    color: .secondaryLabelColor
                )
                stack.addArrangedSubview(moreLabel)
                if item.isActive {
                    activeDetailViews.append(moreLabel)
                }
            }
        }
        NSLayoutConstraint.activate([
            numberBackdrop.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            numberBackdrop.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            numberBackdrop.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 8),
            numberBackdrop.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }
    func beginRenaming(text: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard let activeRenameField else { return }
        onRenameCommit = onCommit
        onRenameCancel = onCancel
        activeHeaderLabel?.isHidden = true
        activeDetailViews.forEach { $0.isHidden = true }
        activeRenameField.stringValue = text
        activeRenameField.isHidden = false
        DispatchQueue.main.async { [weak self, weak activeRenameField] in
            guard let self, let activeRenameField else { return }
            self.window?.makeFirstResponder(activeRenameField)
            activeRenameField.selectText(nil)
        }
    }
    func endRenaming() {
        activeRenameField?.isHidden = true
        activeHeaderLabel?.isHidden = false
        activeDetailViews.forEach { $0.isHidden = false }
        onRenameCommit = nil
        onRenameCancel = nil
        window?.makeFirstResponder(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitActiveRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelActiveRename()
            return true
        default:
            return false
        }
    }
    private func commitActiveRename() {
        guard let activeRenameField, let onRenameCommit else { return }
        self.onRenameCommit = nil
        self.onRenameCancel = nil
        onRenameCommit(activeRenameField.stringValue)
    }
    private func cancelActiveRename() {
        guard let onRenameCancel else { return }
        self.onRenameCommit = nil
        self.onRenameCancel = nil
        onRenameCancel()
    }
    private func workspaceTitle(for item: WorkspaceOverviewItem) -> String {
        let defaultTitle = "Workspace \(item.index + 1)"
        return item.name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle
    }
    private func workspaceNumberBackdrop(for item: WorkspaceOverviewItem) -> NSTextField {
        let label = NSTextField(labelWithString: "\(item.index + 1)")
        label.font = .monospacedDigitSystemFont(ofSize: 58, weight: .bold)
        label.textColor = NSColor.labelColor.withAlphaComponent(item.isActive ? 0.13 : 0.08)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
    private func renameTextField() -> NSTextField {
        let field = NSTextField(string: "")
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.layer?.masksToBounds = true
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return field
    }
    private func windowLabel(for window: WorkspaceOverviewWindow) -> NSTextField {
        let prefix = window.isFocused ? "> " : "- "
        let detail = window.detail.map { " (\($0))" } ?? ""
        return label(
            "\(prefix)\(window.title)\(detail)",
            font: .systemFont(ofSize: 11, weight: window.isFocused ? .semibold : .regular),
            color: window.isFocused ? .labelColor : .secondaryLabelColor
        )
    }
    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
private final class WorkspaceSwitchIndicatorOverlay {
    private var panel: NSPanel?
    private var indicatorView: WorkspaceSwitchIndicatorView?
    private var fadeWorkItem: DispatchWorkItem?
    private var generation = 0
    func show(workspaceNumber: Int, displayID: CGDirectDisplayID?) {
        show(text: "\(workspaceNumber)", displayID: displayID)
    }
    func show(text: String, displayID: CGDirectDisplayID?) {
        generation += 1
        let currentGeneration = generation
        fadeWorkItem?.cancel()
        let panel = ensurePanel()
        indicatorView?.setText(text)
        panel.setFrame(Self.panelFrame(displayID: displayID), display: true)
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, self.generation == currentGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: {
                guard self.generation == currentGeneration else { return }
                panel.orderOut(nil)
            }
        }
        fadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }
    func close() {
        generation += 1
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        indicatorView = nil
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
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        let indicatorView = WorkspaceSwitchIndicatorView()
        panel.contentView = indicatorView
        self.indicatorView = indicatorView
        self.panel = panel
        return panel
    }
    private static func panelFrame(displayID: CGDirectDisplayID?) -> CGRect {
        let screen = displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? Self.screenContainingCursor() ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 150, height: 150)
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
    private static func screenContainingCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) }
    }
}
private final class WorkspaceSwitchIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    func setText(_ text: String) {
        label.stringValue = text
        label.font = text.count <= 1
            ? .monospacedDigitSystemFont(ofSize: 76, weight: .bold)
            : .systemFont(ofSize: 58, weight: .bold)
    }
    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.26).cgColor
        layer?.borderWidth = 1
        label.font = .monospacedDigitSystemFont(ofSize: 76, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
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
