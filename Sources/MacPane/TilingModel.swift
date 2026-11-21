import CoreGraphics

/// Where a tiled window should be right now.
enum Placement: Equatable {
    /// Visible in its tile.
    case tile(CGRect)
    /// On a workspace that is not showing: parked just off the corner of its display.
    case parked(ScreenInfo)
}

/// Everything MacPane decides about windows, with no system calls in it: which windows are managed,
/// which workspace each sits in, and which workspace every display is showing.
///
/// A window stays in its tree for as long as it exists. While it is minimized, hidden with its app
/// or in native fullscreen it simply takes no space, and it gets its tile back when it returns.
struct TilingModel {
    private(set) var windows: [WindowID: ManagedWindow] = [:]
    private(set) var trees: [WorkspaceKey: ScreenTileState] = [:]
    private(set) var floating: [WindowID: ScopeKey] = [:]
    private var activeIndices: [ScopeKey: Int] = [:]
    /// The workspace index each window had on a display that has since been unplugged.
    private var evacuated: [String: [WindowID: Int]] = [:]

    // MARK: Lookup

    func workspace(of id: WindowID) -> WorkspaceKey? {
        trees.first { $0.value.contains(id) }?.key
    }
    func isManaged(_ id: WindowID) -> Bool {
        windows[id] != nil
    }
    func activeIndex(in scope: ScopeKey) -> Int {
        activeIndices[scope] ?? 0
    }
    func activeKey(on screen: ScreenInfo) -> WorkspaceKey {
        screen.workspaceKey(index: activeIndex(in: screen.scope))
    }
    func isShowing(_ key: WorkspaceKey) -> Bool {
        activeIndex(in: key.scope) == key.index
    }
    /// True once a Space on a display has had a workspace chosen or a window tiled.
    func hasState(in scope: ScopeKey) -> Bool {
        activeIndices[scope] != nil || trees.keys.contains { $0.scope == scope }
    }
    /// The windows of a workspace that take no space right now.
    func hidden(in key: WorkspaceKey, onScreen: Set<WindowID>) -> Set<WindowID> {
        trees[key]?.windowIDs.subtracting(onScreen) ?? []
    }
    func minimumSizes(in key: WorkspaceKey) -> [WindowID: CGSize] {
        guard let state = trees[key] else { return [:] }
        var minimums: [WindowID: CGSize] = [:]
        for id in state.orderedIDs {
            guard let minimum = windows[id]?.minimumSize, minimum.width > 0 || minimum.height > 0 else { continue }
            minimums[id] = CGSize(
                width: max(minimum.width, TileLayout.minimumWindowFrameSize.width),
                height: max(minimum.height, TileLayout.minimumWindowFrameSize.height)
            )
        }
        return minimums
    }

    // MARK: Lifetime

    mutating func adoptTiled(
        _ window: ManagedWindow,
        in key: WorkspaceKey,
        near target: WindowID? = nil,
        onScreen: Set<WindowID>
    ) {
        windows[window.id] = window
        floating.removeValue(forKey: window.id)
        insert(window.id, in: key, near: target, onScreen: onScreen)
    }
    /// Adopts a window in place of one it replaces, which is forgotten: the new window takes over
    /// the old one's tile or floating state. Used for tabs, where switching swaps one window for
    /// another at the same spot.
    mutating func adopt(_ window: ManagedWindow, replacing old: WindowID) {
        guard windows[old] != nil, old != window.id else { return }
        windows[window.id] = window
        if let scope = floating[old] {
            floating[window.id] = scope
        } else if let key = workspace(of: old) {
            _ = trees[key]?.replace(old, with: window.id)
        }
        forget(old)
    }
    mutating func adoptFloating(_ window: ManagedWindow, in scope: ScopeKey) {
        windows[window.id] = window
        floating[window.id] = scope
    }
    mutating func forget(_ id: WindowID) {
        windows.removeValue(forKey: id)
        floating.removeValue(forKey: id)
        removeFromTrees(id)
        for display in Array(evacuated.keys) {
            evacuated[display]?.removeValue(forKey: id)
            if evacuated[display]?.isEmpty == true {
                evacuated.removeValue(forKey: display)
            }
        }
    }

    // MARK: Window facts

    mutating func setHandle(_ handle: WindowHandle, of id: WindowID) {
        windows[id]?.handle = handle
    }
    mutating func setTitle(_ title: String?, of id: WindowID) {
        windows[id]?.title = title
    }
    mutating func setMinimumSize(_ size: CGSize, of id: WindowID) {
        windows[id]?.minimumSize = size
    }
    mutating func clearAutoFloat(_ id: WindowID) {
        windows[id]?.autoFloatedAt = nil
    }

    // MARK: Tiled and floating

    mutating func float(_ id: WindowID, in scope: ScopeKey) {
        guard windows[id] != nil else { return }
        removeFromTrees(id)
        floating[id] = scope
    }
    mutating func tile(_ id: WindowID, in key: WorkspaceKey, near target: WindowID? = nil, onScreen: Set<WindowID>) {
        guard windows[id] != nil else { return }
        floating.removeValue(forKey: id)
        windows[id]?.autoFloatedAt = nil
        insert(id, in: key, near: target, onScreen: onScreen)
    }
    mutating func setFloatingScope(_ scope: ScopeKey, of id: WindowID) {
        guard floating[id] != nil else { return }
        floating[id] = scope
    }

    // MARK: Workspaces

    mutating func setActiveIndex(_ index: Int, in scope: ScopeKey) {
        activeIndices[scope] = max(0, index)
    }
    mutating func markFocused(_ id: WindowID) {
        guard let key = workspace(of: id) else { return }
        trees[key]?.markFocused(id)
    }
    /// Moves a tiled window to another workspace, splitting `target` or that workspace's last
    /// focused tile.
    mutating func move(
        _ id: WindowID,
        to key: WorkspaceKey,
        near target: WindowID? = nil,
        placement: TilePlacement = .automatic,
        onScreen: Set<WindowID>
    ) {
        guard windows[id] != nil, workspace(of: id) != key else { return }
        removeFromTrees(id)
        insert(id, in: key, near: target, placement: placement, onScreen: onScreen)
    }
    /// Applies an edit to one workspace's tree and reports whether it changed anything.
    @discardableResult
    mutating func edit(_ key: WorkspaceKey, _ body: (inout ScreenTileState) -> Bool) -> Bool {
        guard var state = trees[key] else { return false }
        guard body(&state) else { return false }
        trees[key] = state
        return true
    }
    func deletionBlockReason(index: Int, workspaceCount: Int) -> String? {
        guard workspaceCount > 1 else { return "Only Workspace" }
        guard index >= 0, index < workspaceCount else { return "Unavailable" }
        let hasTiledWindows = trees.contains { $0.key.index == index && !$0.value.isEmpty }
        let hasFloatingWindows = floating.values.contains { activeIndex(in: $0) == index }
        return hasTiledWindows || hasFloatingWindows ? "Not Empty" : nil
    }
    /// Removes an empty workspace everywhere and closes the gap in the numbering.
    mutating func deleteWorkspace(index: Int, workspaceCount: Int) {
        var shifted: [WorkspaceKey: ScreenTileState] = [:]
        for (key, state) in trees where key.index != index && !state.isEmpty {
            var key = key
            if key.index > index {
                key.index -= 1
            }
            shifted[key] = state
        }
        trees = shifted
        let lastIndex = max(workspaceCount - 2, 0)
        activeIndices = activeIndices.mapValues { active in
            min(max(active > index ? active - 1 : active, 0), lastIndex)
        }
        evacuated = evacuated.mapValues { indices in
            indices.mapValues { $0 > index ? $0 - 1 : min($0, lastIndex) }
        }
    }
    /// Folds every workspace into the one its display is showing, so nothing stays parked.
    mutating func mergeAllIntoActiveWorkspaces() {
        for (key, state) in trees where !isShowing(key) {
            let target = WorkspaceKey(scope: key.scope, index: activeIndex(in: key.scope))
            var merged = trees[target] ?? ScreenTileState()
            merged.merge(state, preferSourceFocus: false)
            trees[target] = merged
            trees.removeValue(forKey: key)
        }
        for key in Array(trees.keys) {
            trees[key]?.clearZoom()
        }
    }

    // MARK: Displays

    /// Moves the workspaces of unplugged displays onto a remaining one, keeping their indices, and
    /// puts them back when the display returns. `fallback` picks the display for some orphaned
    /// windows; it runs while the model is being changed, so it must not read the model. Returns
    /// the windows that were sent back to a returning display.
    @discardableResult
    mutating func reconcileDisplays(
        _ screens: [ScreenInfo],
        onScreen: Set<WindowID>,
        fallback: ([WindowID]) -> ScreenInfo?
    ) -> Set<WindowID> {
        let screensByKey = Dictionary(screens.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, state) in trees where screensByKey[key.display] == nil {
            guard let target = fallback(state.orderedIDs) else { continue }
            trees.removeValue(forKey: key)
            for id in state.orderedIDs {
                evacuated[key.display, default: [:]][id] = key.index
            }
            let targetKey = target.workspaceKey(index: key.index)
            var merged = trees[targetKey] ?? ScreenTileState()
            merged.merge(state, preferSourceFocus: false)
            trees[targetKey] = merged
        }
        for (id, scope) in floating where screensByKey[scope.display] == nil {
            if let target = fallback([id]) {
                floating[id] = target.scope
            }
        }
        var restored: Set<WindowID> = []
        for (display, indices) in evacuated {
            guard let screen = screensByKey[display], screen.isTileable else { continue }
            evacuated.removeValue(forKey: display)
            for (id, index) in indices.sorted(by: { $0.key < $1.key }) where workspace(of: id) != nil {
                move(id, to: screen.workspaceKey(index: index), onScreen: onScreen)
                restored.insert(id)
            }
        }
        return restored
    }

    // MARK: Layout

    /// Where every tiled window that is on screen belongs. Workspaces of Spaces that are not showing
    /// are left out: nothing about them can be seen or needs changing.
    func placements(screens: [ScreenInfo], onScreen: Set<WindowID>, gap: CGFloat) -> [WindowID: Placement] {
        var placements: [WindowID: Placement] = [:]
        for screen in screens where screen.isTileable {
            for (key, state) in trees where key.scope == screen.scope {
                let hidden = state.windowIDs.subtracting(onScreen)
                guard isShowing(key) else {
                    for id in state.orderedIDs where !hidden.contains(id) {
                        placements[id] = .parked(screen)
                    }
                    continue
                }
                let frames = state.frames(
                    in: screen.frame,
                    gap: gap,
                    accommodating: minimumSizes(in: key),
                    hidden: hidden
                )
                for (id, frame) in frames {
                    placements[id] = .tile(frame)
                }
            }
        }
        return placements
    }

    // MARK: Private

    private mutating func insert(
        _ id: WindowID,
        in key: WorkspaceKey,
        near target: WindowID?,
        placement: TilePlacement = .automatic,
        onScreen: Set<WindowID>
    ) {
        removeFromTrees(id)
        var state = trees[key] ?? ScreenTileState()
        state.insert(id, near: target, placement: placement, hidden: state.windowIDs.subtracting(onScreen))
        trees[key] = state
    }
    private mutating func removeFromTrees(_ id: WindowID) {
        for key in Array(trees.keys) where trees[key]?.contains(id) == true {
            trees[key]?.remove(id)
            if trees[key]?.isEmpty == true {
                trees.removeValue(forKey: key)
            }
        }
    }
}
