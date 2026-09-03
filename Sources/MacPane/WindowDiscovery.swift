import AppKit
import ApplicationServices
import CoreGraphics

struct WindowDiscoveryResult {
    let windows: [ManagedWindow]
    let retainedIDs: Set<WindowIdentity>
    let newlyCreatedIDs: Set<WindowIdentity>
    let rawWindowsByPID: [pid_t: [AXUIElement]]
    let hasDeferredCandidates: Bool
    let minimizedIDs: Set<WindowIdentity>
    let cleanlyScannedPIDs: Set<pid_t>
}

struct MinimizedWindowKey {
    let elementKey: WindowElementKey
    let windowKey: WindowOrderKey?
}

struct WindowProbe {
    let candidate: ManagedWindowCandidate?
    let deferred: Bool
    let isMinimized: Bool
    let isExcluded: Bool
}

struct AppScan {
    var candidates: [ManagedWindowCandidate] = []
    var rawWindows: [AXUIElement]?
    var deferred = false
    var failed = false
    var minimizedKeys: [MinimizedWindowKey] = []
}

final class AppScanCollector {
    private let lock = NSLock()
    private var scans: [AppScan?]

    init(count: Int) {
        scans = Array(repeating: nil, count: count)
    }

    func store(_ scan: AppScan, at index: Int) {
        lock.lock()
        if index < scans.count {
            scans[index] = scan
        }
        lock.unlock()
    }

    func snapshot() -> [AppScan?] {
        lock.lock()
        defer { lock.unlock() }
        return scans
    }
}

struct WindowDiscovery {
    let metadataReader: WindowMetadataReader
    let metadataCache: WindowElementMetadataCache
    let screenCatalog: ScreenCatalog
    let accessibilityMessagingTimeout: Float
    let ioScheduler: AXIOScheduler
    let responsiveness: AppResponsivenessTracker
    let scanTimeout: TimeInterval = 0.35
    let unresponsiveAppCooldown: TimeInterval = 2.0

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
        trackedPIDs: Set<pid_t> = [],
        identityRegistry: inout WindowIdentityRegistry,
        knownStateKey: (WindowIdentity) -> String?,
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo
    ) -> WindowDiscoveryResult {
        let scan = windowCandidates(
            screens: screens,
            visiblePIDs: Set(snapshot.visibleNumbersByPID.keys).union(trackedPIDs),
            snapshot: snapshot
        )
        let candidates = visibleCandidates(from: scan.candidates, snapshot: snapshot)
        let minimizedIDs = Set(scan.minimizedKeys.compactMap {
            identityRegistry.identityForStrongAlias(windowKey: $0.windowKey, elementKey: $0.elementKey)
        })

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
            hasDeferredCandidates: scan.hasDeferredCandidates,
            minimizedIDs: minimizedIDs,
            cleanlyScannedPIDs: scan.cleanlyScannedPIDs
        )
    }

    private func windowCandidates(
        screens: [ScreenInfo],
        visiblePIDs: Set<pid_t>,
        snapshot: OnScreenWindowSnapshot
    ) -> (
        candidates: [ManagedWindowCandidate],
        rawWindowsByPID: [pid_t: [AXUIElement]],
        hasDeferredCandidates: Bool,
        minimizedKeys: [MinimizedWindowKey],
        cleanlyScannedPIDs: Set<pid_t>
    ) {
        let apps = NSWorkspace.shared.runningApplications
            .filter { visiblePIDs.contains($0.processIdentifier) && metadataReader.isManageableApp($0) }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }

        let collector = AppScanCollector(count: apps.count)
        let group = DispatchGroup()
        var skippedIndices: Set<Int> = []
        for (index, app) in apps.enumerated() {
            let pid = app.processIdentifier
            guard responsiveness.isResponsive(pid) else {
                skippedIndices.insert(index)
                continue
            }
            group.enter()
            ioScheduler.async(pid: pid) { [self] in
                let scan = scanApp(app, screens: screens, snapshot: snapshot)
                collector.store(scan, at: index)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + scanTimeout)
        let scans = collector.snapshot()

        var candidates: [ManagedWindowCandidate] = []
        var rawWindowsByPID: [pid_t: [AXUIElement]] = [:]
        var scanIndex = 0
        var hasDeferredCandidates = false
        var minimizedKeys: [MinimizedWindowKey] = []
        var cleanlyScannedPIDs: Set<pid_t> = []
        for (index, app) in apps.enumerated() {
            let pid = app.processIdentifier
            if let scan = scans[index], !scan.failed {
                responsiveness.markResponsive(pid)
                if !scan.deferred {
                    cleanlyScannedPIDs.insert(pid)
                }
                if let rawWindows = scan.rawWindows {
                    rawWindowsByPID[pid] = rawWindows
                }
                for var candidate in scan.candidates {
                    candidate.scanIndex = scanIndex
                    candidates.append(candidate)
                    scanIndex += 1
                }
                hasDeferredCandidates = hasDeferredCandidates || scan.deferred
                minimizedKeys.append(contentsOf: scan.minimizedKeys)
                continue
            }
            if !skippedIndices.contains(index) {
                responsiveness.markUnresponsive(pid, for: unresponsiveAppCooldown)
            }
            hasDeferredCandidates = true
            candidates.append(contentsOf: synthesizedCandidates(
                for: app,
                screens: screens,
                snapshot: snapshot,
                scanIndex: &scanIndex
            ))
        }
        return (candidates, rawWindowsByPID, hasDeferredCandidates, minimizedKeys, cleanlyScannedPIDs)
    }

    private func scanApp(
        _ app: NSRunningApplication,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot
    ) -> AppScan {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)
        var scan = AppScan()
        switch AXReader.elementsChecked(appElement, attribute: kAXWindowsAttribute) {
        case .value(let appWindows):
            scan.rawWindows = appWindows
            for (index, window) in appWindows.enumerated() {
                var excluded = false
                guard let candidate = windowCandidate(
                    window,
                    app: app,
                    screens: screens,
                    snapshot: snapshot,
                    scanIndex: index,
                    hasDeferredCandidates: &scan.deferred,
                    minimizedKeys: &scan.minimizedKeys,
                    excludedByPolicy: &excluded
                ) else {
                    continue
                }
                scan.candidates.append(candidate)
            }
        case .missing:
            break
        case .failed:
            scan.deferred = true
            scan.failed = true
        }
        return scan
    }

    func probeWindow(
        _ window: AXUIElement,
        app: NSRunningApplication,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot
    ) -> WindowProbe {
        var deferred = false
        var excluded = false
        var minimizedKeys: [MinimizedWindowKey] = []
        let candidate = windowCandidate(
            window,
            app: app,
            screens: screens,
            snapshot: snapshot,
            scanIndex: 0,
            hasDeferredCandidates: &deferred,
            minimizedKeys: &minimizedKeys,
            excludedByPolicy: &excluded
        )
        return WindowProbe(
            candidate: candidate,
            deferred: deferred,
            isMinimized: !minimizedKeys.isEmpty,
            isExcluded: excluded
        )
    }

    func resolvedWindow(
        from candidate: ManagedWindowCandidate,
        snapshot: OnScreenWindowSnapshot,
        excludingNumbers: Set<Int>,
        isSignatureUnique: Bool,
        identityRegistry: inout WindowIdentityRegistry,
        avoidingIdentities: Set<WindowIdentity>,
        knownStateKey: (WindowIdentity) -> String?,
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo
    ) -> (window: ManagedWindow, isNewlyCreated: Bool)? {
        var visible = candidate
        if let number = candidate.windowNumber {
            guard snapshot.visibleNumbersByPID[candidate.pid]?.contains(number) == true else { return nil }
        } else {
            guard let matched = snapshot.matchWindowNumber(
                pid: candidate.pid,
                frame: candidate.frame,
                title: candidate.title,
                excluding: excludingNumbers
            ) else {
                return nil
            }
            visible.windowNumber = matched
        }
        if let number = visible.windowNumber {
            visible.orderRank = snapshot.rankByWindow[WindowOrderKey(pid: candidate.pid, number: number)]
        }
        let resolution = managedWindows(
            from: [visible],
            signatureCounts: visible.signature.map { [$0: isSignatureUnique ? 1 : 2] } ?? [:],
            identityRegistry: &identityRegistry,
            knownStateKey: knownStateKey,
            screenForKnownStateKey: screenForKnownStateKey,
            avoidingIdentities: avoidingIdentities
        )
        guard let window = resolution.windows.first else { return nil }
        return (window, resolution.newlyCreatedIDs.contains(window.id))
    }

    private func windowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int,
        hasDeferredCandidates: inout Bool,
        minimizedKeys: inout [MinimizedWindowKey],
        excludedByPolicy: inout Bool
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
                scanIndex: scanIndex,
                minimizedKeys: &minimizedKeys,
                excludedByPolicy: &excludedByPolicy
            )
        }
        return newWindowCandidate(
            window,
            app: app,
            elementKey: elementKey,
            screens: screens,
            snapshot: snapshot,
            scanIndex: scanIndex,
            hasDeferredCandidates: &hasDeferredCandidates,
            minimizedKeys: &minimizedKeys,
            excludedByPolicy: &excludedByPolicy
        )
    }

    private func knownWindowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        cached: WindowElementMetadataCache.Entry,
        elementKey: WindowElementKey,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int,
        minimizedKeys: inout [MinimizedWindowKey],
        excludedByPolicy: inout Bool
    ) -> ManagedWindowCandidate? {
        let pid = app.processIdentifier
        let windowNumber = cached.windowNumber ?? AXReader.windowID(of: window)
        let dynamics = AXReader.multipleChecked(window, attributes: Self.knownWindowDynamicAttributes)
        var title: String?
        var document: String?
        if let dynamics {
            if case .value(true) = AXReader.boolReadFromBatch(dynamics[kAXMinimizedAttribute]) {
                minimizedKeys.append(MinimizedWindowKey(
                    elementKey: elementKey,
                    windowKey: windowNumber.map { WindowOrderKey(pid: pid, number: $0) }
                ))
                return nil
            }
            for flagAttribute in ["AXFullScreen", "AXModal"] {
                if case .value(true) = AXReader.boolReadFromBatch(dynamics[flagAttribute]) {
                    excludedByPolicy = true
                    return nil
                }
            }
            title = AXReader.stringFromBatch(dynamics[kAXTitleAttribute])
            document = AXReader.stringFromBatch(dynamics[kAXDocumentAttribute])
            if WindowManageabilityPlanner.isExcludedTitle(title) {
                excludedByPolicy = true
                return nil
            }
        }
        var frame: CGRect?
        if let number = windowNumber {
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
            if entry.windowNumber == nil {
                entry.windowNumber = windowNumber
            }
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

    private func newWindowCandidate(
        _ window: AXUIElement,
        app: NSRunningApplication,
        elementKey: WindowElementKey,
        screens: [ScreenInfo],
        snapshot: OnScreenWindowSnapshot,
        scanIndex: Int,
        hasDeferredCandidates: inout Bool,
        minimizedKeys: inout [MinimizedWindowKey],
        excludedByPolicy: inout Bool
    ) -> ManagedWindowCandidate? {
        let pid = app.processIdentifier
        guard let reads = AXReader.multipleChecked(window, attributes: Self.newWindowAttributes) else {
            hasDeferredCandidates = true
            return nil
        }

        if case .value(true) = AXReader.boolReadFromBatch(reads[kAXMinimizedAttribute]) {
            let number = AXReader.windowID(of: window)
                ?? AXReader.intFromBatch(reads["AXWindowNumber"])
                ?? AXReader.intFromBatch(reads["_AXWindowNumber"])
            minimizedKeys.append(MinimizedWindowKey(
                elementKey: elementKey,
                windowKey: number.map { WindowOrderKey(pid: pid, number: $0) }
            ))
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
            excludedByPolicy = true
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
            excludedByPolicy = true
            return nil
        case .unknown:
            hasDeferredCandidates = true
            return nil
        case .manageable:
            break
        }

        let windowNumber = AXReader.windowID(of: window)
            ?? AXReader.intFromBatch(reads["AXWindowNumber"])
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
        screenForKnownStateKey: (String, ScreenInfo) -> ScreenInfo,
        avoidingIdentities: Set<WindowIdentity> = []
    ) -> (windows: [ManagedWindow], newlyCreatedIDs: Set<WindowIdentity>) {
        var windows: [ManagedWindow] = []
        var seenIDs: Set<WindowIdentity> = avoidingIdentities
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

    static func shouldOrderBefore(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> Bool {
        ManagedWindow.shouldOrderBefore(lhs, rhs)
    }
}

struct ManagedWindowCandidate {
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
    var scanIndex: Int
}
