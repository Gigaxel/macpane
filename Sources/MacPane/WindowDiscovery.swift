import AppKit
import ApplicationServices
import CoreGraphics

struct WindowDiscoveryResult {
    let windows: [ManagedWindow]
    let retainedIDs: Set<WindowIdentity>
}

struct WindowDiscovery {
    let metadataReader: WindowMetadataReader
    let screenCatalog: ScreenCatalog
    let accessibilityMessagingTimeout: Float

    func managedWindows(
        snapshot: OnScreenWindowSnapshot,
        screens: [ScreenInfo],
        retainedOffscreenIDs: Set<WindowIdentity>,
        identityRegistry: inout WindowIdentityRegistry,
        knownStateKey: (WindowIdentity) -> String?,
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo
    ) -> WindowDiscoveryResult {
        var candidates = windowCandidates(screens: screens)
        candidates = visibleCandidates(from: candidates, snapshot: snapshot)

        let stronglyVisibleIDs = stronglyVisibleIDs(from: candidates, identityRegistry: identityRegistry)
        identityRegistry.retainAliases(for: stronglyVisibleIDs.union(retainedOffscreenIDs))

        let signatureCounts = signatureCounts(for: candidates)
        let windows = managedWindows(
            from: candidates,
            signatureCounts: signatureCounts,
            identityRegistry: &identityRegistry,
            knownStateKey: knownStateKey,
            screenForKnownStateKey: screenForKnownStateKey
        )
        let retainedIDs = Set(windows.map(\.id)).union(retainedOffscreenIDs)
        identityRegistry.retainAliases(for: retainedIDs)

        return WindowDiscoveryResult(
            windows: windows.sorted(by: Self.shouldOrderBefore),
            retainedIDs: retainedIDs
        )
    }

    private func windowCandidates(screens: [ScreenInfo]) -> [ManagedWindowCandidate] {
        let apps = NSWorkspace.shared.runningApplications
            .filter(metadataReader.isManageableApp)
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }

        var candidates: [ManagedWindowCandidate] = []
        var scanIndex = 0
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
            let appWindows = AXReader.elements(appElement, attribute: kAXWindowsAttribute)
            for window in appWindows {
                guard let candidate = windowCandidate(
                    window,
                    app: app,
                    screens: screens,
                    scanIndex: scanIndex
                ) else {
                    continue
                }
                candidates.append(candidate)
                scanIndex += 1
            }
        }
        return candidates
    }

    private func windowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        screens: [ScreenInfo],
        scanIndex: Int
    ) -> ManagedWindowCandidate? {
        guard let position = AXReader.point(window, attribute: kAXPositionAttribute),
              let size = AXReader.size(window, attribute: kAXSizeAttribute),
              size.width >= TileLayout.minimumWindowFrameSize.width,
              size.height >= TileLayout.minimumWindowFrameSize.height else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        let title = AXReader.string(window, attribute: kAXTitleAttribute)
        guard screenCatalog.frameIntersectsAnyVisibleScreen(frame, screens: screens),
              metadataReader.isManageableWindow(window, app: app, frame: frame, title: title) else {
            return nil
        }

        let screen = screenCatalog.info(for: frame, screens: screens)
        return ManagedWindowCandidate(
            pid: app.processIdentifier,
            windowNumber: AXReader.int(window, attribute: "AXWindowNumber")
                ?? AXReader.int(window, attribute: "_AXWindowNumber"),
            elementKey: WindowElementKey(pid: app.processIdentifier, hash: CFHash(window)),
            signature: metadataReader.signature(for: window, app: app, title: title, stateKey: screen.stateKey),
            layoutIdentity: metadataReader.layoutIdentity(for: window, app: app, title: title),
            element: window,
            screen: screen,
            frame: frame,
            bundleIdentifier: app.bundleIdentifier,
            title: title,
            orderRank: nil,
            scanIndex: scanIndex
        )
    }

    private func visibleCandidates(
        from candidates: [ManagedWindowCandidate],
        snapshot: OnScreenWindowSnapshot
    ) -> [ManagedWindowCandidate] {
        var visibleCandidates: [ManagedWindowCandidate] = []
        var claimedNumbersByPID: [pid_t: Set<Int>] = [:]

        for var candidate in candidates {
            let number: Int
            if let candidateNumber = candidate.windowNumber {
                guard snapshot.visibleNumbersByPID[candidate.pid]?.contains(candidateNumber) == true else {
                    continue
                }
                number = candidateNumber
            } else {
                guard let matchedNumber = snapshot.matchWindowNumber(
                    pid: candidate.pid,
                    frame: candidate.frame,
                    title: candidate.title,
                    excluding: claimedNumbersByPID[candidate.pid] ?? []
                ) else {
                    continue
                }
                candidate.windowNumber = matchedNumber
                number = matchedNumber
            }

            guard claimedNumbersByPID[candidate.pid]?.contains(number) != true else {
                continue
            }
            claimedNumbersByPID[candidate.pid, default: []].insert(number)
            candidate.orderRank = snapshot.rankByWindow[WindowOrderKey(pid: candidate.pid, number: number)]
            visibleCandidates.append(candidate)
        }
        return visibleCandidates
    }

    private func stronglyVisibleIDs(
        from candidates: [ManagedWindowCandidate],
        identityRegistry: WindowIdentityRegistry
    ) -> Set<WindowIdentity> {
        Set(candidates.compactMap { candidate -> WindowIdentity? in
            let windowKey = candidate.windowNumber.map { WindowOrderKey(pid: candidate.pid, number: $0) }
            return identityRegistry.identityForStrongAlias(windowKey: windowKey, elementKey: candidate.elementKey)
        })
    }

    private func signatureCounts(for candidates: [ManagedWindowCandidate]) -> [WindowSignature: Int] {
        candidates.reduce(into: [WindowSignature: Int]()) { counts, candidate in
            guard let signature = candidate.signature else { return }
            counts[signature, default: 0] += 1
        }
    }

    private func managedWindows(
        from candidates: [ManagedWindowCandidate],
        signatureCounts: [WindowSignature: Int],
        identityRegistry: inout WindowIdentityRegistry,
        knownStateKey: (WindowIdentity) -> String?,
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo
    ) -> [ManagedWindow] {
        var windows: [ManagedWindow] = []
        var seenIDs: Set<WindowIdentity> = []
        for candidate in candidates {
            let windowKey = candidate.windowNumber.map { WindowOrderKey(pid: candidate.pid, number: $0) }
            let uniqueSignature = candidate.signature.flatMap { signatureCounts[$0] == 1 ? $0 : nil }
            let id = identityRegistry.identity(
                for: windowKey,
                elementKey: candidate.elementKey,
                signature: uniqueSignature,
                avoidingIdentities: seenIDs
            )
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            let screen = knownStateKey(id)
                .map { screenForKnownStateKey($0, candidate.screen) }
                ?? candidate.screen
            windows.append(ManagedWindow(
                id: id,
                windowNumber: candidate.windowNumber,
                element: candidate.element,
                screen: screen,
                layoutIdentity: candidate.layoutIdentity,
                frame: candidate.frame,
                bundleIdentifier: candidate.bundleIdentifier,
                title: candidate.title,
                orderRank: candidate.orderRank,
                scanIndex: candidate.scanIndex
            ))
        }
        return windows
    }

    private static func shouldOrderBefore(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> Bool {
        // CGWindowList is front-to-back. Syncing back-to-front makes a newly frontmost window insert last.
        switch (lhs.orderRank, rhs.orderRank) {
        case (.some(let lhsRank), .some(let rhsRank)) where lhsRank != rhsRank:
            return lhsRank > rhsRank
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        let lhsApp = lhs.bundleIdentifier ?? ""
        let rhsApp = rhs.bundleIdentifier ?? ""
        if lhsApp != rhsApp { return lhsApp < rhsApp }
        if lhs.id.pid != rhs.id.pid { return lhs.id.pid < rhs.id.pid }
        switch (lhs.windowNumber, rhs.windowNumber) {
        case (.some(let lhsNumber), .some(let rhsNumber)) where lhsNumber != rhsNumber:
            return lhsNumber < rhsNumber
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.scanIndex < rhs.scanIndex
        }
    }
}

private struct ManagedWindowCandidate {
    let pid: pid_t
    var windowNumber: Int?
    let elementKey: WindowElementKey
    let signature: WindowSignature?
    let layoutIdentity: WindowLayoutIdentity?
    let element: AXUIElement
    let screen: ScreenInfo
    let frame: CGRect
    let bundleIdentifier: String?
    let title: String?
    var orderRank: Int?
    let scanIndex: Int
}
