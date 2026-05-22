enum WindowStateSyncPlanner {
    static func hasWindowSetChanged(
        windows: [ManagedWindow],
        activeStateKeys: Set<String>,
        screenStates: [String: ScreenTileState]
    ) -> Bool {
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

    static func retainedOffscreenWindowIDs(
        activeStateKeys: Set<String>,
        frozenSystemUIScreenStates: [String: ScreenTileState]?,
        screenStates: [String: ScreenTileState],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> Set<WindowIdentity> {
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
}
