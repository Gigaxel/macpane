import CoreGraphics
import Foundation

final class WindowTilerSettings {
    private enum DefaultsKey {
        static let gapPixels = "gapPixels"
        static let workspaceCount = "virtualWorkspaceCount"
        static let tilingEnabled = "tilingEnabled"
        static let workspaceSwitchAnimationsEnabled = "workspaceSwitchAnimationsEnabled"
        static let workspaceNamesByDisplay = "workspaceNamesByDisplay"
        static let accessibilityPrompted = "accessibilityPrompted"
        static let onboardingCompleted = "onboardingCompleted"
        static let autoFloatSmallWindowsEnabled = "autoFloatSmallWindowsEnabled"
        static let fastFocusEnabled = "fastFocusEnabled"
        static let autoFloatWidthThreshold = "autoFloatWidthThreshold"
        static let autoFloatHeightThreshold = "autoFloatHeightThreshold"
    }

    private let defaults: UserDefaults
    static let autoFloatThresholdRange = 100...1200

    private static let defaultAutoFloatWidthThreshold = 500
    private static let defaultAutoFloatHeightThreshold = 400
    private let defaultGap = 8
    private let defaultWorkspaceCount = 4

    let maximumGap = 48
    let maximumWorkspaceCount = 9

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var gapPixels: Int {
        let stored = defaults.object(forKey: DefaultsKey.gapPixels) as? Int
        return min(max(stored ?? defaultGap, 0), maximumGap)
    }

    func setGap(_ value: Int) {
        defaults.set(min(max(value, 0), maximumGap), forKey: DefaultsKey.gapPixels)
    }

    var workspaceCount: Int {
        let stored = defaults.object(forKey: DefaultsKey.workspaceCount) as? Int
        return min(max(stored ?? defaultWorkspaceCount, 1), maximumWorkspaceCount)
    }

    func setWorkspaceCount(_ value: Int) {
        defaults.set(min(max(value, 1), maximumWorkspaceCount), forKey: DefaultsKey.workspaceCount)
    }

    var tilingEnabled: Bool {
        if defaults.object(forKey: DefaultsKey.tilingEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: DefaultsKey.tilingEnabled)
    }

    func toggleTiling() {
        defaults.set(!tilingEnabled, forKey: DefaultsKey.tilingEnabled)
    }

    var workspaceSwitchAnimationsEnabled: Bool {
        if defaults.object(forKey: DefaultsKey.workspaceSwitchAnimationsEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: DefaultsKey.workspaceSwitchAnimationsEnabled)
    }

    func toggleWorkspaceSwitchAnimations() {
        defaults.set(!workspaceSwitchAnimationsEnabled, forKey: DefaultsKey.workspaceSwitchAnimationsEnabled)
    }

    var autoFloatSmallWindowsEnabled: Bool {
        if defaults.object(forKey: DefaultsKey.autoFloatSmallWindowsEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: DefaultsKey.autoFloatSmallWindowsEnabled)
    }

    func setAutoFloatSmallWindowsEnabled(_ value: Bool) {
        defaults.set(value, forKey: DefaultsKey.autoFloatSmallWindowsEnabled)
    }

    var fastFocusEnabled: Bool {
        if defaults.object(forKey: DefaultsKey.fastFocusEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: DefaultsKey.fastFocusEnabled)
    }

    func setFastFocusEnabled(_ value: Bool) {
        defaults.set(value, forKey: DefaultsKey.fastFocusEnabled)
    }

    var autoFloatWidthThreshold: Int {
        clampedAutoFloatThreshold(
            defaults.object(forKey: DefaultsKey.autoFloatWidthThreshold) as? Int
                ?? Self.defaultAutoFloatWidthThreshold
        )
    }

    func setAutoFloatWidthThreshold(_ value: Int) {
        defaults.set(clampedAutoFloatThreshold(value), forKey: DefaultsKey.autoFloatWidthThreshold)
    }

    var autoFloatHeightThreshold: Int {
        clampedAutoFloatThreshold(
            defaults.object(forKey: DefaultsKey.autoFloatHeightThreshold) as? Int
                ?? Self.defaultAutoFloatHeightThreshold
        )
    }

    func setAutoFloatHeightThreshold(_ value: Int) {
        defaults.set(clampedAutoFloatThreshold(value), forKey: DefaultsKey.autoFloatHeightThreshold)
    }

    private func clampedAutoFloatThreshold(_ value: Int) -> Int {
        min(max(value, Self.autoFloatThresholdRange.lowerBound), Self.autoFloatThresholdRange.upperBound)
    }

    var hasPromptedForAccessibilityPermission: Bool {
        defaults.bool(forKey: DefaultsKey.accessibilityPrompted)
    }

    func markAccessibilityPrompted() {
        defaults.set(true, forKey: DefaultsKey.accessibilityPrompted)
    }

    var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: DefaultsKey.onboardingCompleted)
    }

    func markOnboardingCompleted() {
        defaults.set(true, forKey: DefaultsKey.onboardingCompleted)
    }

    func availableWorkspaceIndex(_ index: Int) -> Int? {
        guard index >= 0, index < workspaceCount else { return nil }
        return index
    }

    func wrappedWorkspaceIndex(_ index: Int) -> Int {
        let count = max(1, workspaceCount)
        return ((index % count) + count) % count
    }

    func workspaceName(on screen: ScreenInfo, index: Int) -> String? {
        let names = workspaceNames()
        return names[nameKey(display: screen.key, index: index)]
            ?? names[legacyNameKey(displayID: screen.displayID, index: index)]
    }

    func setWorkspaceName(_ name: String, on screen: ScreenInfo, index: Int) {
        var names = workspaceNames()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names.removeValue(forKey: legacyNameKey(displayID: screen.displayID, index: index))
        if normalizedName.isEmpty {
            names.removeValue(forKey: nameKey(display: screen.key, index: index))
        } else {
            names[nameKey(display: screen.key, index: index)] = String(normalizedName.prefix(48))
        }
        defaults.set(names, forKey: DefaultsKey.workspaceNamesByDisplay)
    }

    func shiftWorkspaceNames(deletingWorkspaceIndex deletingIndex: Int) {
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
        defaults.set(shiftedNames, forKey: DefaultsKey.workspaceNamesByDisplay)
    }

    private func workspaceNames() -> [String: String] {
        defaults.dictionary(forKey: DefaultsKey.workspaceNamesByDisplay) as? [String: String] ?? [:]
    }

    private func nameKey(display: String, index: Int) -> String {
        "\(display):\(index)"
    }

    /// Names saved before displays were identified by UUID.
    private func legacyNameKey(displayID: CGDirectDisplayID, index: Int) -> String {
        "display:\(displayID):\(index)"
    }
}
