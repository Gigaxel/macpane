import AppKit
import ApplicationServices
import CoreGraphics

struct WindowDiscoveryResult {
    let windows: [ManagedWindow]
    let retainedIDs: Set<WindowIdentity>
    let newlyCreatedIDs: Set<WindowIdentity>
    let rawWindowsByPID: [pid_t: [AXUIElement]]
    let hasDeferredCandidates: Bool
}

struct WindowDiscovery {
    let metadataReader: WindowMetadataReader
    let metadataCache: WindowElementMetadataCache
    let screenCatalog: ScreenCatalog
    let accessibilityMessagingTimeout: Float

    private static let knownWindowDynamicAttributes: [String] = [
        kAXTitleAttribute,
        kAXDocumentAttribute,
        kAXMinimizedAttribute,
        "AXFullScreen",
        "AXModal"
    ]
    private static let newWindowAttributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXDocumentAttribute,
        kAXMinimizedAttribute,
        "AXFullScreen",
        "AXModal",
        "AXIdentifier",
        "AXWindowNumber",
        "_AXWindowNumber",
        kAXPositionAttribute,
        kAXSizeAttribute
    ]

    func managedWindows(
        snapshot: OnScreenWindowSnapshot,
        screens: [ScreenInfo],
        retainedOffscreenIDs: Set<WindowIdentity>,
        identityRegistry: inout WindowIdentityRegistry,
        knownStateKey: (WindowIdentity) -> String?,
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo
    ) -> WindowDiscoveryResult {
        let scan = windowCandidates(
            screens: screens,
            visiblePIDs: Set(snapshot.visibleNumbersByPID.keys),
            snapshot: snapshot
        )
        let candidates = visibleCandidates(from: scan.candidates, snapshot: snapshot)

        let stronglyVisibleIDs = stronglyVisibleIDs(from: candidates, identityRegistry: identityRegistry)
        identityRegistry.retainAliases(for: stronglyVisibleIDs.union(retainedOffscreenIDs))

        let signatureCounts = signatureCounts(for: candidates)
        let resolution = managedWindows(
            from: candidates,
            signatureCounts: signatureCounts,
            identityRegistry: &identityRegistry,
            knownStateKey: knownStateKey,
            screenForKnownStateKey: screenForKnownStateKey
        )
        let retainedIDs = Set(resolution.windows.map(\.id)).union(retainedOffscreenIDs)
        identityRegistry.retainAliases(for: retainedIDs)

        return WindowDiscoveryResult(
            windows: resolution.windows.sorted(by: Self.shouldOrderBefore),
            retainedIDs: retainedIDs,
            newlyCreatedIDs: resolution.newlyCreatedIDs,
            rawWindowsByPID: scan.rawWindowsByPID,
            hasDeferredCandidates: scan.hasDeferredCandidates
        )
    }

    private func windowCandidates(
        screens: [ScreenInfo],
        visiblePIDs: Set<pid_t>,
        snapshot: OnScreenWindowSnapshot
    ) -> (
        candidates: [ManagedWindowCandidate],
        rawWindowsByPID: [pid_t: [AXUIElement]],
        hasDeferredCandidates: Bool
    ) {
        let apps = NSWorkspace.shared.runningApplications
            .filter { visiblePIDs.contains($0.processIdentifier) && metadataReader.isManageableApp($0) }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }

        var candidates: [ManagedWindowCandidate] = []
        var rawWindowsByPID: [pid_t: [AXUIElement]] = [:]
        var scanIndex = 0
        var hasDeferredCandidates = false
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
            switch AXReader.elementsChecked(appElement, attribute: kAXWindowsAttribute) {
            case .value(let appWindows):
                rawWindowsByPID[app.processIdentifier] = appWindows
                for window in appWindows {
                    guard let candidate = windowCandidate(
                        window,
                        app: app,
                        screens: screens,
                        snapshot: snapshot,
                        scanIndex: scanIndex,
                        hasDeferredCandidates: &hasDeferredCandidates
                    ) else {
                        continue
                    }
                    candidates.append(candidate)
                    scanIndex += 1
                }
            case .missing:
                continue
            case .failed:
                hasDeferredCandidates = true
                candidates.append(contentsOf: synthesizedCandidates(
                    for: app,
                    screens: screens,
                    snapshot: snapshot,
                    scanIndex: &scanIndex
                ))
            }
        }
        return (candidates, rawWindowsByPID, hasDeferredCandidates)
    }

    private func windowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int,
        hasDeferredCandidates: inout Bool
    ) -> ManagedWindowCandidate? {
        let pid = app.processIdentifier
        let elementKey = WindowElementKey(pid: pid, hash: CFHash(window))
        if let cached = metadataCache.entry(for: elementKey), cached.isStaticallyManageable {
            return knownWindowCandidate(
                window,
                app: app,
                cached: cached,
                elementKey: elementKey,
                screens: screens,
                snapshot: snapshot,
                scanIndex: scanIndex
            )
        }
        return newWindowCandidate(
            window,
            app: app,
            elementKey: elementKey,
            screens: screens,
            snapshot: snapshot,
            scanIndex: scanIndex,
            hasDeferredCandidates: &hasDeferredCandidates
        )
    }

    private func knownWindowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        cached: WindowElementMetadataCache.Entry,
        elementKey: WindowElementKey,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int
    ) -> ManagedWindowCandidate? {
        let pid = app.processIdentifier
        let dynamics = AXReader.multipleChecked(window, attributes: Self.knownWindowDynamicAttributes)
        var title: String?
        var document: String?
        if let dynamics {
            for flagAttribute in [kAXMinimizedAttribute, "AXFullScreen", "AXModal"] {
                if case .value(true) = AXReader.boolReadFromBatch(dynamics[flagAttribute]) {
                    return nil
                }
            }
            title = AXReader.stringFromBatch(dynamics[kAXTitleAttribute])
            document = AXReader.stringFromBatch(dynamics[kAXDocumentAttribute])
            if WindowManageabilityPlanner.isExcludedTitle(title) {
                return nil
            }
        }
        var frame: CGRect?
        if let number = cached.windowNumber {
            frame = snapshot.frame(pid: pid, number: number)
        }
        if frame == nil,
           let position = AXReader.point(window, attribute: kAXPositionAttribute),
           let size = AXReader.size(window, attribute: kAXSizeAttribute),
           size.width > 0, size.height > 0 {
            frame = CGRect(origin: position, size: size)
        }
        if frame == nil {
            frame = cached.lastKnownFrame
        }
        guard let frame, screenCatalog.frameIntersectsAnyVisibleScreen(frame, screens: screens) else {
            return nil
        }
        metadataCache.update(elementKey, element: window) { entry in
            entry.lastKnownFrame = frame
        }

        let screen = screenCatalog.info(for: frame, screens: screens)
        let descriptors = metadataReader.descriptors(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            axIdentifier: cached.axIdentifier,
            document: document,
            title: title,
            stateKey: screen.stateKey
        )
        return ManagedWindowCandidate(
            pid: pid,
            windowNumber: cached.windowNumber,
            elementKey: elementKey,
            signature: descriptors.signature,
            layoutIdentity: descriptors.layoutIdentity,
            element: window,
            screen: screen,
            frame: frame,
            bundleIdentifier: app.bundleIdentifier,
            title: title,
            orderRank: nil,
            scanIndex: scanIndex
        )
    }

    private func newWindowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        elementKey: WindowElementKey,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int,
        hasDeferredCandidates: inout Bool
    ) -> ManagedWindowCandidate? {
        let pid = app.processIdentifier
        guard let reads = AXReader.multipleChecked(window, attributes: Self.newWindowAttributes) else {
            hasDeferredCandidates = true
            return nil
        }

        let title = AXReader.stringFromBatch(reads[kAXTitleAttribute])
        var inputs = WindowManageabilityPlanner.Inputs(
            role: AXReader.stringReadFromBatch(reads[kAXRoleAttribute]),
            subrole: AXReader.stringReadFromBatch(reads[kAXSubroleAttribute]),
            isMinimized: AXReader.boolReadFromBatch(reads[kAXMinimizedAttribute]),
            isFullScreen: AXReader.boolReadFromBatch(reads["AXFullScreen"]),
            isModal: AXReader.boolReadFromBatch(reads["AXModal"]),
            title: title,
            positionSettable: .value(true),
            sizeSettable: .value(true)
        )
        switch WindowManageabilityPlanner.manageability(inputs) {
        case .excluded:
            return nil
        case .unknown:
            hasDeferredCandidates = true
            return nil
        case .manageable:
            break
        }
        inputs.positionSettable = settableRead(window, attribute: kAXPositionAttribute)
        inputs.sizeSettable = settableRead(window, attribute: kAXSizeAttribute)
        switch WindowManageabilityPlanner.manageability(inputs) {
        case .excluded:
            return nil
        case .unknown:
            hasDeferredCandidates = true
            return nil
        case .manageable:
            break
        }

        let windowNumber = AXReader.intFromBatch(reads["AXWindowNumber"])
            ?? AXReader.intFromBatch(reads["_AXWindowNumber"])
        var frame: CGRect?
        if let position = AXReader.pointFromBatch(reads[kAXPositionAttribute]),
           let size = AXReader.sizeFromBatch(reads[kAXSizeAttribute]),
           size.width > 0, size.height > 0 {
            frame = CGRect(origin: position, size: size)
        }
        if frame == nil, let windowNumber {
            frame = snapshot.frame(pid: pid, number: windowNumber)
        }
        guard let frame, screenCatalog.frameIntersectsAnyVisibleScreen(frame, screens: screens) else {
            return nil
        }

        let axIdentifier = AXReader.stringFromBatch(reads["AXIdentifier"])
        metadataCache.update(elementKey, element: window) { entry in
            entry.isStaticallyManageable = true
            entry.windowNumber = windowNumber
            entry.axIdentifier = axIdentifier
            entry.lastKnownFrame = frame
        }

        let screen = screenCatalog.info(for: frame, screens: screens)
        let descriptors = metadataReader.descriptors(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            axIdentifier: axIdentifier,
            document: AXReader.stringFromBatch(reads[kAXDocumentAttribute]),
            title: title,
            stateKey: screen.stateKey
        )
        return ManagedWindowCandidate(
            pid: pid,
            windowNumber: windowNumber,
            elementKey: elementKey,
            signature: descriptors.signature,
            layoutIdentity: descriptors.layoutIdentity,
            element: window,
            screen: screen,
            frame: frame,
            bundleIdentifier: app.bundleIdentifier,
            title: title,
            orderRank: nil,
            scanIndex: scanIndex
        )
    }

    private func synthesizedCandidates(
        for app: NSRunningApplication,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: inout Int
    ) -> [ManagedWindowCandidate] {
        let pid = app.processIdentifier
        let entries = metadataCache.entries(forPID: pid)
            .filter { $0.entry.isStaticallyManageable && $0.entry.windowNumber != nil }
            .sorted { ($0.entry.windowNumber ?? 0) < ($1.entry.windowNumber ?? 0) }
        var candidates: [ManagedWindowCandidate] = []
        for (key, entry) in entries {
            guard let number = entry.windowNumber,
                  snapshot.visibleNumbersByPID[pid]?.contains(number) == true,
                  let frame = snapshot.frame(pid: pid, number: number) ?? entry.lastKnownFrame,
                  screenCatalog.frameIntersectsAnyVisibleScreen(frame, screens: screens) else {
                continue
            }
            candidates.append(ManagedWindowCandidate(
                pid: pid,
                windowNumber: number,
                elementKey: key,
                signature: nil,
                layoutIdentity: nil,
                element: entry.element,
                screen: screenCatalog.info(for: frame, screens: screens),
                frame: frame,
                bundleIdentifier: app.bundleIdentifier,
                title: nil,
                orderRank: nil,
                scanIndex: scanIndex
            ))
            scanIndex += 1
        }
        return candidates
    }

    private func settableRead(_ window: AXUIElement, attribute: String) -> AXRead<Bool> {
        var settable = DarwinBoolean(false)
        switch AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) {
        case .success:
            return .value(settable.boolValue)
        case .noValue, .attributeUnsupported:
            return .value(false)
        default:
            return .failed
        }
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
    ) -> (windows: [ManagedWindow], newlyCreatedIDs: Set<WindowIdentity>) {
        var windows: [ManagedWindow] = []
        var seenIDs: Set<WindowIdentity> = []
        var newlyCreatedIDs: Set<WindowIdentity> = []
        for candidate in candidates {
            let windowKey = candidate.windowNumber.map { WindowOrderKey(pid: candidate.pid, number: $0) }
            let uniqueSignature = candidate.signature.flatMap { signatureCounts[$0] == 1 ? $0 : nil }
            let resolution = identityRegistry.resolveIdentity(
                for: windowKey,
                elementKey: candidate.elementKey,
                signature: uniqueSignature,
                avoidingIdentities: seenIDs
            )
            let id = resolution.id
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)
            if resolution.isNewlyCreated {
                newlyCreatedIDs.insert(id)
            }

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
        return (windows, newlyCreatedIDs)
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
