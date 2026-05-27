import AppKit
import Combine
import Foundation
import SwiftUI

final class SettingsStore: ObservableObject {
    let gapRange: ClosedRange<Int> = 0...48
    let workspaceCountRange: ClosedRange<Int> = 1...9
    private let tiler: WindowTiler

    init(tiler: WindowTiler) {
        self.tiler = tiler
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDefaultsChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleDefaultsChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var gapPixels: Int { tiler.gapPixels }
    var tilingEnabled: Bool { tiler.tilingEnabled }
    var workspaceSwitchAnimationsEnabled: Bool { tiler.workspaceSwitchAnimationsEnabled }
    var workspaceCount: Int { tiler.workspaceCount }
    var canCreateWorkspace: Bool { tiler.workspaceMenuState.canCreateMore }
    var canDeleteCurrentWorkspace: Bool { tiler.workspaceMenuState.canDeleteActive }
    var accessibilityEnabled: Bool { tiler.hasAccessibilityPermission(prompt: false) }

    func setGap(_ value: Int) {
        objectWillChange.send()
        tiler.setGap(value)
    }

    func setTilingEnabled(_ value: Bool) {
        objectWillChange.send()
        tiler.setTilingEnabled(value)
    }

    func setWorkspaceSwitchAnimationsEnabled(_ value: Bool) {
        objectWillChange.send()
        tiler.setWorkspaceSwitchAnimationsEnabled(value)
    }

    func createWorkspace() {
        objectWillChange.send()
        tiler.handle(action: .createWorkspace)
    }

    func deleteCurrentWorkspace() {
        objectWillChange.send()
        tiler.handle(action: .deleteWorkspace)
    }

    func retileNow() {
        tiler.retileNow()
    }

    func refreshAccessibilityStatus() {
        objectWillChange.send()
    }

    var hasCompletedOnboarding: Bool { tiler.hasCompletedOnboarding }

    func markOnboardingCompleted() {
        tiler.markOnboardingCompleted()
        objectWillChange.send()
    }

    func openAccessibilitySettings() {
        _ = tiler.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        objectWillChange.send()
    }

    var bindingStore: HotKeyBindingStore { HotKeyManager.shared.bindingStore }

    func entry(forIdentifier identifier: String) -> HotKeyBindingEntry? {
        HotKeyBindingDefaults.entries.first { $0.identifier == identifier }
    }

    func effectiveBinding(forIdentifier identifier: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let match = bindingStore.effectiveBindings()
            .first(where: { $0.entry.identifier == identifier }) else { return nil }
        return (match.keyCode, match.modifiers)
    }

    func displayString(forIdentifier identifier: String) -> String {
        guard let entry = entry(forIdentifier: identifier),
              let binding = effectiveBinding(forIdentifier: identifier) else { return "—" }
        switch entry.scope {
        case .directionTemplate:
            return HotKeyGlyphs.modifierSymbols(for: binding.modifiers) + " + ◀ ▶ ▲ ▼ / HJKL"
        case .atomic, .fixed:
            return HotKeyGlyphs.displayString(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
    }

    func isOverridden(identifier: String) -> Bool {
        bindingStore.override(forIdentifier: identifier) != nil
    }

    func setShortcut(identifier: String, keyCode: UInt32, modifiers: UInt32) -> String? {
        let result = bindingStore.setOverride(forIdentifier: identifier, keyCode: keyCode, modifiers: modifiers)
        switch result {
        case .success:
            HotKeyManager.shared.reregisterMainHotKeys()
            objectWillChange.send()
            return nil
        case .failure(.conflict(let existing)):
            return "Already bound to \(humanLabel(for: existing))"
        case .failure(.notRebindable):
            return "This shortcut isn't rebindable."
        case .failure(.invalidModifiers):
            return "Add ⌘, ⌥, or ⌃. Shift alone can't be a global shortcut."
        }
    }

    func resetShortcut(identifier: String) {
        bindingStore.resetOverride(forIdentifier: identifier)
        HotKeyManager.shared.reregisterMainHotKeys()
        objectWillChange.send()
    }

    func resetAllShortcuts() {
        bindingStore.resetAll()
        HotKeyManager.shared.reregisterMainHotKeys()
        objectWillChange.send()
    }

    private func humanLabel(for identifier: String) -> String {
        if let workspaceNumber = workspaceNumber(for: identifier, prefix: "switchWorkspace.") {
            return "Switch to workspace \(workspaceNumber)"
        }
        if let workspaceNumber = workspaceNumber(for: identifier, prefix: "moveWindowToWorkspace.alt.") {
            return "Move window to workspace \(workspaceNumber)"
        }
        if let workspaceNumber = workspaceNumber(for: identifier, prefix: "moveWindowToWorkspace.") {
            return "Move window to workspace \(workspaceNumber)"
        }
        switch identifier {
        case "focus": return "Focus neighbor"
        case "swap": return "Swap with neighbor"
        case "resize": return "Resize focused split"
        case "cycleWorkspace.prev": return "Previous workspace"
        case "cycleWorkspace.next": return "Next workspace"
        case "cycleWorkspace.prev.vim": return "Previous workspace (Vim)"
        case "cycleWorkspace.next.vim": return "Next workspace (Vim)"
        case "createWorkspace": return "Create workspace"
        case "deleteWorkspace": return "Delete workspace"
        case "showWorkspaceOverview": return "Show workspace overview"
        case "toggleOrientation": return "Rotate split"
        case "toggleFloating": return "Toggle floating"
        case "toggleTiling": return "Toggle tiling"
        case "toggleWorkspaceSwitchAnimations": return "Toggle workspace animations"
        case "balance": return "Balance BSP tree"
        case "retile": return "Retile now"
        case "openSettings": return "Open settings"
        case "decreaseGap": return "Decrease gap"
        case "increaseGap": return "Increase gap"
        case "resetGap": return "Reset gap"
        default: return identifier
        }
    }

    private func workspaceNumber(for identifier: String, prefix: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let rawIndex = identifier.replacingOccurrences(of: prefix, with: "")
        guard let zeroBasedIndex = Int(rawIndex) else { return rawIndex }
        return String(zeroBasedIndex + 1)
    }
}
