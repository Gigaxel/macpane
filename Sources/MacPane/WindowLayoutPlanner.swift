import CoreGraphics

struct WindowFrameAssignment {
    let window: ManagedWindow
    let frame: CGRect
}

struct WindowLayoutPlan {
    let assignments: [WindowFrameAssignment]
    let skippedIncompleteState: Bool
}

enum WindowLayoutPlanner {
    static func plan(
        windows: [ManagedWindow],
        screenStates: [String: ScreenTileState],
        currentScreens: [ScreenInfo],
        floatingWindowIDs: Set<WindowIdentity>,
        stateKeyLimit: Set<String>?,
        gapPixels: CGFloat
    ) -> WindowLayoutPlan {
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let screens = Dictionary(uniqueKeysWithValues: currentScreens.map { ($0.stateKey, $0) })
        let screensByNativeStateKey = Dictionary(currentScreens.map { ($0.nativeStateKey, $0) }, uniquingKeysWith: { first, _ in first })
        let activeStateKeys = Set(screens.keys)
        var assignments: [WindowFrameAssignment] = []
        var skippedIncompleteState = false

        for (screenKey, state) in statesToApply(screenStates, limitingTo: stateKeyLimit) {
            if activeStateKeys.contains(screenKey) {
                guard let screen = screens[screenKey] ?? windows.first(where: { $0.screen.stateKey == screenKey })?.screen else {
                    continue
                }
                guard hasCompleteWindowSet(state, windowsByID: windowsByID, floatingWindowIDs: floatingWindowIDs) else {
                    skippedIncompleteState = true
                    continue
                }
                assignments.append(contentsOf: visibleFrameAssignments(
                    state: state,
                    screen: screen,
                    windowsByID: windowsByID,
                    floatingWindowIDs: floatingWindowIDs,
                    gapPixels: gapPixels
                ))
                continue
            }

            let nativeStateKey = WorkspaceStateKeys.nativeStateKeyComponent(of: screenKey)
            guard let screen = screensByNativeStateKey[nativeStateKey] ?? windows.first(where: { $0.screen.stateKey == screenKey })?.screen else {
                continue
            }
            assignments.append(contentsOf: hiddenFrameAssignments(
                state: state,
                screen: screen,
                windowsByID: windowsByID,
                floatingWindowIDs: floatingWindowIDs
            ))
        }

        return WindowLayoutPlan(
            assignments: assignments,
            skippedIncompleteState: skippedIncompleteState
        )
    }

    private static func statesToApply(
        _ screenStates: [String: ScreenTileState],
        limitingTo stateKeyLimit: Set<String>?
    ) -> [(key: String, state: ScreenTileState)] {
        if let stateKeyLimit {
            return stateKeyLimit.compactMap { key in
                guard let state = screenStates[key], !state.isEmpty else { return nil }
                return (key: key, state: state)
            }
        }
        return screenStates.compactMap { key, state in
            state.isEmpty ? nil : (key: key, state: state)
        }
    }

    private static func hasCompleteWindowSet(
        _ state: ScreenTileState,
        windowsByID: [WindowIdentity: ManagedWindow],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> Bool {
        state.windowIDs.allSatisfy { id in
            windowsByID[id] != nil || floatingWindowIDs.contains(id)
        }
    }

    private static func visibleFrameAssignments(
        state: ScreenTileState,
        screen: ScreenInfo,
        windowsByID: [WindowIdentity: ManagedWindow],
        floatingWindowIDs: Set<WindowIdentity>,
        gapPixels: CGFloat
    ) -> [WindowFrameAssignment] {
        state.slots.compactMap { id, slot in
            guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { return nil }
            let frame = slot.frame(in: screen.frame, gap: gapPixels, smartOuterGap: true)
            return WindowFrameAssignment(window: window, frame: frame)
        }
    }

    private static func hiddenFrameAssignments(
        state: ScreenTileState,
        screen: ScreenInfo,
        windowsByID: [WindowIdentity: ManagedWindow],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> [WindowFrameAssignment] {
        state.windowIDs.compactMap { id in
            guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { return nil }
            return WindowFrameAssignment(window: window, frame: hiddenFrame(for: window, on: screen))
        }
    }

    private static func hiddenFrame(for window: ManagedWindow, on screen: ScreenInfo) -> CGRect {
        let size = CGSize(
            width: max(window.frame.width, TileLayout.minimumWindowFrameSize.width),
            height: max(window.frame.height, TileLayout.minimumWindowFrameSize.height)
        )
        return CGRect(
            x: screen.frame.maxX - 1,
            y: screen.frame.maxY - 1,
            width: size.width,
            height: size.height
        )
    }

}
