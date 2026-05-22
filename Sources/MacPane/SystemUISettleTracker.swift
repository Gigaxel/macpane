import Foundation

struct SystemUISettleTracker {
    private var pausedUntil = Date.distantPast
    private var lastWindowSnapshot: SystemUIWindowSnapshot?
    private var stableSnapshotCount = 0
    private var settleBeganAt: Date?

    private let requiredStableSnapshotCount = 2
    private let missingFrozenWindowGrace: TimeInterval = 3.0

    var isPaused: Bool {
        Date() < pausedUntil
    }

    mutating func pause(for duration: TimeInterval, now: Date = Date()) {
        pausedUntil = max(pausedUntil, now.addingTimeInterval(duration))
    }

    mutating func resetSnapshotStability() {
        lastWindowSnapshot = nil
        stableSnapshotCount = 0
        settleBeganAt = nil
    }

    mutating func isSnapshotStable(
        _ windows: [ManagedWindow],
        frozenStates: [String: ScreenTileState]?,
        activeStateKeys: Set<String>?,
        layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity],
        now: Date = Date()
    ) -> Bool {
        if settleBeganAt == nil {
            settleBeganAt = now
        }
        if shouldKeepWaitingForFrozenWindows(
            toReappearIn: windows,
            frozenStates: frozenStates,
            activeStateKeys: activeStateKeys,
            layoutIdentityByWindowID: layoutIdentityByWindowID,
            now: now
        ) {
            lastWindowSnapshot = nil
            stableSnapshotCount = 0
            return false
        }

        let snapshot = SystemUIWindowSnapshot(windows: windows)
        if snapshot == lastWindowSnapshot {
            stableSnapshotCount += 1
        } else {
            lastWindowSnapshot = snapshot
            stableSnapshotCount = 1
        }
        return stableSnapshotCount >= requiredStableSnapshotCount
    }

    private func shouldKeepWaitingForFrozenWindows(
        toReappearIn windows: [ManagedWindow],
        frozenStates: [String: ScreenTileState]?,
        activeStateKeys: Set<String>?,
        layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity],
        now: Date
    ) -> Bool {
        guard let frozenStates,
              let settleBeganAt,
              now.timeIntervalSince(settleBeganAt) < missingFrozenWindowGrace else {
            return false
        }

        let statesToWaitFor: [ScreenTileState]
        if let activeStateKeys {
            statesToWaitFor = frozenStates.compactMap { key, state in
                activeStateKeys.contains(key) ? state : nil
            }
        } else {
            statesToWaitFor = Array(frozenStates.values)
        }

        let frozenIDs = Set(statesToWaitFor.flatMap(\.windowIDs))
        guard !frozenIDs.isEmpty else { return false }
        let liveIDs = Set(windows.map(\.id))
        guard !frozenIDs.isSubset(of: liveIDs) else { return false }

        let missingIDs = frozenIDs.subtracting(liveIDs)
        let appearedWindows = windows.filter { !frozenIDs.contains($0.id) }
        let matchedMissingIDs = Set(WindowLayoutIdentityMatcher.replacements(
            stored: LayoutRestorePlanner.layoutIdentityItems(
                forStoredIDs: missingIDs,
                identitiesByWindowID: layoutIdentityByWindowID
            ),
            visible: LayoutRestorePlanner.layoutIdentityItems(forWindows: appearedWindows)
        ).keys)
        return !missingIDs.subtracting(matchedMissingIDs).isEmpty
    }
}
