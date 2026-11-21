import AppKit
import ApplicationServices

/// Drives the real `WindowTiler` against real windows that this process opens, and checks the
/// frames the WindowServer reports. Only this process's windows are managed.
///
/// Everything is real except the last hop: a process cannot reach its own windows through
/// Accessibility, so `LocalApplicationPort` moves them with AppKit instead.
@main
@MainActor
struct IntegrationTests {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await Scenario().run()
                print("IntegrationTests passed")
                exit(0)
            } catch {
                fputs("IntegrationTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class Scenario {
    private let server = WindowServer.shared
    private let defaults: UserDefaults
    private let tiler: WindowTiler
    private let gap: CGFloat = 8
    private var windows: [NSWindow] = []
    private var timings: [(name: String, milliseconds: Double)] = []

    init() {
        let suite = "com.gigaxel.macpane.integration-tests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "accessibilityPrompted")
        defaults.set(false, forKey: "workspaceSwitchAnimationsEnabled")
        tiler = WindowTiler(
            environment: WindowTiler.Environment(
                isAccessibilityTrusted: { true },
                managesProcess: { $0 == getpid() },
                makePort: { _ in LocalApplicationPort() }
            ),
            settings: WindowTilerSettings(defaults: defaults)
        )
    }

    func run() async throws {
        tiler.start()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "com.gigaxel.macpane.integration-tests")
        }
        guard server.usesSkyLight else {
            try await runWithoutSkyLight()
            return
        }

        // New windows tile by splitting the most recent one.
        let a = openWindow("A")
        try await expect("first window fills the display", [(a, tile(0, 0, 1, 1))], timing: "open → tiled (1 window)")
        let b = openWindow("B")
        try await expect("second window splits the first", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timing: "open → tiled (2 windows)")
        let c = openWindow("C")
        try await expect("third window splits the second", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 0.5)), (c, tile(0.5, 0.5, 0.5, 0.5))
        ], timing: "open → tiled (3 windows)")

        // Closing promotes the sibling.
        mark()
        c.close()
        try await expect("closing a window gives its tile back", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timing: "close → retiled")

        // A minimized window keeps its place. (Not timed: AppKit runs the minimize animation on
        // the main thread of the app that owns the window, which here is the tiler's own.)
        b.miniaturize(nil)
        try await expect("minimizing gives the space to the sibling", [(a, tile(0, 0, 1, 1))], timeout: 4)
        b.deminiaturize(nil)
        try await expect("restoring returns the window to its tile", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timeout: 4)

        // Switching tabs swaps one window for another on the same tile.
        let tab = NSWindow(
            contentRect: b.contentRect(forFrameRect: b.frame),
            styleMask: b.styleMask,
            backing: .buffered,
            defer: false
        )
        tab.title = "B2"
        tab.isReleasedWhenClosed = false
        windows.append(tab)
        b.addTabbedWindow(tab, ordered: .above)
        b.tabGroup?.selectedWindow = tab
        try await expect("the second tab sits on the first tab's tile", [
            (a, tile(0, 0, 0.5, 1)), (tab, tile(0.5, 0, 0.5, 1))
        ], timeout: 3)
        // Swapping proves the tab itself is now the tiled window, not just sitting where B was.
        tiler.handle(action: .focus(.right))
        command(.swap(.left))
        try await expect("the tab took over the tile and moves with it", [
            (tab, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ], timeout: 3)
        b.tabGroup?.selectedWindow = b
        try await expect("switching back hands the tile to the first tab", [
            (b, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ], timeout: 3)
        command(.swap(.right))
        try await expect("and it moves with the tile too", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timeout: 3)
        tab.close()
        try await expect("closing the spare tab changes nothing", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ])

        // A hidden app's windows come back where they were.
        NSApp.hide(nil)
        try await pause(0.6)
        NSApp.unhideWithoutActivation()
        try await expect("unhiding restores every tile", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timeout: 4)

        // Keyboard commands. Focus picks the window the rest act on.
        tiler.handle(action: .focus(.left))
        command(.swap(.right))
        try await expect("swap exchanges the two tiles", [
            (a, tile(0.5, 0, 0.5, 1)), (b, tile(0, 0, 0.5, 1))
        ], timing: "swap → frames")
        command(.resize(.left))
        try await expect("resize moves the split", [
            (a, tile(0.445, 0, 0.555, 1)), (b, tile(0, 0, 0.445, 1))
        ], timing: "resize → frames")
        for _ in 0..<6 {
            tiler.handle(action: .resize(.left))
        }
        try await expect("held resize ends on the last step", [
            (a, tile(0.12, 0, 0.88, 1)), (b, tile(0, 0, 0.12, 1))
        ])
        command(.balance)
        try await expect("balance evens the split", [
            (a, tile(0.5, 0, 0.5, 1)), (b, tile(0, 0, 0.5, 1))
        ], timing: "balance → frames")
        command(.toggleOrientation)
        try await expect("rotate stacks the tiles", [
            (a, tile(0, 0.5, 1, 0.5)), (b, tile(0, 0, 1, 0.5))
        ], timing: "rotate → frames")
        command(.toggleOrientation)
        try await expect("rotate again restores the columns", [
            (a, tile(0.5, 0, 0.5, 1)), (b, tile(0, 0, 0.5, 1))
        ])
        command(.toggleZoom)
        try await expect("zoom fills the workspace", [(a, tile(0, 0, 1, 1)), (b, tile(0, 0, 0.5, 1))], timing: "zoom → frames")
        command(.toggleZoom)
        try await expect("unzoom returns the tile", [
            (a, tile(0.5, 0, 0.5, 1)), (b, tile(0, 0, 0.5, 1))
        ])

        // An app that moves its own window is put back.
        a.setFrameOrigin(NSPoint(x: a.frame.minX - 180, y: a.frame.minY - 60))
        let strayed = a.frame
        try await waitUntil("the stray move reaches the WindowServer", timeout: 2) { [self] in
            guard let screen = try? screenInfo(), let current = bounds(a) else { return false }
            return !FramePlanner.approximatelyEqual(current, tile(0.5, 0, 0.5, 1).frame(in: screen.frame, gap: gap, smartOuterGap: true))
                || a.frame != strayed
        }
        mark()
        try await expect("a window that moves itself returns to its tile", [
            (a, tile(0.5, 0, 0.5, 1)), (b, tile(0, 0, 0.5, 1))
        ], timing: "stray move → corrected")

        // Virtual workspaces park windows off the corner of the display.
        command(.moveWindowToWorkspace(1))
        try await expect("moving a window to another workspace parks it", [(b, tile(0, 0, 1, 1))], timing: "move to workspace → frames")
        try await expectParked(a, "the moved window waits off the corner")
        command(.switchWorkspace(1))
        try await expect("switching shows the other workspace", [(a, tile(0, 0, 1, 1))], timing: "switch workspace → frames")
        try await expectParked(b, "the previous workspace is parked")
        try expectEqual(tiler.workspaceMenuState.activeIndex, 1, "active workspace after switch")
        command(.switchWorkspace(0))
        try await expect("switching back restores the first workspace", [(b, tile(0, 0, 1, 1))])
        try await expectParked(a, "the second workspace is parked again")

        // The same switch with the slide animation.
        tiler.setWorkspaceSwitchAnimationsEnabled(true)
        command(.switchWorkspace(1))
        try await expect("an animated switch ends on the same frames", [(a, tile(0, 0, 1, 1))], timeout: 3, timing: "animated switch → settled")
        try await expectParked(b, "the outgoing workspace is parked after the slide")
        command(.cycleWorkspace(-1))
        command(.cycleWorkspace(1))
        command(.cycleWorkspace(-1))
        try await expect("switches chained mid-slide end on the last target", [(b, tile(0, 0, 1, 1))], timeout: 3)
        try await expectParked(a, "the other workspace is parked after chained slides")
        try expectEqual(tiler.workspaceMenuState.activeIndex, 0, "active workspace after chained switches")
        tiler.setWorkspaceSwitchAnimationsEnabled(false)

        // Bring both windows back onto one workspace.
        command(.switchWorkspace(1))
        try await expect("workspace 2 shows its window", [(a, tile(0, 0, 1, 1))])
        command(.moveWindowToWorkspace(0))
        command(.switchWorkspace(0))
        try await expect("a window moved back joins the tiles there", [
            (b, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ])

        // An app that refuses to go below a size gets that size, and its neighbors make room.
        let screen = try screenInfo()
        let minimumWidth = (screen.frame.width * 0.68).rounded()
        let d = openWindow("D", minimumSize: NSSize(width: minimumWidth, height: 300))
        try await waitUntil("a window with a large minimum is given room", timeout: 4) { [self] in
            guard let dBounds = bounds(d), let aBounds = bounds(a), let bBounds = bounds(b) else { return false }
            return dBounds.width >= minimumWidth - 1 &&
                abs(aBounds.width - dBounds.width) <= 2 &&
                bBounds.maxX <= dBounds.minX && bBounds.maxX <= aBounds.minX &&
                aBounds.maxY <= dBounds.minY
        }
        record("open → minimum accommodated")
        d.close()
        try await expect("closing it restores the even split", [
            (b, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ])

        // Small pop-ups float, and panels are never touched.
        let popup = openWindow("Popup", frame: NSRect(x: 420, y: 380, width: 300, height: 200))
        let popupFrame = popup.frame
        let panel = NSPanel(
            contentRect: NSRect(x: 300, y: 300, width: 240, height: 160),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        windows.append(panel)
        try await pause(0.5)
        try expectEqual(popup.frame, popupFrame, "a small pop-up stays where it opened")
        try await expect("pop-ups and panels leave the tiles alone", [
            (b, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ])
        popup.close()
        panel.close()

        // Quitting brings parked windows back.
        command(.moveWindowToWorkspace(2))
        try await expectParked(a, "a window on workspace 3 is parked")
        await stopTiler()
        try await waitUntil("stopping brings parked windows back on screen", timeout: 3) { [self] in
            guard let aBounds = bounds(a) else { return false }
            return screen.frame.contains(aBounds)
        }

        for window in windows {
            window.close()
        }
        print("")
        for timing in timings {
            print("  \(timing.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%7.2f ms", timing.milliseconds))")
        }
    }

    /// With `MACPANE_DISABLE_SKYLIGHT=1` the tiler runs on the public window list and a once-a-second
    /// check, as it would on a macOS release that dropped the private calls. Slower, same result.
    private func runWithoutSkyLight() async throws {
        let a = openWindow("A")
        try await expect("fallback: first window fills the display", [(a, tile(0, 0, 1, 1))], timeout: 5)
        let b = openWindow("B")
        try await expect("fallback: second window splits the first", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timeout: 5)
        b.miniaturize(nil)
        try await expect("fallback: minimizing gives the space to the sibling", [(a, tile(0, 0, 1, 1))], timeout: 6)
        b.deminiaturize(nil)
        try await expect("fallback: restoring returns the window to its tile", [
            (a, tile(0, 0, 0.5, 1)), (b, tile(0.5, 0, 0.5, 1))
        ], timeout: 6)
        command(.swap(.left))
        try await expect("fallback: swap exchanges the two tiles", [
            (b, tile(0, 0, 0.5, 1)), (a, tile(0.5, 0, 0.5, 1))
        ], timeout: 5)
        b.close()
        try await expect("fallback: closing gives the tile back", [(a, tile(0, 0, 1, 1))], timeout: 5)
        await stopTiler()
        for window in windows {
            window.close()
        }
    }

    /// The app stops the tiler from a menu action or `applicationWillTerminate`, which run straight
    /// off the run loop. This test body runs on the main dispatch queue instead, and that queue is
    /// not serviced re-entrantly, so the stop is handed to the run loop the same way.
    private func stopTiler() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [tiler] in
                tiler.stop()
                continuation.resume()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    // MARK: - Windows

    private func openWindow(_ title: String, frame: NSRect? = nil, minimumSize: NSSize? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: frame ?? NSRect(x: 160 + windows.count * 40, y: 220, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        if let minimumSize {
            window.minSize = minimumSize
        }
        mark()
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func bounds(_ window: NSWindow) -> CGRect? {
        server.bounds(of: WindowID(window.windowNumber))
    }

    private func screenInfo() throws -> ScreenInfo {
        guard let screen = ScreenCatalog.current(server: server).first(where: { $0.displayID == CGMainDisplayID() })
            ?? ScreenCatalog.current(server: server).first else {
            throw Failure(description: "no display")
        }
        return screen
    }

    private func tile(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> TileSlot {
        TileSlot(x: x, y: y, width: width, height: height)
    }

    // MARK: - Expectations

    private var markedAt = PerformanceTrace.now()

    private func mark() {
        markedAt = PerformanceTrace.now()
    }

    private func command(_ action: HotKeyAction) {
        mark()
        tiler.handle(action: action)
    }

    private func record(_ name: String) {
        timings.append((name, PerformanceTrace.milliseconds(since: markedAt)))
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitUntil(_ message: String, timeout: Double, _ condition: () -> Bool) async throws {
        let start = PerformanceTrace.now()
        while !condition() {
            guard PerformanceTrace.milliseconds(since: start) < timeout * 1000 else {
                let state = windows.map { "\($0.title)=\(bounds($0).map { "\($0)" } ?? "off screen")" }.joined(separator: " ")
                throw Failure(description: "\(message)\n  windows: \(state)")
            }
            try await Task.sleep(nanoseconds: 500_000)
        }
    }

    /// Waits for every listed window to sit exactly on its tile.
    private func expect(
        _ message: String,
        _ expected: [(NSWindow, TileSlot)],
        timeout: Double = 2,
        timing: String? = nil
    ) async throws {
        // The usable area changes whenever the Dock does, so the tiles are worked out on every look.
        func frames() -> [(NSWindow, CGRect)] {
            guard let screen = try? screenInfo() else { return [] }
            return expected.map { ($0.0, $0.1.frame(in: screen.frame, gap: gap, smartOuterGap: true)) }
        }
        func isInPlace() -> Bool {
            let frames = frames()
            return !frames.isEmpty && frames.allSatisfy { window, frame in
                bounds(window).map { FramePlanner.approximatelyEqual($0, frame) } ?? false
            }
        }
        do {
            try await waitUntil(message, timeout: timeout, isInPlace)
        } catch {
            let wanted = frames().map { "\($0.0.title)=\($0.1)" }.joined(separator: " ")
            throw Failure(description: "\(error)\n  expected: \(wanted)")
        }
        if let timing {
            record(timing)
        }
        // Settled means it stays there: nothing may still be moving the windows.
        try await pause(0.12)
        try await waitUntil("\(message) (and stays there)", timeout: 1, isInPlace)
        print("ok  \(message)")
    }

    private func expectParked(_ window: NSWindow, _ message: String) async throws {
        let screen = try screenInfo()
        try await waitUntil(message, timeout: 3) { [self] in
            // One point of the window stays on the display's right edge. AppKit holds the title
            // bar clear of the Dock, so it may sit a little above the bottom corner.
            guard let current = bounds(window), let screen = try? screenInfo() else { return false }
            return abs(current.minX - (screen.frame.maxX - 1)) <= 1 && current.minY >= screen.frame.maxY - 64
        }
        try await pause(0.25)
        guard let settled = bounds(window), abs(settled.minX - (screen.frame.maxX - 1)) <= 1 else {
            throw Failure(description: "\(message): did not stay parked, now \(String(describing: bounds(window)))")
        }
        print("ok  \(message)")
    }

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw Failure(description: "\(message): expected \(expected), got \(actual)")
        }
    }
}
