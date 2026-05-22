enum HotKeyStateKeyResolution {
    case existing(String)
    case initialize(key: String, windowIDs: [WindowIdentity])
}

enum HotKeyStateSyncAction {
    case unavailable
    case preserveExistingFocus
    case sync(windowIDs: [WindowIdentity], focusedID: WindowIdentity?)
    case markFocused
}

enum HotKeyStatePlanner {
    static func hasLikelyPartialSnapshot(
        windows: [ManagedWindow],
        activeStateKeys: Set<String>,
        screenStates: [String: ScreenTileState]
    ) -> Bool {
        activeStateKeys.contains { key in
            hasLikelyPartialSnapshot(forStateKey: key, windows: windows, screenStates: screenStates)
        }
    }

    static func hasLikelyPartialSnapshot(
        forStateKey key: String,
        windows: [ManagedWindow],
        screenStates: [String: ScreenTileState]
    ) -> Bool {
        guard let state = screenStates[key], !state.isEmpty else { return false }
        let observedCount = windows.reduce(into: 0) { count, window in
            if window.screen.stateKey == key {
                count += 1
            }
        }
        return observedCount < state.windowIDs.count
    }

    static func resolveStateKey(
        for focusedID: WindowIdentity,
        knownStateKey: String?,
        windows: [ManagedWindow],
        screenStates: [String: ScreenTileState],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> HotKeyStateKeyResolution? {
        if let knownStateKey, screenStates[knownStateKey] != nil {
            return .existing(knownStateKey)
        }
        guard let focusedWindow = windows.first(where: { $0.id == focusedID }) else { return nil }
        let candidateKey = focusedWindow.screen.stateKey
        if screenStates[candidateKey] != nil {
            return .existing(candidateKey)
        }
        if hasLikelyPartialSnapshot(forStateKey: candidateKey, windows: windows, screenStates: screenStates) {
            return nil
        }
        let candidateIDs = windowIDs(in: windows, stateKey: candidateKey, floatingWindowIDs: floatingWindowIDs)
        guard !candidateIDs.isEmpty else { return nil }
        return .initialize(key: candidateKey, windowIDs: candidateIDs)
    }

    static func syncAction(
        currentState state: ScreenTileState?,
        focusedID: WindowIdentity,
        windows: [ManagedWindow],
        stateKey: String,
        floatingWindowIDs: Set<WindowIdentity>
    ) -> HotKeyStateSyncAction {
        guard let state else { return .unavailable }
        let candidateIDs = windowIDs(in: windows, stateKey: stateKey, floatingWindowIDs: floatingWindowIDs)
        guard !candidateIDs.isEmpty else { return .unavailable }

        let candidateSet = Set(candidateIDs)
        if candidateSet.count < state.windowIDs.count {
            // Hotkey paths can observe transiently incomplete AX snapshots during rapid resizes.
            // Avoid shrinking the tree in that case; a scheduled reconcile will heal once stable.
            return state.contains(focusedID) ? .preserveExistingFocus : .unavailable
        }
        if state.windowIDs != candidateSet {
            return .sync(
                windowIDs: candidateIDs,
                focusedID: candidateSet.contains(focusedID) ? focusedID : nil
            )
        }
        return candidateSet.contains(focusedID) ? .markFocused : .unavailable
    }

    static func windowIDs(
        in windows: [ManagedWindow],
        stateKey: String,
        floatingWindowIDs: Set<WindowIdentity>
    ) -> [WindowIdentity] {
        windows
            .filter { $0.screen.stateKey == stateKey && !floatingWindowIDs.contains($0.id) }
            .map(\.id)
    }
}
