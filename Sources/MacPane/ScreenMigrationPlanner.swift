enum ScreenMigrationPlanner {
    static func orphanedNativeStateKeys(
        currentNativeStateKeys: Set<String>,
        screenStates: [String: ScreenTileState],
        persistedLayoutsByStateKey: [String: PersistedScreenLayout],
        floatingWindowStateKeys: [WindowIdentity: String],
        disconnectedNativeStateKeys: Set<String>,
        hasWorkspaceMetadata: (String) -> Bool
    ) -> Set<String> {
        var keys: Set<String> = []
        for stateKey in screenStates.keys {
            insertIfOrphaned(
                WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey),
                currentNativeStateKeys: currentNativeStateKeys,
                into: &keys
            )
        }
        for snapshot in persistedLayoutsByStateKey.values {
            insertIfOrphaned(
                WorkspaceStateKeys.nativeStateKeyComponent(of: snapshot.stateKey),
                currentNativeStateKeys: currentNativeStateKeys,
                into: &keys
            )
        }
        for stateKey in floatingWindowStateKeys.values {
            insertIfOrphaned(
                WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey),
                currentNativeStateKeys: currentNativeStateKeys,
                into: &keys
            )
        }
        for nativeStateKey in disconnectedNativeStateKeys
            where !currentNativeStateKeys.contains(nativeStateKey) && hasWorkspaceMetadata(nativeStateKey) {
            keys.insert(nativeStateKey)
        }
        return keys
    }

    static func targetNativeStateKeyForOrphanedDisplay(
        sourceNativeStateKey: String,
        currentScreens: [ScreenInfo],
        windows: [ManagedWindow]?,
        sourceWindowIDs: Set<WindowIdentity>,
        screenForFrame: (ManagedWindow, [ScreenInfo]) -> ScreenInfo,
        fallbackNativeStateKeys: [String]
    ) -> String? {
        if currentScreens.count == 1 {
            return currentScreens.first?.nativeStateKey
        }

        if !sourceWindowIDs.isEmpty, let windows {
            let countsByNativeStateKey = windows.reduce(into: [String: Int]()) { counts, window in
                guard sourceWindowIDs.contains(window.id) else { return }
                let physicalScreen = screenForFrame(window, currentScreens)
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

        let currentNativeStateKeys = Set(currentScreens.map(\.nativeStateKey))
        if let fallback = fallbackNativeStateKeys.first(where: { currentNativeStateKeys.contains($0) }) {
            return fallback
        }
        return currentScreens.first?.nativeStateKey
    }

    static func windowIDs(
        inNativeStateKey nativeStateKey: String,
        screenStates: [String: ScreenTileState],
        floatingWindowStateKeys: [WindowIdentity: String]
    ) -> Set<WindowIdentity> {
        var ids = Set(screenStates
            .filter { key, _ in WorkspaceStateKeys.nativeStateKeyComponent(of: key) == nativeStateKey }
            .values
            .flatMap(\.windowIDs))
        ids.formUnion(floatingWindowStateKeys.compactMap { id, stateKey in
            WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey) == nativeStateKey ? id : nil
        })
        return ids
    }

    private static func insertIfOrphaned(
        _ nativeStateKey: String,
        currentNativeStateKeys: Set<String>,
        into keys: inout Set<String>
    ) {
        if !currentNativeStateKeys.contains(nativeStateKey) {
            keys.insert(nativeStateKey)
        }
    }
}
