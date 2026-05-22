import AppKit
import ApplicationServices

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
