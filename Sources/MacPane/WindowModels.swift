import AppKit
import ApplicationServices

struct CGWindowRecord {
    let pid: pid_t
    let number: Int
    let frame: CGRect
    let title: String?
    let rank: Int
}
struct OnScreenWindowSnapshot {
    var recordsByPID: [pid_t: [CGWindowRecord]] = [:]
    var visibleNumbersByPID: [pid_t: Set<Int>] = [:]
    var rankByWindow: [WindowOrderKey: Int] = [:]
    func matchWindowNumber(pid: pid_t, frame: CGRect, title: String?, excluding excludedNumbers: Set<Int>) -> Int? {
        guard let records = recordsByPID[pid], !records.isEmpty else { return nil }
        let normalizedTitle = normalizedWindowTitle(title)
        var best: (number: Int, score: CGFloat)?
        for record in records where !excludedNumbers.contains(record.number) {
            let frameScore = record.frame.frameSimilarityScore(to: frame)
            guard frameScore <= 24 else { continue }
            let recordTitle = normalizedWindowTitle(record.title)
            var score = frameScore
            if !normalizedTitle.isEmpty, !recordTitle.isEmpty, normalizedTitle != recordTitle {
                score += 20
            } else if normalizedTitle.isEmpty || recordTitle.isEmpty {
                score += 4
            }
            score += CGFloat(record.rank) * 0.001
            if best == nil || score < best!.score {
                best = (record.number, score)
            }
        }
        return best?.number
    }
    private func normalizedWindowTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct VisibleWindowSignature: Equatable {
    let visibleNumbersByPID: [pid_t: Set<Int>]
    init() {
        visibleNumbersByPID = [:]
    }
    init(snapshot: OnScreenWindowSnapshot) {
        visibleNumbersByPID = snapshot.visibleNumbersByPID.filter { !$0.value.isEmpty }
    }
}
struct ScreenInfo {
    static let workspaceStateSeparator = ":workspace:"
    let key: String
    let frame: CGRect
    let displayID: CGDirectDisplayID?
    let workspaceIndex: Int
    private let stateKeyOverride: String?
    init(
        key: String,
        frame: CGRect,
        displayID: CGDirectDisplayID?,
        workspaceIndex: Int,
        stateKeyOverride: String? = nil
    ) {
        self.key = key
        self.frame = frame
        self.displayID = displayID
        self.workspaceIndex = workspaceIndex
        self.stateKeyOverride = stateKeyOverride
    }
    var nativeStateKey: String {
        Self.nativeStateKey(displayKey: key)
    }
    var stateKey: String {
        stateKeyOverride ?? Self.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: workspaceIndex)
    }
    func withStateKeyOverride(_ stateKey: String) -> ScreenInfo {
        ScreenInfo(
            key: key,
            frame: frame,
            displayID: displayID,
            workspaceIndex: Self.workspaceIndex(from: stateKey) ?? workspaceIndex,
            stateKeyOverride: stateKey
        )
    }
    func withoutStateKeyOverride() -> ScreenInfo {
        ScreenInfo(
            key: key,
            frame: frame,
            displayID: displayID,
            workspaceIndex: workspaceIndex
        )
    }
    static func nativeStateKey(displayKey: String) -> String {
        displayKey
    }
    static func workspaceStateKey(nativeStateKey: String, workspaceIndex: Int) -> String {
        "\(nativeStateKey)\(workspaceStateSeparator)\(workspaceIndex)"
    }
    static func workspaceIndex(from stateKey: String) -> Int? {
        guard let range = stateKey.range(of: workspaceStateSeparator) else { return nil }
        return Int(stateKey[range.upperBound...])
    }
    static func displayKey(for displayID: CGDirectDisplayID?, frame: CGRect?) -> String {
        if let displayID { return "display:\(displayID)" }
        if let frame { return "frame:\(frame.debugDescription)" }
        return "display:unknown"
    }
}
struct ManagedWindow {
    let id: WindowIdentity
    let windowNumber: Int?
    let element: AXUIElement
    let screen: ScreenInfo
    let layoutIdentity: WindowLayoutIdentity?
    let frame: CGRect
    let bundleIdentifier: String?
    let title: String?
    let orderRank: Int?
    let scanIndex: Int
    func withFrame(_ frame: CGRect) -> ManagedWindow {
        ManagedWindow(
            id: id,
            windowNumber: windowNumber,
            element: element,
            screen: screen,
            layoutIdentity: layoutIdentity,
            frame: frame,
            bundleIdentifier: bundleIdentifier,
            title: title,
            orderRank: orderRank,
            scanIndex: scanIndex
        )
    }
}
struct PersistedScreenLayout {
    let stateKey: String
    let displayKey: String
    let tree: BSPTree<Int>
    let entriesByID: [Int: PersistedWindowLayoutEntry]
    let lastFocusedEntryID: Int?
    let lastUpdated: Date
}
struct PersistedWindowLayoutEntry {
    let id: Int
    let pid: pid_t
    let bundleIdentifier: String?
    let layoutIdentity: WindowLayoutIdentity?
    let orderRank: Int?
    let scanIndex: Int
}
struct PersistedWindowGroupKey: Hashable {
    let pid: pid_t
    let bundleIdentifier: String?
}
struct SystemUIWindowSnapshot: Equatable {
    let idsByStateKey: [String: Set<WindowIdentity>]
    let framesByID: [WindowIdentity: RoundedWindowFrame]
    init(windows: [ManagedWindow]) {
        idsByStateKey = Dictionary(grouping: windows, by: { $0.screen.stateKey })
            .mapValues { Set($0.map(\.id)) }
        framesByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, RoundedWindowFrame($0.frame)) })
    }
}
struct RoundedWindowFrame: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    init(_ frame: CGRect) {
        x = Int(frame.minX.rounded(.toNearestOrAwayFromZero))
        y = Int(frame.minY.rounded(.toNearestOrAwayFromZero))
        width = Int(frame.width.rounded(.toNearestOrAwayFromZero))
        height = Int(frame.height.rounded(.toNearestOrAwayFromZero))
    }
}
final class AppObserverRegistration {
    let observer: AXObserver
    let source: CFRunLoopSource
    var observedWindowTokens: Set<String> = []
    init(observer: AXObserver, source: CFRunLoopSource) {
        self.observer = observer
        self.source = source
    }
}
struct ScreenTileState {
    private var tree = BSPTree<WindowIdentity>()
    private var lastFocusedID: WindowIdentity?
    init() {}
    init(tree: BSPTree<WindowIdentity>, lastFocusedID: WindowIdentity? = nil) {
        self.tree = tree
        self.lastFocusedID = lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
    }
    var isEmpty: Bool { tree.isEmpty }
    var slots: [WindowIdentity: TileSlot] { tree.slots() }
    var slotList: [(id: WindowIdentity, slot: TileSlot)] { tree.slotList() }
    var tileCount: Int { tree.tileCount }
    var windowIDs: Set<WindowIdentity> { Set(tree.ids) }
    var focusedWindowID: WindowIdentity? {
        lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
    }
    var lastFocusedOrLargestID: WindowIdentity? {
        lastFocusedID.flatMap { tree.contains($0) ? $0 : nil } ?? tree.largestLeafID() ?? tree.firstID
    }
    func contains(_ id: WindowIdentity) -> Bool {
        tree.contains(id)
    }
    mutating func replaceWindowIDs(_ replacements: [WindowIdentity: WindowIdentity]) -> Bool {
        guard tree.replaceIDs(replacements) else { return false }
        if let lastFocusedID, let replacement = replacements[lastFocusedID] {
            self.lastFocusedID = replacement
        }
        return true
    }
    func compactMapWindowIDs<NewID: Hashable>(_ transform: (WindowIdentity) -> NewID?) -> BSPTree<NewID>? {
        tree.compactMapIDs(transform)
    }
    mutating func sync(windowIDs: [WindowIdentity], focusedID: WindowIdentity?) {
        let liveIDs = Set(windowIDs)
        tree.removeMissing(keeping: liveIDs)
        let existingIDs = Set(tree.ids)
        var target = focusedID.flatMap { existingIDs.contains($0) ? $0 : nil }
            ?? lastFocusedID.flatMap { existingIDs.contains($0) ? $0 : nil }
            ?? tree.largestLeafID()
            ?? tree.firstID
        for id in windowIDs where !existingIDs.contains(id) {
            tree.insert(id, near: target, placement: .automatic)
            target = id
        }
        if let focusedID, liveIDs.contains(focusedID) {
            markFocused(focusedID)
        } else if let lastFocusedID, liveIDs.contains(lastFocusedID) {
            markFocused(lastFocusedID)
        } else if let target, liveIDs.contains(target) {
            markFocused(target)
        } else if let first = tree.firstID {
            markFocused(first)
        } else {
            lastFocusedID = nil
        }
    }
    mutating func removeMissing(keeping liveIDs: Set<WindowIdentity>) {
        tree.removeMissing(keeping: liveIDs)
        if let lastFocusedID, !tree.contains(lastFocusedID) {
            self.lastFocusedID = tree.firstID
        }
    }
    mutating func insertExisting(_ id: WindowIdentity, near targetID: WindowIdentity?, placement: TilePlacement) {
        let target = targetID.flatMap { tree.contains($0) ? $0 : nil } ?? lastFocusedOrLargestID
        tree.insert(id, near: target, placement: placement)
        markFocused(id)
    }
    mutating func merge(_ source: ScreenTileState, preferSourceFocus: Bool) {
        guard !source.isEmpty else { return }
        guard !isEmpty else {
            self = source
            return
        }
        let preservedFocus = focusedWindowID
        var insertionTarget = lastFocusedOrLargestID
        for item in source.slotList {
            guard !tree.contains(item.id) else { continue }
            tree.insert(item.id, near: insertionTarget, placement: .automatic)
            insertionTarget = item.id
        }
        if preferSourceFocus, let sourceFocus = source.focusedWindowID ?? source.lastFocusedOrLargestID {
            markFocusedIfKnown(sourceFocus)
        } else if let preservedFocus {
            markFocusedIfKnown(preservedFocus)
        } else if let insertionTarget {
            markFocusedIfKnown(insertionTarget)
        }
    }
    mutating func remove(_ id: WindowIdentity) {
        tree.remove(id)
        if lastFocusedID == id {
            lastFocusedID = tree.firstID
        }
    }
    func neighborID(from focusedID: WindowIdentity, direction: SnapDirection) -> WindowIdentity? {
        tree.neighborID(from: focusedID, direction: direction)
    }
    mutating func markFocused(_ focusedID: WindowIdentity) {
        guard tree.contains(focusedID) else { return }
        lastFocusedID = focusedID
    }
    mutating func markFocusedIfKnown(_ focusedID: WindowIdentity) {
        guard tree.contains(focusedID) else { return }
        markFocused(focusedID)
    }
    mutating func swapFocused(_ focusedID: WindowIdentity, direction: SnapDirection) -> Bool {
        guard let neighborID = tree.neighborID(from: focusedID, direction: direction),
              tree.swap(focusedID, neighborID) else {
            return false
        }
        markFocused(focusedID)
        return true
    }
    mutating func resizeFocused(_ focusedID: WindowIdentity, direction: SnapDirection) -> Bool {
        guard tree.resize(focusedID: focusedID, direction: direction) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func reflectResize(focusedID: WindowIdentity, observedSlot: TileSlot) -> Bool {
        guard tree.reflectResize(focusedID: focusedID, observedSlot: observedSlot) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func toggleOrientation(focusedID: WindowIdentity) -> Bool {
        guard tree.toggleOrientation(focusedID: focusedID) else { return false }
        markFocused(focusedID)
        return true
    }
    mutating func move(_ id: WindowIdentity, onto target: WindowIdentity, placement: TilePlacement) -> Bool {
        guard tree.move(id, onto: target, placement: placement) else { return false }
        markFocused(id)
        return true
    }
    mutating func balance() {
        tree.balance()
        if let lastFocusedID, tree.contains(lastFocusedID) {
            markFocused(lastFocusedID)
        }
    }
    mutating func limitTileCount(to maxCount: Int) -> [WindowIdentity] {
        let removed = tree.limitTileCount(to: maxCount)
        if let lastFocusedID, !tree.contains(lastFocusedID) {
            self.lastFocusedID = tree.firstID
        }
        return removed
    }
}
