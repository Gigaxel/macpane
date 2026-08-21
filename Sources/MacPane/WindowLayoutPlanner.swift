import CoreGraphics

struct WindowFrameAssignment {
    enum Kind: Equatable {
        case visibleTile
        case hiddenPark
    }

    let window: ManagedWindow
    let frame: CGRect
    let kind: Kind
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
        gapPixels: CGFloat,
        minimumSizesByID: [WindowIdentity: CGSize] = [:]
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
                    gapPixels: gapPixels,
                    minimumSizesByID: minimumSizesByID
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
                otherScreenFrames: currentScreens.filter { $0.key != screen.key }.map(\.frame),
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
        gapPixels: CGFloat,
        minimumSizesByID: [WindowIdentity: CGSize]
    ) -> [WindowFrameAssignment] {
        let slots = state.resolvedSlots(in: screen.frame, gap: gapPixels, accommodating: minimumSizesByID)
        return slots.compactMap { id, slot in
            guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { return nil }
            let frame = visibleFrame(
                for: id,
                slot: slot,
                state: state,
                screenFrame: screen.frame,
                gapPixels: gapPixels
            )
            return WindowFrameAssignment(window: window, frame: frame, kind: .visibleTile)
        }
    }

    static func visibleFrame(
        for id: WindowIdentity,
        slot: TileSlot,
        state: ScreenTileState,
        screenFrame: CGRect,
        gapPixels: CGFloat
    ) -> CGRect {
        let visibleSlot = id == state.zoomedWindowID
            ? TileSlot(x: 0, y: 0, width: 1, height: 1)
            : slot
        return visibleSlot.frame(in: screenFrame, gap: gapPixels, smartOuterGap: true)
    }

    private static func hiddenFrameAssignments(
        state: ScreenTileState,
        screen: ScreenInfo,
        otherScreenFrames: [CGRect],
        windowsByID: [WindowIdentity: ManagedWindow],
        floatingWindowIDs: Set<WindowIdentity>
    ) -> [WindowFrameAssignment] {
        state.windowIDs.compactMap { id in
            guard let window = windowsByID[id], !floatingWindowIDs.contains(id) else { return nil }
            let size = CGSize(
                width: max(window.frame.width, TileLayout.minimumWindowFrameSize.width),
                height: max(window.frame.height, TileLayout.minimumWindowFrameSize.height)
            )
            let frame = hiddenParkFrame(
                windowSize: size,
                screenFrame: screen.frame,
                otherScreenFrames: otherScreenFrames
            )
            return WindowFrameAssignment(window: window, frame: frame, kind: .hiddenPark)
        }
    }

    static func hiddenParkFrame(
        windowSize: CGSize,
        screenFrame: CGRect,
        otherScreenFrames: [CGRect]
    ) -> CGRect {
        let width = windowSize.width
        let height = windowSize.height
        let candidates = [
            CGRect(x: screenFrame.maxX - 1, y: screenFrame.maxY - 1, width: width, height: height),
            CGRect(x: screenFrame.minX - width + 1, y: screenFrame.maxY - 1, width: width, height: height),
            CGRect(x: screenFrame.maxX - width, y: screenFrame.maxY - 1, width: width, height: height),
            CGRect(x: screenFrame.maxX - 1, y: max(screenFrame.minY, screenFrame.maxY - height), width: width, height: height),
            CGRect(x: screenFrame.minX - width + 1, y: max(screenFrame.minY, screenFrame.maxY - height), width: width, height: height)
        ]
        let viable = candidates.filter { candidate in
            let onSource = candidate.intersection(screenFrame)
            return onSource.width > 0 && onSource.height > 0
        }
        if let clear = viable.first(where: { candidate in
            !otherScreenFrames.contains { candidate.intersects($0) }
        }) {
            return clear
        }
        let scored = viable.map { candidate in
            (candidate, otherScreenFrames.reduce(CGFloat(0)) { total, other in
                let overlap = candidate.intersection(other)
                return total + max(0, overlap.width) * max(0, overlap.height)
            })
        }
        return scored.min(by: { $0.1 < $1.1 })?.0 ?? candidates[0]
    }

}
