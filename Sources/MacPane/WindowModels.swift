import ApplicationServices
import CoreGraphics

/// A display together with the native Space it is currently showing.
struct ScreenInfo: Equatable {
    /// Display UUID. Unlike `CGDirectDisplayID` it survives reconnects and sleep.
    let key: String
    let displayID: CGDirectDisplayID
    /// Usable area in global top-left coordinates: the display minus the menu bar and Dock.
    let frame: CGRect
    /// Full display bounds in the same coordinates.
    let bounds: CGRect
    let space: UInt64
    /// False while the display shows a fullscreen or system Space, which is never tiled.
    let isTileable: Bool

    var scope: ScopeKey { ScopeKey(display: key, space: space) }
    func workspaceKey(index: Int) -> WorkspaceKey {
        WorkspaceKey(display: key, space: space, index: index)
    }
}

/// One native Space on one display: the unit that owns a set of virtual workspaces.
struct ScopeKey: Hashable {
    var display: String
    var space: UInt64
}

/// One virtual workspace. Each has its own tile tree.
struct WorkspaceKey: Hashable {
    var display: String
    var space: UInt64
    var index: Int

    var scope: ScopeKey { ScopeKey(display: display, space: space) }
    init(display: String, space: UInt64, index: Int) {
        self.display = display
        self.space = space
        self.index = index
    }
    init(scope: ScopeKey, index: Int) {
        self.init(display: scope.display, space: scope.space, index: index)
    }
}

/// A window MacPane manages. It exists from the moment Accessibility confirms the window is
/// manageable until the WindowServer reports the window gone.
struct ManagedWindow {
    let id: WindowID
    let pid: pid_t
    var handle: WindowHandle
    let bundleIdentifier: String?
    var title: String?
    /// The smallest size the app accepted when asked for less. Measured from the app's own answer
    /// to a frame write; zero in a dimension means no floor is known there.
    var minimumSize = CGSize.zero
    /// Set while the window floats only because it opened below the pop-up size limits.
    var autoFloatedAt: UInt64?
}

/// The tile tree of one virtual workspace, plus which of its windows was focused last and which
/// one, if any, is zoomed to fill the workspace.
struct ScreenTileState {
    private var tree = BSPTree<WindowID>()
    private var lastFocusedID: WindowID?
    private(set) var zoomedWindowID: WindowID?

    init() {}
    init(tree: BSPTree<WindowID>, lastFocusedID: WindowID? = nil, zoomedWindowID: WindowID? = nil) {
        self.tree = tree
        self.lastFocusedID = lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
        self.zoomedWindowID = zoomedWindowID.flatMap { tree.contains($0) ? $0 : nil }
    }

    var isEmpty: Bool { tree.isEmpty }
    var orderedIDs: [WindowID] { tree.ids }
    var windowIDs: Set<WindowID> { Set(tree.ids) }
    var focusedWindowID: WindowID? {
        lastFocusedID.flatMap { tree.contains($0) ? $0 : nil }
    }
    func contains(_ id: WindowID) -> Bool {
        tree.contains(id)
    }

    // MARK: Layout

    /// The unit-square slot of every visible window, grown where needed to respect app minimums.
    func resolvedSlots(
        in screenFrame: CGRect,
        gap: CGFloat,
        accommodating minimums: [WindowID: CGSize] = [:],
        hidden: Set<WindowID> = []
    ) -> [WindowID: TileSlot] {
        tree.slotsAccommodating(minimums: minimums, in: screenFrame, gap: gap, hidden: hidden)
    }
    /// Frames for every visible window. A zoomed window covers the workspace; the rest keep their
    /// tiles underneath it.
    func frames(
        in screenFrame: CGRect,
        gap: CGFloat,
        accommodating minimums: [WindowID: CGSize] = [:],
        hidden: Set<WindowID> = []
    ) -> [WindowID: CGRect] {
        resolvedSlots(in: screenFrame, gap: gap, accommodating: minimums, hidden: hidden)
            .reduce(into: [WindowID: CGRect]()) { frames, entry in
                let slot = entry.key == zoomedWindowID ? TileSlot(x: 0, y: 0, width: 1, height: 1) : entry.value
                frames[entry.key] = slot.frame(in: screenFrame, gap: gap, smartOuterGap: true)
            }
    }
    func focusTarget(hidden: Set<WindowID> = []) -> WindowID? {
        if let lastFocusedID, tree.contains(lastFocusedID), !hidden.contains(lastFocusedID) {
            return lastFocusedID
        }
        return tree.largestLeafID(hidden: hidden)
    }
    func neighborID(from focusedID: WindowID, direction: SnapDirection, hidden: Set<WindowID> = []) -> WindowID? {
        tree.neighborID(from: focusedID, direction: direction, hidden: hidden)
    }

    // MARK: Membership

    /// Adds a window by splitting `targetID`'s tile, or the last focused or largest visible tile.
    mutating func insert(
        _ id: WindowID,
        near targetID: WindowID? = nil,
        placement: TilePlacement = .automatic,
        hidden: Set<WindowID> = []
    ) {
        guard !tree.contains(id) else { return }
        let target = targetID.flatMap { tree.contains($0) && !hidden.contains($0) ? $0 : nil }
            ?? focusTarget(hidden: hidden)
        tree.insert(id, near: target, placement: placement, hidden: hidden)
        zoomedWindowID = nil
        lastFocusedID = id
    }
    /// Hands a window's tile, focus and zoom to another window.
    mutating func replace(_ id: WindowID, with replacement: WindowID) -> Bool {
        guard tree.replace(id, with: replacement) else { return false }
        if lastFocusedID == id {
            lastFocusedID = replacement
        }
        if zoomedWindowID == id {
            zoomedWindowID = replacement
        }
        return true
    }
    mutating func remove(_ id: WindowID) {
        guard tree.contains(id) else { return }
        tree.remove(id)
        if lastFocusedID == id {
            lastFocusedID = nil
        }
        if zoomedWindowID == id {
            zoomedWindowID = nil
        }
    }
    /// Appends another workspace's windows, keeping this one's shape.
    mutating func merge(_ source: ScreenTileState, preferSourceFocus: Bool) {
        guard !source.isEmpty else { return }
        guard !isEmpty else {
            self = source
            return
        }
        let preservedFocus = focusedWindowID
        for id in source.orderedIDs where !tree.contains(id) {
            insert(id)
        }
        if preferSourceFocus, let sourceFocus = source.focusedWindowID {
            markFocused(sourceFocus)
        } else if let preservedFocus {
            markFocused(preservedFocus)
        }
    }
    mutating func markFocused(_ id: WindowID) {
        guard tree.contains(id) else { return }
        lastFocusedID = id
    }

    // MARK: Edits

    @discardableResult
    mutating func toggleZoom(_ id: WindowID) -> Bool {
        guard tree.contains(id) else { return false }
        zoomedWindowID = zoomedWindowID == id ? nil : id
        return true
    }
    @discardableResult
    mutating func clearZoom() -> Bool {
        guard zoomedWindowID != nil else { return false }
        zoomedWindowID = nil
        return true
    }
    mutating func swap(_ id: WindowID, direction: SnapDirection, hidden: Set<WindowID> = []) -> Bool {
        guard let neighborID = tree.neighborID(from: id, direction: direction, hidden: hidden),
              tree.swap(id, neighborID) else {
            return false
        }
        markFocused(id)
        return true
    }
    mutating func resize(_ id: WindowID, direction: SnapDirection, hidden: Set<WindowID> = []) -> Bool {
        guard tree.resize(focusedID: id, direction: direction, hidden: hidden) else { return false }
        markFocused(id)
        return true
    }
    mutating func reflectResize(_ id: WindowID, observedSlot: TileSlot, hidden: Set<WindowID> = []) -> Bool {
        guard tree.reflectResize(focusedID: id, observedSlot: observedSlot, hidden: hidden) else { return false }
        markFocused(id)
        return true
    }
    mutating func toggleOrientation(_ id: WindowID, hidden: Set<WindowID> = []) -> Bool {
        guard tree.toggleOrientation(focusedID: id, hidden: hidden) else { return false }
        markFocused(id)
        return true
    }
    mutating func move(
        _ id: WindowID,
        onto target: WindowID,
        placement: TilePlacement,
        hidden: Set<WindowID> = []
    ) -> Bool {
        guard tree.move(id, onto: target, placement: placement, hidden: hidden) else { return false }
        markFocused(id)
        return true
    }
    mutating func balance() {
        tree.balance()
    }
}
