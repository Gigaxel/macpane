import Foundation

enum WorkspaceStatePlanner {
    static func deletionAvailability(
        index: Int,
        workspaceCount: Int,
        screenStates: [String: ScreenTileState],
        floatingWindowStateKeys: [WindowIdentity: String]
    ) -> (canDelete: Bool, reason: String?) {
        guard workspaceCount > 1 else {
            return (false, "Only Workspace")
        }
        guard index >= 0, index < workspaceCount else {
            return (false, "Unavailable")
        }
        guard workspaceIsEmpty(
            index: index,
            screenStates: screenStates,
            floatingWindowStateKeys: floatingWindowStateKeys
        ) else {
            return (false, "Not Empty")
        }
        return (true, nil)
    }

    static func shiftedScreenStates(
        _ screenStates: [String: ScreenTileState],
        deletingWorkspaceIndex index: Int
    ) -> [String: ScreenTileState] {
        var shifted: [String: ScreenTileState] = [:]
        for (stateKey, state) in screenStates where !state.isEmpty {
            guard let shiftedKey = shiftedWorkspaceStateKey(stateKey, deletingWorkspaceIndex: index) else {
                continue
            }
            shifted[shiftedKey] = state
        }
        return shifted
    }

    static func shiftedPersistedLayouts(
        _ persistedLayoutsByStateKey: [String: PersistedScreenLayout],
        deletingWorkspaceIndex index: Int
    ) -> [String: PersistedScreenLayout] {
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

    static func shiftedFloatingWindowStateKeys(
        _ floatingWindowStateKeys: [WindowIdentity: String],
        deletingWorkspaceIndex index: Int
    ) -> [WindowIdentity: String] {
        floatingWindowStateKeys.compactMapValues {
            shiftedWorkspaceStateKey($0, deletingWorkspaceIndex: index)
        }
    }

    private static func workspaceIsEmpty(
        index: Int,
        screenStates: [String: ScreenTileState],
        floatingWindowStateKeys: [WindowIdentity: String]
    ) -> Bool {
        let hasTiledWindows = screenStates.contains { key, state in
            ScreenInfo.workspaceIndex(from: key) == index && !state.isEmpty
        }
        let hasFloatingWindows = floatingWindowStateKeys.values.contains { stateKey in
            ScreenInfo.workspaceIndex(from: stateKey) == index
        }
        return !hasTiledWindows && !hasFloatingWindows
    }

    private static func shiftedWorkspaceStateKey(_ stateKey: String, deletingWorkspaceIndex index: Int) -> String? {
        guard let workspaceIndex = ScreenInfo.workspaceIndex(from: stateKey) else { return stateKey }
        if workspaceIndex == index {
            return nil
        }
        guard workspaceIndex > index else { return stateKey }
        return ScreenInfo.workspaceStateKey(
            nativeStateKey: WorkspaceStateKeys.nativeStateKeyComponent(of: stateKey),
            workspaceIndex: workspaceIndex - 1
        )
    }

    private static func displayKeyComponent(of stateKey: String) -> String {
        WorkspaceStateKeys.displayKeyComponent(of: stateKey)
    }
}
