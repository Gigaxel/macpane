import Foundation
struct WindowIdentity: Hashable {
    let pid: pid_t
    let serial: Int
}
struct WindowOrderKey: Hashable {
    let pid: pid_t
    let number: Int
}
struct WindowElementKey: Hashable {
    let pid: pid_t
    let hash: CFHashCode
}
struct WindowSignature: Hashable {
    let pid: pid_t
    let stateKey: String?
    let bundleIdentifier: String?
    let axIdentifier: String?
    let document: String?
    let title: String?
    var hasStableComponent: Bool {
        axIdentifier != nil || document != nil || title != nil
    }
}
struct WindowIdentityRegistry {
    private var nextWindowIdentitySerial = 1
    private var identityByWindowNumber: [WindowOrderKey: WindowIdentity] = [:]
    private var windowNumbersByIdentity: [WindowIdentity: Set<WindowOrderKey>] = [:]
    private var identityByElement: [WindowElementKey: WindowIdentity] = [:]
    private var elementsByIdentity: [WindowIdentity: Set<WindowElementKey>] = [:]
    private var identityBySignature: [WindowSignature: WindowIdentity] = [:]
    private var signaturesByIdentity: [WindowIdentity: Set<WindowSignature>] = [:]
    mutating func identity(
        for windowKey: WindowOrderKey?,
        elementKey: WindowElementKey,
        signature: WindowSignature?,
        avoidingIdentities reservedIdentities: Set<WindowIdentity> = []
    ) -> WindowIdentity {
        if let existing = identityByElement[elementKey] {
            rememberIdentity(existing, windowKey: windowKey, elementKey: elementKey, signature: signature)
            return existing
        }
        if let windowKey,
           let existing = identityByWindowNumber[windowKey],
           !reservedIdentities.contains(existing),
           isCompatibleIdentity(existing, signature: signature) {
            rememberIdentity(existing, windowKey: windowKey, elementKey: elementKey, signature: signature)
            return existing
        }
        if let signature,
           let existing = identityBySignature[signature],
           !reservedIdentities.contains(existing) {
            rememberIdentity(existing, windowKey: windowKey, elementKey: elementKey, signature: signature)
            return existing
        }
        let created = WindowIdentity(pid: windowKey?.pid ?? elementKey.pid, serial: nextWindowIdentitySerial)
        nextWindowIdentitySerial += 1
        rememberIdentity(created, windowKey: windowKey, elementKey: elementKey, signature: signature)
        return created
    }
    mutating func retainAliases(for retainedIdentities: Set<WindowIdentity>) {
        let knownIdentities = Set(windowNumbersByIdentity.keys)
            .union(elementsByIdentity.keys)
            .union(signaturesByIdentity.keys)
        for identity in knownIdentities where !retainedIdentities.contains(identity) {
            removeAliases(for: identity)
        }
    }
    func identityForStrongAlias(windowKey: WindowOrderKey?, elementKey: WindowElementKey) -> WindowIdentity? {
        if let existing = identityByElement[elementKey] {
            return existing
        }
        if let windowKey {
            return identityByWindowNumber[windowKey]
        }
        return nil
    }
    mutating func removeAliases(for identities: Set<WindowIdentity>) {
        for identity in identities {
            removeAliases(for: identity)
        }
    }
    private mutating func rememberIdentity(
        _ identity: WindowIdentity,
        windowKey: WindowOrderKey?,
        elementKey: WindowElementKey,
        signature: WindowSignature?
    ) {
        replaceWindowKey(windowKey, for: identity)
        replaceElementKey(elementKey, for: identity)
        replaceSignature(signature, for: identity)
    }
    private mutating func replaceWindowKey(_ windowKey: WindowOrderKey?, for identity: WindowIdentity) {
        let staleKeys = (windowNumbersByIdentity[identity] ?? []).filter { $0 != windowKey }
        for staleKey in staleKeys {
            if identityByWindowNumber[staleKey] == identity {
                identityByWindowNumber.removeValue(forKey: staleKey)
            }
            windowNumbersByIdentity[identity]?.remove(staleKey)
        }
        guard let windowKey else {
            removeEmptyWindowKeySet(for: identity)
            return
        }
        if let replacedIdentity = identityByWindowNumber[windowKey], replacedIdentity != identity {
            windowNumbersByIdentity[replacedIdentity]?.remove(windowKey)
            removeEmptyWindowKeySet(for: replacedIdentity)
        }
        identityByWindowNumber[windowKey] = identity
        windowNumbersByIdentity[identity, default: []].insert(windowKey)
    }
    private mutating func replaceElementKey(_ elementKey: WindowElementKey, for identity: WindowIdentity) {
        let staleKeys = (elementsByIdentity[identity] ?? []).filter { $0 != elementKey }
        for staleKey in staleKeys {
            if identityByElement[staleKey] == identity {
                identityByElement.removeValue(forKey: staleKey)
            }
            elementsByIdentity[identity]?.remove(staleKey)
        }
        if let replacedIdentity = identityByElement[elementKey], replacedIdentity != identity {
            elementsByIdentity[replacedIdentity]?.remove(elementKey)
            removeEmptyElementKeySet(for: replacedIdentity)
        }
        identityByElement[elementKey] = identity
        elementsByIdentity[identity, default: []].insert(elementKey)
    }
    private mutating func replaceSignature(_ signature: WindowSignature?, for identity: WindowIdentity) {
        let staleSignatures: Set<WindowSignature>
        if let signature {
            staleSignatures = (signaturesByIdentity[identity] ?? []).filter { $0 != signature }
        } else {
            staleSignatures = signaturesByIdentity[identity] ?? []
        }
        for staleSignature in staleSignatures {
            if identityBySignature[staleSignature] == identity {
                identityBySignature.removeValue(forKey: staleSignature)
            }
            signaturesByIdentity[identity]?.remove(staleSignature)
        }
        guard let signature else {
            removeEmptySignatureSet(for: identity)
            return
        }
        if let replacedIdentity = identityBySignature[signature], replacedIdentity != identity {
            signaturesByIdentity[replacedIdentity]?.remove(signature)
            removeEmptySignatureSet(for: replacedIdentity)
        }
        identityBySignature[signature] = identity
        signaturesByIdentity[identity, default: []].insert(signature)
    }
    private mutating func removeEmptyWindowKeySet(for identity: WindowIdentity) {
        if windowNumbersByIdentity[identity]?.isEmpty == true {
            windowNumbersByIdentity.removeValue(forKey: identity)
        }
    }
    private mutating func removeEmptyElementKeySet(for identity: WindowIdentity) {
        if elementsByIdentity[identity]?.isEmpty == true {
            elementsByIdentity.removeValue(forKey: identity)
        }
    }
    private mutating func removeEmptySignatureSet(for identity: WindowIdentity) {
        if signaturesByIdentity[identity]?.isEmpty == true {
            signaturesByIdentity.removeValue(forKey: identity)
        }
    }
    private mutating func removeAliases(for identity: WindowIdentity) {
        for key in windowNumbersByIdentity[identity] ?? [] where identityByWindowNumber[key] == identity {
            identityByWindowNumber.removeValue(forKey: key)
        }
        windowNumbersByIdentity.removeValue(forKey: identity)
        for key in elementsByIdentity[identity] ?? [] where identityByElement[key] == identity {
            identityByElement.removeValue(forKey: key)
        }
        elementsByIdentity.removeValue(forKey: identity)
        for signature in signaturesByIdentity[identity] ?? [] where identityBySignature[signature] == identity {
            identityBySignature.removeValue(forKey: signature)
        }
        signaturesByIdentity.removeValue(forKey: identity)
    }
    private func isCompatibleIdentity(_ identity: WindowIdentity, signature: WindowSignature?) -> Bool {
        guard let signature,
              let knownSignatures = signaturesByIdentity[identity],
              !knownSignatures.isEmpty else {
            return true
        }
        return knownSignatures.contains(signature)
    }
}
