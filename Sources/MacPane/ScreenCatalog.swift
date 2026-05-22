import AppKit
import CoreGraphics

struct ScreenCatalog {
    private let activeWorkspaceIndexForNativeStateKey: (String) -> Int

    init(activeWorkspaceIndexForNativeStateKey: @escaping (String) -> Int) {
        self.activeWorkspaceIndexForNativeStateKey = activeWorkspaceIndexForNativeStateKey
    }

    func infosByKey() -> [String: ScreenInfo] {
        Dictionary(uniqueKeysWithValues: currentInfos().map { ($0.stateKey, $0) })
    }

    func currentInfos() -> [ScreenInfo] {
        NSScreen.screens.map(info(forScreen:))
    }

    func info(forScreen screen: NSScreen) -> ScreenInfo {
        let displayID = screen.displayID
        let displayKey = ScreenInfo.displayKey(for: displayID, frame: screen.frame)
        let nativeStateKey = ScreenInfo.nativeStateKey(displayKey: displayKey)
        return ScreenInfo(
            key: displayKey,
            frame: accessibilityVisibleFrame(for: screen),
            displayID: displayID,
            workspaceIndex: activeWorkspaceIndexForNativeStateKey(nativeStateKey)
        )
    }

    func screenContainingCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) }
    }

    func displayName(for screen: ScreenInfo) -> String {
        guard let displayID = screen.displayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            return "Current Display"
        }
        return screen.localizedName
    }

    func info(for windowRect: CGRect, screens: [ScreenInfo]) -> ScreenInfo {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if let bestIndex = ScreenGeometry.bestScreenIndex(for: windowRect, screens: screens.map(\.frame)) {
            return screens[bestIndex]
        }
        if let containingScreen = screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen
        }
        return screens.min { lhs, rhs in
            lhs.frame.distanceSquared(to: center) < rhs.frame.distanceSquared(to: center)
        } ?? ScreenInfo(
            key: "fallback",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            displayID: nil,
            workspaceIndex: 0
        )
    }

    func frameIntersectsAnyVisibleScreen(_ frame: CGRect, screens: [ScreenInfo]) -> Bool {
        screens.contains { $0.frame.intersects(frame) }
    }

    private func accessibilityVisibleFrame(for screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let displayBounds = screen.displayID.map { CGDisplayBounds($0) } ?? screenFrame
        let leftInset = visibleFrame.minX - screenFrame.minX
        let rightInset = screenFrame.maxX - visibleFrame.maxX
        let topInset = screenFrame.maxY - visibleFrame.maxY
        let bottomInset = visibleFrame.minY - screenFrame.minY
        return CGRect(
            x: displayBounds.minX + leftInset,
            y: displayBounds.minY + topInset,
            width: displayBounds.width - leftInset - rightInset,
            height: displayBounds.height - topInset - bottomInset
        )
    }
}
