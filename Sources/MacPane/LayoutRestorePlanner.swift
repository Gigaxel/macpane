import CoreGraphics
import Foundation

enum LayoutRestorePlanner {
    private static let maximumFrameScore: CGFloat = 48

    static func mergedPersistedLayout(
        _ target: PersistedScreenLayout,
        with source: PersistedScreenLayout,
        targetKey: String,
        displayKey: String
    ) -> PersistedScreenLayout {
        var tree = target.tree
        var entriesByID = target.entriesByID
        var nextEntryID = (entriesByID.keys.max() ?? 0) + 1
        var sourceEntryIDReplacements: [Int: Int] = [:]

        for sourceEntryID in source.tree.ids {
            guard let sourceEntry = source.entriesByID[sourceEntryID] else { continue }
            let replacementEntryID = nextEntryID
            nextEntryID += 1
            sourceEntryIDReplacements[sourceEntryID] = replacementEntryID
            entriesByID[replacementEntryID] = PersistedWindowLayoutEntry(
                id: replacementEntryID,
                pid: sourceEntry.pid,
                bundleIdentifier: sourceEntry.bundleIdentifier,
                layoutIdentity: sourceEntry.layoutIdentity,
                orderRank: sourceEntry.orderRank,
                scanIndex: sourceEntry.scanIndex
            )
        }

        if tree.isEmpty,
           let sourceTree = source.tree.compactMapIDs({ sourceEntryIDReplacements[$0] }) {
            tree = sourceTree
        } else {
            var insertionTarget = target.lastFocusedEntryID ?? tree.largestLeafID() ?? tree.firstID
            for sourceEntryID in source.tree.ids {
                guard let replacementEntryID = sourceEntryIDReplacements[sourceEntryID] else { continue }
                tree.insert(replacementEntryID, near: insertionTarget, placement: .automatic)
                insertionTarget = replacementEntryID
            }
        }

        let sourceFocusedEntryID = source.lastFocusedEntryID.flatMap { sourceEntryIDReplacements[$0] }
        return PersistedScreenLayout(
            stateKey: targetKey,
            displayKey: displayKey,
            tree: tree,
            entriesByID: entriesByID,
            lastFocusedEntryID: target.lastFocusedEntryID ?? sourceFocusedEntryID,
            lastUpdated: max(target.lastUpdated, source.lastUpdated)
        )
    }

    static func storedStateKeyForLayoutRestore(
        currentKey: String,
        windows: [ManagedWindow],
        states: [String: ScreenTileState],
        layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity],
        canMigrateState: (String, String) -> Bool
    ) -> String? {
        if states[currentKey] != nil { return currentKey }
        let currentLayoutIdentities = layoutIdentityItems(forWindows: windows)
        guard !currentLayoutIdentities.isEmpty else { return nil }

        var bestMatch: (key: String, count: Int)?
        var hasAmbiguousBestMatch = false
        for (storedKey, state) in states where canMigrateState(storedKey, currentKey) {
            let storedLayoutIdentities = layoutIdentityItems(
                forStoredIDs: state.windowIDs,
                identitiesByWindowID: layoutIdentityByWindowID
            )
            let expectedMatches = min(storedLayoutIdentities.count, currentLayoutIdentities.count)
            guard expectedMatches > 0 else { continue }
            let matches = WindowLayoutIdentityMatcher.replacements(
                stored: storedLayoutIdentities,
                visible: currentLayoutIdentities
            ).count
            guard matches == expectedMatches else { continue }
            if bestMatch == nil || matches > bestMatch!.count {
                bestMatch = (key: storedKey, count: matches)
                hasAmbiguousBestMatch = false
            } else if matches == bestMatch!.count {
                hasAmbiguousBestMatch = true
            }
        }

        guard !hasAmbiguousBestMatch else { return nil }
        return bestMatch?.key
    }

    static func identityReplacements(
        for state: ScreenTileState,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow],
        layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity],
        gapPixels: CGFloat
    ) -> [WindowIdentity: WindowIdentity] {
        let stateIDs = state.windowIDs
        let currentIDs = Set(currentWindows.map(\.id))
        var missingStateIDs = stateIDs.subtracting(currentIDs)
        var appearingWindows = currentWindows.filter { !stateIDs.contains($0.id) }
        guard !missingStateIDs.isEmpty, !appearingWindows.isEmpty else { return [:] }

        var replacements: [WindowIdentity: WindowIdentity] = [:]
        replacements.merge(
            WindowLayoutIdentityMatcher.replacements(
                stored: layoutIdentityItems(
                    forStoredIDs: missingStateIDs,
                    identitiesByWindowID: layoutIdentityByWindowID
                ),
                visible: layoutIdentityItems(forWindows: appearingWindows)
            ),
            uniquingKeysWith: { existing, _ in existing }
        )

        missingStateIDs.subtract(Set(replacements.keys))
        let usedVisibleIDs = Set(replacements.values)
        appearingWindows.removeAll { usedVisibleIDs.contains($0.id) }
        replacements.merge(
            frameBasedIdentityReplacements(
                forStoredIDs: missingStateIDs,
                in: state,
                on: screen,
                currentWindows: appearingWindows,
                gapPixels: gapPixels
            ),
            uniquingKeysWith: { existing, _ in existing }
        )
        return replacements
    }

    static func layoutIdentityItems(
        forStoredIDs ids: Set<WindowIdentity>,
        identitiesByWindowID: [WindowIdentity: WindowLayoutIdentity]
    ) -> [(id: WindowIdentity, identity: WindowLayoutIdentity)] {
        ids.compactMap { id in
            guard let layoutIdentity = identitiesByWindowID[id] else { return nil }
            return (id: id, identity: layoutIdentity)
        }
    }

    static func layoutIdentityItems(forWindows windows: [ManagedWindow]) -> [(id: WindowIdentity, identity: WindowLayoutIdentity)] {
        windows.compactMap { window in
            guard let layoutIdentity = window.layoutIdentity else { return nil }
            return (id: window.id, identity: layoutIdentity)
        }
    }

    static func persistedLayoutCandidates(
        for currentKey: String,
        in snapshots: [PersistedScreenLayout],
        canMigrateState: (String, String) -> Bool
    ) -> [PersistedScreenLayout] {
        var candidates = snapshots.filter { $0.stateKey == currentKey }
        let fallbackCandidates = snapshots
            .filter { $0.stateKey != currentKey && canMigrateState($0.stateKey, currentKey) }
            .sorted { lhs, rhs in
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                return lhs.stateKey < rhs.stateKey
            }
        candidates.append(contentsOf: fallbackCandidates)
        return candidates
    }

    static func restoredState(
        from snapshot: PersistedScreenLayout,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow],
        gapPixels: CGFloat
    ) -> ScreenTileState? {
        guard !snapshot.entriesByID.isEmpty, !currentWindows.isEmpty else { return nil }
        let storedLayoutIdentityItems: [(id: Int, identity: WindowLayoutIdentity)] = snapshot.entriesByID.values.compactMap { entry in
            guard let layoutIdentity = entry.layoutIdentity else { return nil }
            return (id: entry.id, identity: layoutIdentity)
        }
        var entryIDToWindowID = WindowLayoutIdentityMatcher.replacements(
            stored: storedLayoutIdentityItems,
            visible: layoutIdentityItems(forWindows: currentWindows)
        )

        let usedWindowIDs = Set(entryIDToWindowID.values)
        entryIDToWindowID.merge(
            frameBasedPersistedLayoutReplacements(
                from: snapshot,
                on: screen,
                currentWindows: currentWindows.filter { !usedWindowIDs.contains($0.id) },
                excludingEntryIDs: Set(entryIDToWindowID.keys),
                gapPixels: gapPixels
            ),
            uniquingKeysWith: { existing, _ in existing }
        )

        let secondPassUsedWindowIDs = Set(entryIDToWindowID.values)
        entryIDToWindowID.merge(
            orderBasedPersistedLayoutReplacements(
                from: snapshot,
                currentWindows: currentWindows.filter { !secondPassUsedWindowIDs.contains($0.id) },
                excludingEntryIDs: Set(entryIDToWindowID.keys)
            ),
            uniquingKeysWith: { existing, _ in existing }
        )

        guard let tree = snapshot.tree.compactMapIDs({ entryIDToWindowID[$0] }) else { return nil }
        let focusedID = snapshot.lastFocusedEntryID.flatMap { entryIDToWindowID[$0] }
        return ScreenTileState(tree: tree, lastFocusedID: focusedID)
    }

    static func snapshot(
        stateKey: String,
        state: ScreenTileState,
        windowsByID: [WindowIdentity: ManagedWindow],
        layoutIdentityByWindowID: [WindowIdentity: WindowLayoutIdentity],
        displayKey: String
    ) -> PersistedScreenLayout? {
        let slotList = state.slotList
        guard !slotList.isEmpty else { return nil }

        var entryIDByWindowID: [WindowIdentity: Int] = [:]
        var entriesByID: [Int: PersistedWindowLayoutEntry] = [:]
        var nextEntryID = 1
        for item in slotList {
            guard let window = windowsByID[item.id] else { return nil }
            let entryID = nextEntryID
            nextEntryID += 1
            entryIDByWindowID[item.id] = entryID
            entriesByID[entryID] = PersistedWindowLayoutEntry(
                id: entryID,
                pid: window.id.pid,
                bundleIdentifier: window.bundleIdentifier,
                layoutIdentity: window.layoutIdentity ?? layoutIdentityByWindowID[window.id],
                orderRank: window.orderRank,
                scanIndex: window.scanIndex
            )
        }

        guard let tree = state.compactMapWindowIDs({ entryIDByWindowID[$0] }) else {
            return nil
        }
        return PersistedScreenLayout(
            stateKey: stateKey,
            displayKey: displayKey,
            tree: tree,
            entriesByID: entriesByID,
            lastFocusedEntryID: state.focusedWindowID.flatMap { entryIDByWindowID[$0] },
            lastUpdated: Date()
        )
    }

    private static func frameBasedIdentityReplacements(
        forStoredIDs storedIDs: Set<WindowIdentity>,
        in state: ScreenTileState,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow],
        gapPixels: CGFloat
    ) -> [WindowIdentity: WindowIdentity] {
        guard !storedIDs.isEmpty, !currentWindows.isEmpty else { return [:] }
        let slots = state.slots
        var candidates: [(storedID: WindowIdentity, visibleID: WindowIdentity, score: CGFloat)] = []
        for storedID in storedIDs {
            guard let slot = slots[storedID] else { continue }
            let expectedFrame = slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true)
            for window in currentWindows where window.id.pid == storedID.pid {
                let score = expectedFrame.frameSimilarityScore(to: window.frame)
                guard score <= maximumFrameScore else { continue }
                candidates.append((storedID: storedID, visibleID: window.id, score: score))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.storedID.pid != rhs.storedID.pid { return lhs.storedID.pid < rhs.storedID.pid }
            if lhs.storedID.serial != rhs.storedID.serial { return lhs.storedID.serial < rhs.storedID.serial }
            return lhs.visibleID.serial < rhs.visibleID.serial
        }
        var replacements: [WindowIdentity: WindowIdentity] = [:]
        var usedStoredIDs: Set<WindowIdentity> = []
        var usedVisibleIDs: Set<WindowIdentity> = []
        for candidate in candidates {
            guard !usedStoredIDs.contains(candidate.storedID),
                  !usedVisibleIDs.contains(candidate.visibleID) else {
                continue
            }
            usedStoredIDs.insert(candidate.storedID)
            usedVisibleIDs.insert(candidate.visibleID)
            replacements[candidate.storedID] = candidate.visibleID
        }
        return replacements
    }

    private static func frameBasedPersistedLayoutReplacements(
        from snapshot: PersistedScreenLayout,
        on screen: ScreenInfo,
        currentWindows: [ManagedWindow],
        excludingEntryIDs excludedEntryIDs: Set<Int>,
        gapPixels: CGFloat
    ) -> [Int: WindowIdentity] {
        guard !currentWindows.isEmpty else { return [:] }
        let slots = snapshot.tree.slots()
        var candidates: [(entryID: Int, windowID: WindowIdentity, score: CGFloat)] = []
        for (entryID, entry) in snapshot.entriesByID where !excludedEntryIDs.contains(entryID) {
            guard let slot = slots[entryID] else { continue }
            let expectedFrame = slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true)
            for window in currentWindows where persistedEntry(entry, canFrameMatch: window) {
                let score = expectedFrame.frameSimilarityScore(to: window.frame)
                guard score <= maximumFrameScore else { continue }
                candidates.append((entryID: entryID, windowID: window.id, score: score))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.entryID != rhs.entryID { return lhs.entryID < rhs.entryID }
            return lhs.windowID.serial < rhs.windowID.serial
        }
        var replacements: [Int: WindowIdentity] = [:]
        var usedEntries: Set<Int> = []
        var usedWindows: Set<WindowIdentity> = []
        for candidate in candidates {
            guard !usedEntries.contains(candidate.entryID),
                  !usedWindows.contains(candidate.windowID) else {
                continue
            }
            replacements[candidate.entryID] = candidate.windowID
            usedEntries.insert(candidate.entryID)
            usedWindows.insert(candidate.windowID)
        }
        return replacements
    }

    private static func orderBasedPersistedLayoutReplacements(
        from snapshot: PersistedScreenLayout,
        currentWindows: [ManagedWindow],
        excludingEntryIDs excludedEntryIDs: Set<Int>
    ) -> [Int: WindowIdentity] {
        guard !currentWindows.isEmpty else { return [:] }
        let remainingEntries = snapshot.entriesByID.values.filter { !excludedEntryIDs.contains($0.id) }
        let entriesByGroup = Dictionary(grouping: remainingEntries, by: persistedWindowGroupKey)
        let windowsByGroup = Dictionary(grouping: currentWindows, by: persistedWindowGroupKey)
        var replacements: [Int: WindowIdentity] = [:]
        for (groupKey, entries) in entriesByGroup {
            guard let windows = windowsByGroup[groupKey], entries.count == windows.count else { continue }
            let sortedEntries = entries.sorted {
                if $0.orderRank != $1.orderRank { return ($0.orderRank ?? Int.max) < ($1.orderRank ?? Int.max) }
                if $0.scanIndex != $1.scanIndex { return $0.scanIndex < $1.scanIndex }
                return $0.id < $1.id
            }
            let sortedWindows = windows.sorted {
                if $0.orderRank != $1.orderRank { return ($0.orderRank ?? Int.max) < ($1.orderRank ?? Int.max) }
                if $0.scanIndex != $1.scanIndex { return $0.scanIndex < $1.scanIndex }
                return $0.id.serial < $1.id.serial
            }
            for (entry, window) in zip(sortedEntries, sortedWindows) {
                replacements[entry.id] = window.id
            }
        }
        return replacements
    }

    private static func persistedEntry(_ entry: PersistedWindowLayoutEntry, canFrameMatch window: ManagedWindow) -> Bool {
        entry.pid == window.id.pid &&
            (entry.bundleIdentifier == nil || window.bundleIdentifier == nil || entry.bundleIdentifier == window.bundleIdentifier)
    }

    private static func persistedWindowGroupKey(for entry: PersistedWindowLayoutEntry) -> PersistedWindowGroupKey {
        PersistedWindowGroupKey(pid: entry.pid, bundleIdentifier: entry.bundleIdentifier)
    }

    private static func persistedWindowGroupKey(for window: ManagedWindow) -> PersistedWindowGroupKey {
        PersistedWindowGroupKey(pid: window.id.pid, bundleIdentifier: window.bundleIdentifier)
    }
}
