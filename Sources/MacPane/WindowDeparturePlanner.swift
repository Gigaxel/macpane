/// Decides what a managed window missing from the window listing means. Being missing proves
/// nothing on its own: a window is ordered out while it is minimized, hidden with its app, on a
/// Space that is not showing, and for a moment while it moves to or from a fullscreen Space, when
/// the WindowServer may report it on no Space at all. Only evidence that it closed ends its tile.
enum WindowDeparturePlanner {
    enum Verdict: Equatable {
        /// Closed: forget it.
        case gone
        /// Still there and out of view: it keeps its tile, which takes no space meanwhile.
        case hidden
        /// Announced closed but alive on another Space: its app rebuilt its element, so the
        /// announcement is void and the handle is dead.
        case rebuilt
    }

    /// - Parameters:
    ///   - exists: the WindowServer still describes the window.
    ///   - announcedClosing: its app reported its Accessibility element destroyed, at any point
    ///     since the window was last seen in view.
    ///   - isMinimized: the server tags it minimized, or hidden with its app.
    ///   - isHomeShowing: the Space of the window's own workspace is showing.
    ///   - spaces: the Spaces the server assigns it to. Empty when it is on none, which a closed
    ///     window an app keeps around and a window between Spaces both report.
    ///   - showingSpaces: the Spaces the displays are showing.
    static func verdict(
        exists: Bool,
        announcedClosing: Bool,
        isMinimized: Bool,
        isHomeShowing: Bool,
        spaces: [UInt64],
        showingSpaces: Set<UInt64>
    ) -> Verdict {
        guard exists else { return .gone }
        // An app rebuilding its element (some do around fullscreen) also announces a close, so
        // the announcement counts only for a window that is not out of view for another reason.
        // It counts once the window would be in view: a fullscreen Space showing in place of the
        // window's desktop is no place to judge it from.
        guard announcedClosing, !isMinimized, isHomeShowing else { return .hidden }
        let isOnAnotherSpace = !spaces.isEmpty && !spaces.contains(where: showingSpaces.contains)
        return isOnAnotherSpace ? .rebuilt : .gone
    }
}
