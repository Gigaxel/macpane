import Foundation

struct DepartedScreenLayout {
    let state: ScreenTileState
    let createdAt: Date
}

struct MissingWindowRetention {
    let retainedIDsByStateKey: [String: Set<WindowIdentity>]
    let missingSinceByID: [WindowIdentity: Date]
}

enum WindowStateSyncPlanner {
    static let departedLayoutExpiry: TimeInterval = 6 * 60 * 60

    static func missingWindowRetention(
        idsByScreen: [String: Set<WindowIdentity>],
        activeStateKeys: Set<String>,
        screenStates: [String: ScreenTileState],
        visibleIDs: Set<WindowIdentity>,
        missingSinceByID: [WindowIdentity: Date],
        confirmedRemovedIDs: Set<WindowIdentity>,
        isProcessRunning: (pid_t) -> Bool,
        grace: TimeInterval,
        now: Date
    ) -> MissingWindowRetention {
        var retainedIDsByStateKey: [String: Set<WindowIdentity>] = [:]
        var updatedMissingSince: [WindowIdentity: Date] = [:]
        for (key, state) in screenStates where activeStateKeys.contains(key) {
            let stateVisibleIDs = idsByScreen[key] ?? []
            for id in state.windowIDs.subtracting(stateVisibleIDs) {
                guard !visibleIDs.contains(id) else { continue }
                guard !confirmedRemovedIDs.contains(id), isProcessRunning(id.pid) else { continue }
                let missingSince = missingSinceByID[id] ?? now
                guard now.timeIntervalSince(missingSince) < grace else { continue }
                retainedIDsByStateKey[key, default: []].insert(id)
                updatedMissingSince[id] = missingSince
            }
        }
        return MissingWindowRetention(
            retainedIDsByStateKey: retainedIDsByStateKey,
            missingSinceByID: updatedMissingSince
        )
    }

    static func restoredDepartedLayout(
        memory: DepartedScreenLayout,
        visibleIDs: Set<WindowIdentity>,
        currentState: ScreenTileState?,
        now: Date = Date()
    ) -> ScreenTileState? {
        guard now.timeIntervalSince(memory.createdAt) <= departedLayoutExpiry else { return nil }
        let currentIDs = currentState?.windowIDs ?? []
        let returningIDs = memory.state.windowIDs.intersection(visibleIDs).subtracting(currentIDs)
        guard !returningIDs.isEmpty else { return nil }
        return memory.state
    }

    static func shouldRememberDepartedLayout(
        previousState: ScreenTileState,
        visibleIDs: Set<WindowIdentity>,
        existingMemory: DepartedScreenLayout?,
        now: Date = Date()
    ) -> Bool {
        let departingIDs = previousState.windowIDs.subtracting(visibleIDs)
        guard !departingIDs.isEmpty else { return false }
        if let existingMemory,
           now.timeIntervalSince(existingMemory.createdAt) <= departedLayoutExpiry,
           existingMemory.state.windowIDs.isSuperset(of: previousState.windowIDs) {
            return false
        }
        return true
    }

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
        floatingWindowIDs: Set<WindowIdentity>,
        departedWindowIDs: Set<WindowIdentity> = []
    ) -> Set<WindowIdentity> {
        var retainedIDs: Set<WindowIdentity> = []
        if let frozenSystemUIScreenStates {
            retainedIDs.formUnion(frozenSystemUIScreenStates.values.flatMap(\.windowIDs))
        }
        // Retain every tracked window ID, not just inactive workspaces. Active-workspace windows
        // can briefly fail `windowCandidate` checks during Mission Control / App Exposé animations,
        // and dropping their identity aliases here causes them to be re-discovered as fresh
        // identities under the wrong workspace on the next scan.
        let trackedStateIDs = screenStates.values.flatMap(\.windowIDs)
        retainedIDs.formUnion(trackedStateIDs)
        retainedIDs.formUnion(floatingWindowIDs)
        retainedIDs.formUnion(departedWindowIDs)
        return retainedIDs
    }
}
