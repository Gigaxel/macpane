import AppKit
import ApplicationServices

@main
final class MacPaneApp: NSObject, NSApplicationDelegate, HotKeyHandling, NSMenuDelegate {
    private static let sharedDelegate = MacPaneApp()
    private var statusItem: NSStatusItem?
    private let tiler = WindowTiler()
    private let workspaceOverviewOverlay = WorkspaceOverviewOverlay()
    private let workspaceSwitchIndicatorOverlay = WorkspaceSwitchIndicatorOverlay()
    private lazy var settingsStore = SettingsStore(tiler: tiler)
    private lazy var settingsWindowController = SettingsWindowController(store: settingsStore)
    private var onboardingWindowController: OnboardingWindowController?
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
        if !tiler.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWindow()
            }
        }
    }
    private func showOnboardingWindow() {
        let controller = onboardingWindowController ?? OnboardingWindowController(store: settingsStore)
        onboardingWindowController = controller
        controller.present()
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
        case .openSettings:
            openSettingsWindow()
            return
        case .decreaseGap:
            decreaseGap()
            return
        case .increaseGap:
            increaseGap()
            return
        case .resetGap:
            resetGap()
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
        let workspaceSwitchAnimationsEnabledBefore: Bool?
        let workspaceSwitchAnimationsIndicatorDisplayID: CGDirectDisplayID?
        if case .toggleTiling = action {
            tilingEnabledBefore = tiler.tilingEnabled
            tilingIndicatorDisplayID = tiler.currentDisplayID
            workspaceSwitchAnimationsEnabledBefore = nil
            workspaceSwitchAnimationsIndicatorDisplayID = nil
        } else if case .toggleWorkspaceSwitchAnimations = action {
            workspaceSwitchAnimationsEnabledBefore = tiler.workspaceSwitchAnimationsEnabled
            workspaceSwitchAnimationsIndicatorDisplayID = tiler.currentDisplayID
            tilingEnabledBefore = nil
            tilingIndicatorDisplayID = nil
        } else {
            tilingEnabledBefore = nil
            tilingIndicatorDisplayID = nil
            workspaceSwitchAnimationsEnabledBefore = nil
            workspaceSwitchAnimationsIndicatorDisplayID = nil
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
        if let workspaceSwitchAnimationsEnabledBefore,
           tiler.workspaceSwitchAnimationsEnabled != workspaceSwitchAnimationsEnabledBefore {
            showWorkspaceSwitchAnimationsStateIndicator(displayID: workspaceSwitchAnimationsIndicatorDisplayID)
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
        if let glyph = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "MacPane") {
            let configured = glyph.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            ) ?? glyph
            configured.isTemplate = true
            button.image = configured
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else if let icon = Bundle.main.image(forResource: "MacPaneIcon") {
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

        let workspaceMenuState = tiler.workspaceMenuState
        let statusItem = NSMenuItem(title: workspaceMenuState.statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if !tiler.hasAccessibilityPermission(prompt: false) {
            let permissionItem = NSMenuItem(
                title: "Accessibility access required",
                action: #selector(openSettingsFromMenu),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
        }
        menu.addItem(NSMenuItem.separator())

        let switchWorkspaceItem = NSMenuItem(title: "Switch Workspace", action: nil, keyEquivalent: "")
        let switchWorkspaceMenu = NSMenu()
        for index in 0..<workspaceMenuState.count {
            let item = NSMenuItem(
                title: "Workspace \(index + 1)",
                action: #selector(switchWorkspaceFromMenu),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = index
            item.state = workspaceMenuState.activeIndex == index ? .on : .off
            switchWorkspaceMenu.addItem(item)
        }
        switchWorkspaceItem.submenu = switchWorkspaceMenu
        menu.addItem(switchWorkspaceItem)

        let moveToWorkspaceItem = NSMenuItem(title: "Move Window To", action: nil, keyEquivalent: "")
        let moveToWorkspaceMenu = NSMenu()
        for index in 0..<workspaceMenuState.count {
            let item = NSMenuItem(
                title: "Workspace \(index + 1)",
                action: #selector(moveFocusedWindowToWorkspaceFromMenu),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = index
            moveToWorkspaceMenu.addItem(item)
        }
        moveToWorkspaceItem.submenu = moveToWorkspaceMenu
        menu.addItem(moveToWorkspaceItem)

        let overviewItem = NSMenuItem(
            title: "Show Overview",
            action: #selector(showWorkspaceOverviewFromMenu),
            keyEquivalent: ""
        )
        overviewItem.target = self
        menu.addItem(overviewItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command, .option]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit MacPane", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }
    private func openSettingsWindow() {
        settingsWindowController.present()
    }
    @objc private func switchWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        perform(action: .switchWorkspace(index), rebuildMenu: true)
    }
    @objc private func moveFocusedWindowToWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        perform(action: .moveWindowToWorkspace(index), rebuildMenu: true)
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
        workspaceSwitchIndicatorOverlay.show(
            workspaceNumber: indicator.workspaceIndex + 1,
            workspaceCount: tiler.workspaceCount,
            displayID: indicator.displayID
        )
    }
    private func showTilingStateIndicator(displayID: CGDirectDisplayID?) {
        workspaceSwitchIndicatorOverlay.show(text: tiler.tilingEnabled ? "On" : "Off", displayID: displayID)
    }
    private func showWorkspaceSwitchAnimationsStateIndicator(displayID: CGDirectDisplayID?) {
        workspaceSwitchIndicatorOverlay.show(
            text: tiler.workspaceSwitchAnimationsEnabled ? "On" : "Off",
            displayID: displayID
        )
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
