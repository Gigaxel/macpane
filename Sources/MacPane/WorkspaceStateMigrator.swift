import Foundation

enum WorkspaceStateMigrator {
    static func mergeWorkspaceStates(
        inNativeStateKey nativeStateKey: String,
        into targetKey: String,
        focusedID: WindowIdentity?,
        screenStates: inout [String: ScreenTileState]
    ) -> Bool {
        let sourceKeys = screenStates.keys
            .filter { key in
                key != targetKey &&
                    WorkspaceStateKeys.nativeStateKeyComponent(of: key) == nativeStateKey
            }
            .sorted()
        var merged = false
        for sourceKey in sourceKeys {
            merged = migrateScreenState(
                from: sourceKey,
                to: targetKey,
                focusedID: focusedID,
                screenStates: &screenStates
            ) || merged
        }
        return merged
    }

    static func moveFloatingWindowStateKeys(
        inNativeStateKey nativeStateKey: String,
        to targetKey: String,
        floatingWindowStateKeys: inout [WindowIdentity: String]
    ) -> Bool {
        var moved = false
        for (id, stateKey) in floatingWindowStateKeys {
            guard stateKey != targetKey,
                  WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey) == nativeStateKey else {
                continue
            }
            floatingWindowStateKeys[id] = targetKey
            moved = true
        }
        return moved
    }

    static func hasAnyScreenState(
        inNativeStateKey nativeStateKey: String,
        screenStates: [String: ScreenTileState]
    ) -> Bool {
        screenStates.contains { stateKey, state in
            WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey) == nativeStateKey && !state.isEmpty
        }
    }

    static func migrateNativeWorkspaceStates(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        workspaceCount: Int,
        focusedID: WindowIdentity?,
        screenStates: inout [String: ScreenTileState],
        persistedLayoutsByStateKey: inout [String: PersistedScreenLayout],
        floatingWindowStateKeys: inout [WindowIdentity: String],
        focusedWorkspaceIndex: inout Int?
    ) -> Bool {
        guard sourceNativeStateKey != targetNativeStateKey else { return false }
        var migrated = false
        for index in 0..<workspaceCount {
            let sourceKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: sourceNativeStateKey,
                workspaceIndex: index
            )
            let targetKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: targetNativeStateKey,
                workspaceIndex: index
            )
            if let focusedID, screenStates[sourceKey]?.contains(focusedID) == true {
                focusedWorkspaceIndex = index
            }
            migrated = migrateScreenState(
                from: sourceKey,
                to: targetKey,
                focusedID: focusedID,
                screenStates: &screenStates
            ) || migrated
            migrated = migratePersistedLayout(
                from: sourceKey,
                to: targetKey,
                persistedLayoutsByStateKey: &persistedLayoutsByStateKey
            ) || migrated
        }
        migrated = migrateFloatingWindowStateKeys(
            fromNativeStateKey: sourceNativeStateKey,
            toNativeStateKey: targetNativeStateKey,
            workspaceCount: workspaceCount,
            floatingWindowStateKeys: &floatingWindowStateKeys,
            focusedWorkspaceIndex: &focusedWorkspaceIndex,
            focusedID: focusedID
        ) || migrated
        return migrated
    }

    static func migrateStates(
        toNativeStateKey targetNativeStateKey: String,
        workspaceCount: Int,
        screenStates: inout [String: ScreenTileState],
        persistedLayoutsByStateKey: inout [String: PersistedScreenLayout],
        floatingWindowStateKeys: inout [WindowIdentity: String]
    ) -> Bool {
        var migrated = false
        for index in 0..<workspaceCount {
            let targetKey = ScreenInfo.workspaceStateKey(
                nativeStateKey: targetNativeStateKey,
                workspaceIndex: index
            )
            migrated = migrateScreenState(to: targetKey, screenStates: &screenStates) || migrated
            migrated = migratePersistedLayout(
                to: targetKey,
                persistedLayoutsByStateKey: &persistedLayoutsByStateKey
            ) || migrated
        }
        migrated = migrateFloatingWindowStateKeys(
            toNativeStateKey: targetNativeStateKey,
            workspaceCount: workspaceCount,
            floatingWindowStateKeys: &floatingWindowStateKeys
        ) || migrated
        return migrated
    }

    private static func migrateScreenState(
        from sourceKey: String,
        to targetKey: String,
        focusedID: WindowIdentity?,
        screenStates: inout [String: ScreenTileState]
    ) -> Bool {
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

    private static func migratePersistedLayout(
        from sourceKey: String,
        to targetKey: String,
        persistedLayoutsByStateKey: inout [String: PersistedScreenLayout]
    ) -> Bool {
        guard let sourceSnapshot = persistedLayoutsByStateKey.removeValue(forKey: sourceKey) else { return false }
        if let targetSnapshot = persistedLayoutsByStateKey[targetKey] {
            persistedLayoutsByStateKey[targetKey] = LayoutRestorePlanner.mergedPersistedLayout(
                targetSnapshot,
                with: sourceSnapshot,
                targetKey: targetKey,
                displayKey: WorkspaceStateKeys.displayKeyComponent(of: targetKey)
            )
        } else {
            persistedLayoutsByStateKey[targetKey] = PersistedScreenLayout(
                stateKey: targetKey,
                displayKey: WorkspaceStateKeys.displayKeyComponent(of: targetKey),
                tree: sourceSnapshot.tree,
                entriesByID: sourceSnapshot.entriesByID,
                lastFocusedEntryID: sourceSnapshot.lastFocusedEntryID,
                lastUpdated: sourceSnapshot.lastUpdated
            )
        }
        return true
    }

    private static func migrateFloatingWindowStateKeys(
        fromNativeStateKey sourceNativeStateKey: String,
        toNativeStateKey targetNativeStateKey: String,
        workspaceCount: Int,
        floatingWindowStateKeys: inout [WindowIdentity: String],
        focusedWorkspaceIndex: inout Int?,
        focusedID: WindowIdentity?
    ) -> Bool {
        var migrated = false
        for (id, sourceKey) in floatingWindowStateKeys {
            guard WorkspaceStateKeys.nativeStateKeyComponent(of: sourceKey) == sourceNativeStateKey,
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

    private static func migrateScreenState(
        to targetKey: String,
        screenStates: inout [String: ScreenTileState]
    ) -> Bool {
        guard screenStates[targetKey] == nil else { return false }
        let candidates = screenStates.filter { sourceKey, state in
            sourceKey != targetKey &&
                WorkspaceStateKeys.canMigrateState(from: sourceKey, to: targetKey) &&
                !state.isEmpty
        }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        screenStates[targetKey] = candidate.value
        screenStates.removeValue(forKey: candidate.key)
        return true
    }

    private static func migratePersistedLayout(
        to targetKey: String,
        persistedLayoutsByStateKey: inout [String: PersistedScreenLayout]
    ) -> Bool {
        guard persistedLayoutsByStateKey[targetKey] == nil else { return false }
        let candidates = persistedLayoutsByStateKey.values
            .filter {
                $0.stateKey != targetKey &&
                    WorkspaceStateKeys.canMigrateState(from: $0.stateKey, to: targetKey)
            }
            .sorted { lhs, rhs in
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                return lhs.stateKey < rhs.stateKey
            }
        guard let snapshot = candidates.first else { return false }
        persistedLayoutsByStateKey.removeValue(forKey: snapshot.stateKey)
        persistedLayoutsByStateKey[targetKey] = PersistedScreenLayout(
            stateKey: targetKey,
            displayKey: WorkspaceStateKeys.displayKeyComponent(of: targetKey),
            tree: snapshot.tree,
            entriesByID: snapshot.entriesByID,
            lastFocusedEntryID: snapshot.lastFocusedEntryID,
            lastUpdated: snapshot.lastUpdated
        )
        return true
    }

    private static func migrateFloatingWindowStateKeys(
        toNativeStateKey targetNativeStateKey: String,
        workspaceCount: Int,
        floatingWindowStateKeys: inout [WindowIdentity: String]
    ) -> Bool {
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
            guard sourceKey != targetKey, WorkspaceStateKeys.canMigrateState(from: sourceKey, to: targetKey) else {
                continue
            }
            floatingWindowStateKeys[id] = targetKey
            migrated = true
        }
        return migrated
    }
}
