import Foundation

struct WindowLayoutIdentity: Hashable {
    let pid: pid_t
    let bundleIdentifier: String?
    let axIdentifier: String?
    let document: String?
    let title: String?

    var hasStableComponent: Bool {
        axIdentifier != nil || document != nil || title != nil
    }

    var matchKeys: [WindowLayoutIdentityMatchKey] {
        var keys: [WindowLayoutIdentityMatchKey] = []
        if let axIdentifier {
            keys.append(WindowLayoutIdentityMatchKey(
                kind: .axIdentifier,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                value: axIdentifier
            ))
        }
        if let document {
            keys.append(WindowLayoutIdentityMatchKey(
                kind: .document,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                value: document
            ))
        }
        if let title {
            keys.append(WindowLayoutIdentityMatchKey(
                kind: .title,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                value: title
            ))
        }
        return keys
    }

    func value(for kind: WindowLayoutIdentityMatchKey.Kind) -> String? {
        switch kind {
        case .axIdentifier:
            return axIdentifier
        case .document:
            return document
        case .title:
            return title
        }
    }
}

struct WindowLayoutIdentityMatchKey: Hashable {
    enum Kind: CaseIterable {
        case axIdentifier
        case document
        case title

        var strongerKinds: [Kind] {
            switch self {
            case .axIdentifier:
                return []
            case .document:
                return [.axIdentifier]
            case .title:
                return [.axIdentifier, .document]
            }
        }
    }

    let kind: Kind
    let pid: pid_t
    let bundleIdentifier: String?
    let value: String
}

enum WindowLayoutIdentityMatcher {
    private struct MatchCandidate<ID: Hashable> {
        let id: ID
        let identity: WindowLayoutIdentity
    }

    static func replacements<StoredID: Hashable, VisibleID: Hashable>(
        stored: [(id: StoredID, identity: WindowLayoutIdentity)],
        visible: [(id: VisibleID, identity: WindowLayoutIdentity)]
    ) -> [StoredID: VisibleID] {
        var replacements: [StoredID: VisibleID] = [:]
        var usedStoredIDs: Set<StoredID> = []
        var usedVisibleIDs: Set<VisibleID> = []

        for kind in WindowLayoutIdentityMatchKey.Kind.allCases {
            let storedCandidatesByKey = uniqueCandidatesByKey(stored, kind: kind, excluding: usedStoredIDs)
            let visibleCandidatesByKey = uniqueCandidatesByKey(visible, kind: kind, excluding: usedVisibleIDs)
            for (key, storedCandidate) in storedCandidatesByKey {
                guard let visibleCandidate = visibleCandidatesByKey[key],
                      !usedStoredIDs.contains(storedCandidate.id),
                      !usedVisibleIDs.contains(visibleCandidate.id),
                      canMatch(storedCandidate.identity, visibleCandidate.identity, by: kind) else {
                    continue
                }
                replacements[storedCandidate.id] = visibleCandidate.id
                usedStoredIDs.insert(storedCandidate.id)
                usedVisibleIDs.insert(visibleCandidate.id)
            }
        }

        return replacements
    }

    private static func uniqueCandidatesByKey<ID: Hashable>(
        _ items: [(id: ID, identity: WindowLayoutIdentity)],
        kind: WindowLayoutIdentityMatchKey.Kind,
        excluding excludedIDs: Set<ID>
    ) -> [WindowLayoutIdentityMatchKey: MatchCandidate<ID>] {
        var candidatesByKey: [WindowLayoutIdentityMatchKey: [MatchCandidate<ID>]] = [:]
        for item in items where !excludedIDs.contains(item.id) {
            for key in item.identity.matchKeys where key.kind == kind {
                candidatesByKey[key, default: []].append(MatchCandidate(id: item.id, identity: item.identity))
            }
        }
        return candidatesByKey.compactMapValues { candidates in
            Set(candidates.map(\.id)).count == 1 ? candidates[0] : nil
        }
    }

    private static func canMatch(
        _ stored: WindowLayoutIdentity,
        _ visible: WindowLayoutIdentity,
        by kind: WindowLayoutIdentityMatchKey.Kind
    ) -> Bool {
        for strongerKind in kind.strongerKinds {
            guard let storedValue = stored.value(for: strongerKind),
                  let visibleValue = visible.value(for: strongerKind) else {
                continue
            }
            guard storedValue == visibleValue else { return false }
        }
        return true
    }
}
