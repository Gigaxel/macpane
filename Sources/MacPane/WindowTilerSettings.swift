import Foundation

final class WindowTilerSettings {
    private enum DefaultsKey {
        static let gapPixels = "gapPixels"
        static let workspaceCount = "virtualWorkspaceCount"
        static let tilingEnabled = "tilingEnabled"
        static let workspaceSwitchAnimationsEnabled = "workspaceSwitchAnimationsEnabled"
        static let workspaceNamesByDisplay = "workspaceNamesByDisplay"
        static let accessibilityPrompted = "accessibilityPrompted"
    }

    private let defaults: UserDefaults
    private let defaultGap = 8
    private let defaultWorkspaceCount = 4

    let maximumGap = 48
    let maximumWorkspaceCount = 9

    private var activeWorkspaceIndexByNativeStateKey: [String: Int] = [:]
    private var activeWorkspaceIndexByDisplayKey: [String: Int] = [:]

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

    var hasPromptedForAccessibilityPermission: Bool {
        defaults.bool(forKey: DefaultsKey.accessibilityPrompted)
    }

    func markAccessibilityPrompted() {
        defaults.set(true, forKey: DefaultsKey.accessibilityPrompted)
    }

    func resetRuntimeState() {
        activeWorkspaceIndexByNativeStateKey.removeAll()
        activeWorkspaceIndexByDisplayKey.removeAll()
    }

    func availableWorkspaceIndex(_ index: Int) -> Int? {
        guard index >= 0, index < workspaceCount else { return nil }
        return index
    }

    func wrappedWorkspaceIndex(_ index: Int) -> Int {
        let count = max(1, workspaceCount)
        return ((index % count) + count) % count
    }

    func shiftedActiveWorkspaceIndex(
        _ activeIndex: Int,
        deletingWorkspaceIndex index: Int,
        newWorkspaceCount: Int
    ) -> Int {
        let shifted = activeIndex > index ? activeIndex - 1 : min(activeIndex, newWorkspaceCount - 1)
        return min(max(shifted, 0), max(newWorkspaceCount - 1, 0))
    }

    func shiftActiveWorkspaceIndices(deletingWorkspaceIndex index: Int, newWorkspaceCount: Int) {
        activeWorkspaceIndexByNativeStateKey = activeWorkspaceIndexByNativeStateKey.mapValues {
            shiftedActiveWorkspaceIndex($0, deletingWorkspaceIndex: index, newWorkspaceCount: newWorkspaceCount)
        }
        activeWorkspaceIndexByDisplayKey = activeWorkspaceIndexByDisplayKey.mapValues {
            shiftedActiveWorkspaceIndex($0, deletingWorkspaceIndex: index, newWorkspaceCount: newWorkspaceCount)
        }
    }

    func activeWorkspaceIndex(forNativeStateKey nativeStateKey: String) -> Int {
        let displayKey = displayKeyComponent(of: nativeStateKey)
        let fallbackIndex = activeWorkspaceIndexByDisplayKey[displayKey]
            ?? activeWorkspaceIndexByNativeStateKey.first { displayKeyComponent(of: $0.key) == displayKey }?.value
            ?? 0
        let index = clampedWorkspaceIndex(activeWorkspaceIndexByNativeStateKey[nativeStateKey] ?? fallbackIndex)
        activeWorkspaceIndexByNativeStateKey[nativeStateKey] = index
        activeWorkspaceIndexByDisplayKey[displayKey] = index
        return index
    }

    func storedActiveWorkspaceIndex(forNativeStateKey nativeStateKey: String) -> Int? {
        let displayKey = displayKeyComponent(of: nativeStateKey)
        let index = activeWorkspaceIndexByNativeStateKey[nativeStateKey]
            ?? activeWorkspaceIndexByDisplayKey[displayKey]
        return index.map(clampedWorkspaceIndex)
    }

    func setActiveWorkspaceIndex(_ index: Int, forNativeStateKey nativeStateKey: String) {
        let index = clampedWorkspaceIndex(index)
        activeWorkspaceIndexByNativeStateKey[nativeStateKey] = index
        activeWorkspaceIndexByDisplayKey[displayKeyComponent(of: nativeStateKey)] = index
    }

    func hasWorkspaceMetadata(forNativeStateKey nativeStateKey: String) -> Bool {
        if activeWorkspaceIndexByNativeStateKey[nativeStateKey] != nil {
            return true
        }
        let displayKey = displayKeyComponent(of: nativeStateKey)
        if activeWorkspaceIndexByDisplayKey[displayKey] != nil {
            return true
        }
        return workspaceNames().keys.contains { nameKey in
            workspaceNameDisplayKey(from: nameKey) == displayKey
        }
    }

    func workspaceName(forNativeStateKey nativeStateKey: String, workspaceIndex: Int) -> String? {
        workspaceNames()[workspaceNameKey(forNativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)]
    }

    func setWorkspaceName(_ name: String, forNativeStateKey nativeStateKey: String, workspaceIndex: Int) {
        var names = workspaceNames()
        let key = workspaceNameKey(forNativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty {
            names.removeValue(forKey: key)
        } else {
            names[key] = String(normalizedName.prefix(48))
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

    func migrateWorkspaceNames(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String
    ) -> Bool {
        var names = workspaceNames()
        var migrated = false
        for index in 0..<workspaceCount {
            let sourceKey = workspaceNameKey(forNativeStateKey: sourceNativeStateKey, workspaceIndex: index)
            let targetKey = workspaceNameKey(forNativeStateKey: targetNativeStateKey, workspaceIndex: index)
            guard sourceKey != targetKey, let name = names[sourceKey], names[targetKey] == nil else { continue }
            names[targetKey] = name
            names.removeValue(forKey: sourceKey)
            migrated = true
        }
        if migrated {
            defaults.set(names, forKey: DefaultsKey.workspaceNamesByDisplay)
        }
        return migrated
    }

    func migrateActiveWorkspaceIndex(
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

    private func clampedWorkspaceIndex(_ index: Int) -> Int {
        min(max(index, 0), workspaceCount - 1)
    }

    private func workspaceNames() -> [String: String] {
        defaults.dictionary(forKey: DefaultsKey.workspaceNamesByDisplay) as? [String: String] ?? [:]
    }

    private func workspaceNameKey(forNativeStateKey nativeStateKey: String, workspaceIndex: Int) -> String {
        "\(displayKeyComponent(of: nativeStateKey)):\(workspaceIndex)"
    }

    private func workspaceNameDisplayKey(from nameKey: String) -> String? {
        guard let separator = nameKey.lastIndex(of: ":") else { return nil }
        return String(nameKey[..<separator])
    }

    private func displayKeyComponent(of stateKey: String) -> String {
        nativeStateKeyComponent(of: stateKey)
    }

    private func nativeStateKeyComponent(of stateKey: String) -> String {
        guard let range = stateKey.range(of: ScreenInfo.workspaceStateSeparator) else { return stateKey }
        return String(stateKey[..<range.lowerBound])
    }
}
