import AppKit
import CoreGraphics

/// Reads the connected displays and the native Space each one is showing. Nothing is kept between
/// calls: reading every display takes a few microseconds.
enum ScreenCatalog {
    static func current(server: WindowServer = .shared) -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            let key = displayKey(for: displayID)
            let space = server.currentSpace(ofDisplay: key)
            return ScreenInfo(
                key: key,
                displayID: displayID,
                frame: usableFrame(of: screen, displayID: displayID),
                bounds: CGDisplayBounds(displayID),
                space: space?.id ?? 0,
                isTileable: space?.isUser ?? true
            )
        }
    }

    static func displayKey(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else {
            return "display:\(displayID)"
        }
        return string
    }

    static func displayName(for screen: ScreenInfo) -> String {
        NSScreen.screens.first { $0.displayID == screen.displayID }?.localizedName ?? "Current Display"
    }

    static func nsScreen(for screen: ScreenInfo) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == screen.displayID }
    }

    /// The pointer in the global top-left coordinates the WindowServer and Accessibility use.
    static func cursorLocation() -> CGPoint {
        if let location = CGEvent(source: nil)?.location {
            return location
        }
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    static func screen(containing point: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first { $0.bounds.contains(point) }
            ?? screens.min { $0.bounds.distanceSquared(to: point) < $1.bounds.distanceSquared(to: point) }
    }

    /// The display a frame belongs on: the one it overlaps most, else the nearest.
    static func screen(for frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        if let index = ScreenGeometry.bestScreenIndex(for: frame, screens: screens.map(\.bounds)) {
            return screens[index]
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { $0.bounds.distanceSquared(to: center) < $1.bounds.distanceSquared(to: center) }
    }

    /// AppKit measures from the bottom-left of the primary display; windows are placed in top-left
    /// coordinates. The insets are the same either way, so they are applied to the display bounds.
    private static func usableFrame(of screen: NSScreen, displayID: CGDirectDisplayID) -> CGRect {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let bounds = CGDisplayBounds(displayID)
        let leftInset = visibleFrame.minX - screenFrame.minX
        let rightInset = screenFrame.maxX - visibleFrame.maxX
        let topInset = screenFrame.maxY - visibleFrame.maxY
        let bottomInset = visibleFrame.minY - screenFrame.minY
        return CGRect(
            x: bounds.minX + leftInset,
            y: bounds.minY + topInset,
            width: bounds.width - leftInset - rightInset,
            height: bounds.height - topInset - bottomInset
        )
    }
}
