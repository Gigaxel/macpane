import ApplicationServices
import CoreGraphics
import Foundation

@main
struct TilingTests {
    static func main() {
        testTreeInsertionSplitsFocusedTile()
        testRemovalPromotesSibling()
        testDirectionalNeighborAndSwap()
        testResizeMovesContainingSplitFromEitherSideOnBothAxes()
        testResizeIsLocalToContainingSplit()
        testExplicitDropPlacement()
        testToggleOrientation()
        testBalancePreservesWindows()
        testGaps()
        testScreenGeometryChoosesLargestIntersection()

        testHiddenLeafGivesItsSlotToItsSibling()
        testHiddenLeafGetsItsSlotBack()
        testHiddenSubtreeCollapsesThroughNestedSplits()
        testResizeSkipsSplitWithHiddenSide()
        testToggleOrientationSkipsSplitWithHiddenSide()
        testNeighborIgnoresHiddenWindows()
        testInsertSplitsAVisibleTile()

        testObservedSlotInvertsRenderedFrame()
        testObservedSlotReadsADraggedDivider()
        testReflectResizeMovesTheSharedSplit()

        testAccommodationGrowsConstrainedTile()
        testAccommodationInfeasibleFallsBackProportionally()
        testAccommodationIgnoresHiddenWindows()

        testStateZoomFillsWorkspaceAndClearsOnNewMember()
        testStateFocusTargetSkipsHiddenWindows()
        testStateMergeKeepsShapeAndFocus()

        testModelTilesNewWindowBesideLastFocused()
        testModelParksWindowsOfHiddenWorkspaces()
        testModelKeepsMinimizedWindowsPlace()
        testModelReplacementTakesOverTile()
        testModelIgnoresSpacesThatAreNotShowing()
        testModelKeepsTilesThroughFullscreenRoundTrip()
        testDepartureNeedsEvidenceOfClosing()
        testStateExchangeKeepsZoomAndFocusWithTheTile()
        testModelFloatAndTile()
        testModelMoveBetweenWorkspaces()
        testModelDeleteWorkspaceShiftsHigherWorkspaces()
        testModelDeletionRules()
        testModelMergeAllIntoActiveWorkspaces()
        testModelEvacuatesAndRestoresDisplay()
        testModelAccommodatesLearnedMinimum()
        testModelForgetRemovesEverywhere()

        testServerWindowStandardFilter()
        testWindowManageabilityPlannerFailsClosed()
        testFrameVerificationClassifierVerdicts()
        testSlidePlannerMovesOutgoingAndIncomingWindows()
        testSlidePlannerRefusesToCrossAnotherDisplay()
        testChainedSlideContinuesFromCurrentPosition()
        testChainedSlideSkipsAlreadyHiddenNonTargetWindows()
        testFocusNavigatorPicksNeighborByGeometry()
        testFocusNavigatorFindsAdjacentDisplays()
        testDropPlannerActions()
        testDropPlannerTarget()
        testParkOriginKeepsCornerOnSingleDisplay()
        testParkOriginAvoidsNeighboringDisplays()
        testParkOriginIsDeterministicWhenSurrounded()

        runFrameConvergenceTests()
        print("TilingTests passed")
    }

    // MARK: - Tree

    private static func testTreeInsertionSplitsFocusedTile() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.insert("C", near: "B")
        let slots = tree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "first window stays left")
        expectEqual(slots["B"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 0.5), "focused right tile becomes top")
        expectEqual(slots["C"]!, TileSlot(x: 0.5, y: 0.5, width: 0.5, height: 0.5), "new window becomes second child")
    }

    private static func testRemovalPromotesSibling() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.remove("B")
        expectEqual(tree.slots()["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 1), "sibling is promoted")
    }

    private static func testDirectionalNeighborAndSwap() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        guard tree.neighborID(from: "A", direction: .right) == "B", tree.swap("A", "B") else {
            fail("expected right neighbor and swap")
        }
        let slots = tree.slots()
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "neighbor moved into first tile")
        expectEqual(slots["A"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "focused moved into second tile")
    }

    private static func testResizeMovesContainingSplitFromEitherSideOnBothAxes() {
        func expectResize(
            focused: String,
            placement: TilePlacement,
            direction: SnapDirection,
            first: TileSlot,
            second: TileSlot,
            _ message: String
        ) {
            var tree = BSPTree<String>()
            tree.insert("A", near: nil)
            tree.insert("B", near: "A", placement: placement)
            guard tree.resize(focusedID: focused, direction: direction) else {
                fail("\(message): resize was refused")
            }
            expectEqual(tree.slots()["A"]!, first, "\(message): first child")
            expectEqual(tree.slots()["B"]!, second, "\(message): second child")
            guard tree.resize(focusedID: focused, direction: opposite(direction)) else {
                fail("\(message): resize back was refused")
            }
            let half = placement == .automatic
                ? (TileSlot(x: 0, y: 0, width: 0.5, height: 1), TileSlot(x: 0.5, y: 0, width: 0.5, height: 1))
                : (TileSlot(x: 0, y: 0, width: 1, height: 0.5), TileSlot(x: 0, y: 0.5, width: 1, height: 0.5))
            expectEqual(tree.slots()["A"]!, half.0, "\(message): first child returns to even split")
            expectEqual(tree.slots()["B"]!, half.1, "\(message): second child returns to even split")
        }
        expectResize(
            focused: "A", placement: .automatic, direction: .left,
            first: TileSlot(x: 0, y: 0, width: 0.445, height: 1),
            second: TileSlot(x: 0.445, y: 0, width: 0.555, height: 1),
            "left from the first child"
        )
        expectResize(
            focused: "B", placement: .automatic, direction: .right,
            first: TileSlot(x: 0, y: 0, width: 0.555, height: 1),
            second: TileSlot(x: 0.555, y: 0, width: 0.445, height: 1),
            "right from the second child"
        )
        expectResize(
            focused: "A", placement: .split(.down), direction: .up,
            first: TileSlot(x: 0, y: 0, width: 1, height: 0.445),
            second: TileSlot(x: 0, y: 0.445, width: 1, height: 0.555),
            "up from the first child"
        )
        expectResize(
            focused: "B", placement: .split(.down), direction: .down,
            first: TileSlot(x: 0, y: 0, width: 1, height: 0.555),
            second: TileSlot(x: 0, y: 0.555, width: 1, height: 0.445),
            "down from the second child"
        )
    }

    private static func opposite(_ direction: SnapDirection) -> SnapDirection {
        switch direction {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }

    private static func testResizeIsLocalToContainingSplit() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.insert("C", near: "B")
        guard tree.resize(focusedID: "B", direction: .down) else {
            fail("expected local vertical resize")
        }
        let slots = tree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "outer sibling unchanged")
        expectEqual(slots["B"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 0.555), "focused branch grows")
        expectEqual(slots["C"]!, TileSlot(x: 0.5, y: 0.555, width: 0.5, height: 0.445), "local sibling shrinks")
    }

    private static func testExplicitDropPlacement() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A", placement: .split(.left))
        let slots = tree.slots()
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "left drop inserts before target")
        expectEqual(slots["A"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "target shifts right")
    }

    private static func testToggleOrientation() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        guard tree.toggleOrientation(focusedID: "A") else {
            fail("expected orientation toggle")
        }
        let slots = tree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.5), "split became vertical")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.5, width: 1, height: 0.5), "sibling order preserved")
    }

    private static func testBalancePreservesWindows() {
        var tree = BSPTree<String>()
        for id in ["A", "B", "C", "D", "E"] {
            tree.insert(id, near: tree.largestLeafID())
        }
        tree.balance()
        guard Set(tree.ids) == ["A", "B", "C", "D", "E"] else {
            fail("balance should preserve all ids")
        }
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = tree.slotList().map { $0.slot.frame(in: screen, gap: 8, smartOuterGap: true) }
        for lhs in frames.indices {
            for rhs in frames.indices where rhs > lhs {
                let overlap = frames[lhs].intersection(frames[rhs])
                guard overlap.isNull || overlap.width * overlap.height <= 0.001 else {
                    fail("balanced tree produced overlapping frames: \(frames[lhs]) and \(frames[rhs])")
                }
            }
        }
    }

    private static func testGaps() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let left = TileSlot(x: 0, y: 0, width: 0.5, height: 1).frame(in: screen, gap: 10, smartOuterGap: true)
        let right = TileSlot(x: 0.5, y: 0, width: 0.5, height: 1).frame(in: screen, gap: 10, smartOuterGap: true)
        let single = TileSlot(x: 0, y: 0, width: 1, height: 1).frame(in: screen, gap: 10, smartOuterGap: true)
        expectEqual(left, CGRect(x: 10, y: 10, width: 485, height: 780), "left gap")
        expectEqual(right, CGRect(x: 505, y: 10, width: 485, height: 780), "right gap")
        expectEqual(single, CGRect(x: 10, y: 10, width: 980, height: 780), "single tile keeps an outer gap")
    }

    private static func testScreenGeometryChoosesLargestIntersection() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1000, height: 800)
        ]
        guard ScreenGeometry.bestScreenIndex(for: CGRect(x: 900, y: 100, width: 500, height: 300), screens: screens) == 1,
              ScreenGeometry.bestScreenIndex(for: CGRect(x: -600, y: 0, width: 100, height: 100), screens: screens) == nil else {
            fail("expected largest screen intersection")
        }
    }

    // MARK: - Hidden leaves

    /// A | (B over C)
    private static func threeWindowTree() -> BSPTree<String> {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.insert("C", near: "B")
        return tree
    }

    private static func testHiddenLeafGivesItsSlotToItsSibling() {
        let slots = threeWindowTree().slots(hidden: ["B"])
        guard slots["B"] == nil else {
            fail("a hidden window must not get a slot")
        }
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "unrelated tile is untouched")
        expectEqual(slots["C"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "sibling takes the hidden window's space")
    }

    private static func testHiddenLeafGetsItsSlotBack() {
        var tree = threeWindowTree()
        guard tree.resize(focusedID: "B", direction: .down) else {
            fail("expected resize")
        }
        let before = tree.slots()
        tree.insert("D", near: "A", hidden: ["B"])
        tree.remove("D")
        let after = tree.slots()
        for id in ["A", "B", "C"] {
            expectEqual(after[id]!, before[id]!, "\(id) returns to the slot it had before B was hidden")
        }
    }

    private static func testHiddenSubtreeCollapsesThroughNestedSplits() {
        let slots = threeWindowTree().slots(hidden: ["B", "C"])
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 1), "a fully hidden branch takes no space")
        guard threeWindowTree().slots(hidden: ["A", "B", "C"]).isEmpty else {
            fail("a tree with nothing visible has no slots")
        }
    }

    private static func testResizeSkipsSplitWithHiddenSide() {
        // With C hidden, B fills the right half. Growing B downwards has nothing to push against;
        // the split that matters is the one between A and the right half.
        var tree = threeWindowTree()
        guard !tree.resize(focusedID: "B", direction: .down, hidden: ["C"]) else {
            fail("a split with a hidden side must not resize")
        }
        guard tree.resize(focusedID: "B", direction: .left, hidden: ["C"]) else {
            fail("the visible split should still resize")
        }
        let slots = tree.slots(hidden: ["C"])
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.445, height: 1), "left tile shrinks")
        expectEqual(slots["B"]!, TileSlot(x: 0.445, y: 0, width: 0.555, height: 1), "right tile grows")
        expectEqual(tree.slots()["C"]!, TileSlot(x: 0.445, y: 0.5, width: 0.555, height: 0.5), "the hidden split keeps its ratio")
    }

    private static func testToggleOrientationSkipsSplitWithHiddenSide() {
        var tree = threeWindowTree()
        guard tree.toggleOrientation(focusedID: "B", hidden: ["C"]) else {
            fail("expected the visible split to rotate")
        }
        let slots = tree.slots(hidden: ["C"])
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.5), "outer split rotated")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.5, width: 1, height: 0.5), "visible sibling follows")
    }

    private static func testNeighborIgnoresHiddenWindows() {
        let tree = threeWindowTree()
        guard tree.neighborID(from: "A", direction: .right, hidden: ["B"]) == "C" else {
            fail("the neighbor must be a visible window")
        }
        guard tree.neighborID(from: "C", direction: .up, hidden: ["B"]) == nil else {
            fail("a hidden window is not a neighbor")
        }
    }

    private static func testInsertSplitsAVisibleTile() {
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        state.insert(3, hidden: [2])
        let slots = state.resolvedSlots(in: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 0, hidden: [2])
        expectEqual(slots[1]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "new window split the visible tile")
        expectEqual(slots[3]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "new window sits beside it")
    }

    // MARK: - Resize reflection

    private static func testObservedSlotInvertsRenderedFrame() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        for gap in [CGFloat(0), 8, 48] {
            for slot in [
                TileSlot(x: 0, y: 0, width: 1, height: 1),
                TileSlot(x: 0, y: 0, width: 0.5, height: 1),
                TileSlot(x: 0.5, y: 0, width: 0.5, height: 0.5),
                TileSlot(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
            ] {
                let frame = slot.frame(in: screen, gap: gap, smartOuterGap: true)
                let observed = TileSlot.observed(from: frame, in: screen, gap: gap, rendered: slot)
                guard abs(observed.x - slot.x) < 0.002, abs(observed.y - slot.y) < 0.002,
                      abs(observed.maxX - slot.maxX) < 0.002, abs(observed.maxY - slot.maxY) < 0.002 else {
                    fail("an untouched frame must read back as its own slot at gap \(gap): \(slot) became \(observed)")
                }
            }
        }
    }

    private static func testObservedSlotReadsADraggedDivider() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let slot = TileSlot(x: 0, y: 0, width: 0.5, height: 1)
        var frame = slot.frame(in: screen, gap: 20, smartOuterGap: true)
        frame.size.width += 96
        let observed = TileSlot.observed(from: frame, in: screen, gap: 20, rendered: slot)
        expectEqual(observed, TileSlot(x: 0, y: 0, width: 0.6, height: 1), "divider dragged 96 points of 960")
    }

    private static func testReflectResizeMovesTheSharedSplit() {
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        guard state.reflectResize(1, observedSlot: TileSlot(x: 0, y: 0, width: 0.6, height: 1)) else {
            fail("expected the split to follow the dragged edge")
        }
        let slots = state.resolvedSlots(in: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 0)
        expectEqual(slots[1]!, TileSlot(x: 0, y: 0, width: 0.6, height: 1), "dragged window keeps its new width")
        expectEqual(slots[2]!, TileSlot(x: 0.6, y: 0, width: 0.4, height: 1), "sibling gives up the difference")
        guard !state.reflectResize(1, observedSlot: TileSlot(x: 0, y: 0, width: 0.605, height: 1)) else {
            fail("a change below the threshold must not move the split")
        }
    }

    // MARK: - Accommodation

    private static func testAccommodationGrowsConstrainedTile() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let gap: CGFloat = 8
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        let frames = state.frames(in: screenFrame, gap: gap, accommodating: [1: CGSize(width: 700, height: 120)])
        guard let first = frames[1], let second = frames[2] else {
            fail("accommodation must keep both windows")
        }
        guard first.width >= 699 else {
            fail("constrained tile must grow to its minimum width, got \(first.width)")
        }
        guard second.width >= TileLayout.minimumWindowFrameSize.width - 1 else {
            fail("sibling must keep at least the default minimum, got \(second.width)")
        }
        guard !first.intersects(second) else {
            fail("accommodated frames must not overlap")
        }
        expectEqual(state.resolvedSlots(in: screenFrame, gap: gap)[1]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "the stored split is unchanged")
    }

    private static func testAccommodationInfeasibleFallsBackProportionally() {
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        let slots = state.resolvedSlots(
            in: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 0,
            accommodating: [1: CGSize(width: 800, height: 100), 2: CGSize(width: 800, height: 100)]
        )
        guard abs(slots[1]!.width - 0.5) < 0.001, abs(slots[2]!.width - 0.5) < 0.001 else {
            fail("equal minimums that cannot fit must split evenly, got \(slots[1]!.width)/\(slots[2]!.width)")
        }
    }

    private static func testAccommodationIgnoresHiddenWindows() {
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        let slots = state.resolvedSlots(
            in: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 0,
            accommodating: [2: CGSize(width: 900, height: 100)],
            hidden: [2]
        )
        expectEqual(slots[1]!, TileSlot(x: 0, y: 0, width: 1, height: 1), "a hidden window's minimum reserves nothing")
    }

    // MARK: - Workspace state

    private static func testStateZoomFillsWorkspaceAndClearsOnNewMember() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        guard state.toggleZoom(2) else {
            fail("expected zoom")
        }
        let frames = state.frames(in: screenFrame, gap: 10)
        expectEqual(frames[2]!, CGRect(x: 10, y: 10, width: 980, height: 780), "zoomed window fills the workspace")
        expectEqual(frames[1]!, CGRect(x: 10, y: 10, width: 485, height: 780), "the others keep their tiles underneath")
        state.insert(3)
        guard state.zoomedWindowID == nil else {
            fail("a new window ends the zoom")
        }
        state.toggleZoom(3)
        state.remove(3)
        guard state.zoomedWindowID == nil else {
            fail("removing the zoomed window ends the zoom")
        }
    }

    private static func testStateFocusTargetSkipsHiddenWindows() {
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        state.markFocused(2)
        guard state.focusTarget() == 2, state.focusTarget(hidden: [2]) == 1 else {
            fail("the focus target must be a visible window")
        }
    }

    private static func testStateMergeKeepsShapeAndFocus() {
        var target = ScreenTileState()
        target.insert(1)
        target.insert(2, near: 1)
        target.markFocused(1)
        var source = ScreenTileState()
        source.insert(3)
        source.insert(4, near: 3)
        target.merge(source, preferSourceFocus: false)
        guard target.windowIDs == [1, 2, 3, 4], target.focusedWindowID == 1 else {
            fail("merge must keep every window and the target's focus")
        }
    }

    // MARK: - Model

    static let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    static func screen(
        _ key: String = "main",
        space: UInt64 = 1,
        x: CGFloat = 0,
        isTileable: Bool = true
    ) -> ScreenInfo {
        let frame = screenFrame.offsetBy(dx: x, dy: 0)
        return ScreenInfo(key: key, displayID: 1, frame: frame, bounds: frame, space: space, isTileable: isTileable)
    }

    static func window(_ id: WindowID, pid: pid_t = 100) -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: pid,
            handle: StubWindowHandle(),
            bundleIdentifier: nil,
            title: nil
        )
    }

    private static func testModelTilesNewWindowBesideLastFocused() {
        let main = screen()
        let key = main.workspaceKey(index: 0)
        var model = TilingModel()
        model.adoptTiled(window(1), in: key, onScreen: [1])
        model.adoptTiled(window(2), in: key, onScreen: [1, 2])
        model.markFocused(1)
        model.adoptTiled(window(3), in: key, onScreen: [1, 2, 3])
        let placements = model.placements(screens: [main], onScreen: [1, 2, 3], gap: 0)
        expectPlacement(placements[1], .tile(CGRect(x: 0, y: 0, width: 500, height: 400)), "focused tile was split")
        expectPlacement(placements[3], .tile(CGRect(x: 0, y: 400, width: 500, height: 400)), "new window took the other half")
        expectPlacement(placements[2], .tile(CGRect(x: 500, y: 0, width: 500, height: 800)), "unfocused tile untouched")
    }

    private static func testModelParksWindowsOfHiddenWorkspaces() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(2), in: main.workspaceKey(index: 1), onScreen: [1, 2])
        var placements = model.placements(screens: [main], onScreen: [1, 2], gap: 0)
        expectPlacement(placements[1], .tile(screenFrame), "workspace 1 is showing")
        expectPlacement(placements[2], .parked(main), "workspace 2 is parked")
        model.setActiveIndex(1, in: main.scope)
        placements = model.placements(screens: [main], onScreen: [1, 2], gap: 0)
        expectPlacement(placements[1], .parked(main), "workspace 1 is parked after the switch")
        expectPlacement(placements[2], .tile(screenFrame), "workspace 2 is showing after the switch")
    }

    private static func testModelKeepsMinimizedWindowsPlace() {
        let main = screen()
        let key = main.workspaceKey(index: 0)
        var model = TilingModel()
        for id in [WindowID(1), 2, 3] {
            model.adoptTiled(window(id), in: key, near: id == 1 ? nil : id - 1, onScreen: [1, 2, 3])
        }
        let all = model.placements(screens: [main], onScreen: [1, 2, 3], gap: 0)
        let minimized = model.placements(screens: [main], onScreen: [1, 3], gap: 0)
        guard minimized[2] == nil else {
            fail("a minimized window has no placement")
        }
        expectPlacement(minimized[3], .tile(CGRect(x: 500, y: 0, width: 500, height: 800)), "its sibling fills the space")
        guard model.workspace(of: 2) == key else {
            fail("a minimized window stays in its workspace")
        }
        let restored = model.placements(screens: [main], onScreen: [1, 2, 3], gap: 0)
        for id in [WindowID(1), 2, 3] {
            expectPlacement(restored[id], all[id]!, "window \(id) returns to its tile")
        }
    }

    private static func testModelReplacementTakesOverTile() {
        let main = screen()
        let key = main.workspaceKey(index: 0)
        var model = TilingModel()
        model.adoptTiled(window(1), in: key, onScreen: [1])
        model.adoptTiled(window(2), in: key, near: 1, onScreen: [1, 2])
        model.edit(key) { $0.toggleZoom(2) }
        // Window 2 is a tab that was switched away from; window 3 is the tab that replaced it.
        model.adopt(window(3), replacing: 2)
        guard model.windows[2] == nil, model.workspace(of: 3) == key,
              model.trees[key]?.zoomedWindowID == 3, model.trees[key]?.focusedWindowID == 3 else {
            fail("the replacement takes over the tile, focus and zoom, and the old window is forgotten")
        }
        model.edit(key) { $0.clearZoom() }
        let placements = model.placements(screens: [main], onScreen: [1, 3], gap: 0)
        expectPlacement(placements[3], .tile(CGRect(x: 500, y: 0, width: 500, height: 800)), "the new tab sits where the old one was")
        expectPlacement(placements[1], .tile(CGRect(x: 0, y: 0, width: 500, height: 800)), "the other window never moves")

        model.adoptFloating(window(4), in: main.scope)
        model.adopt(window(5), replacing: 4)
        guard model.floating[5] == main.scope, model.floating[4] == nil else {
            fail("a floating window's replacement floats too")
        }
    }

    private static func testModelIgnoresSpacesThatAreNotShowing() {
        let desktop = screen(space: 1)
        let otherDesktop = screen(space: 2)
        let fullscreen = screen(space: 3, isTileable: false)
        var model = TilingModel()
        model.adoptTiled(window(1), in: desktop.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(2), in: otherDesktop.workspaceKey(index: 0), onScreen: [2])
        guard model.placements(screens: [desktop], onScreen: [1], gap: 0).keys.sorted() == [1] else {
            fail("only the showing Space is laid out")
        }
        guard model.placements(screens: [otherDesktop], onScreen: [2], gap: 0).keys.sorted() == [2] else {
            fail("each Space keeps its own tree")
        }
        guard model.placements(screens: [fullscreen], onScreen: [1, 2], gap: 0).isEmpty else {
            fail("a fullscreen Space is never tiled")
        }
    }

    /// A window that goes fullscreen leaves the desktop's listing, and on the way back it can sit
    /// on no Space at all. Its tile waits for it, so every window ends up where it was.
    private static func testModelKeepsTilesThroughFullscreenRoundTrip() {
        let desktop = screen(space: 1)
        let fullscreen = screen(space: 9, isTileable: false)
        let key = desktop.workspaceKey(index: 0)
        var model = TilingModel()
        model.adoptTiled(window(1), in: key, onScreen: [1])
        model.adoptTiled(window(2), in: key, near: 1, onScreen: [1, 2])
        model.adoptTiled(window(3), in: key, near: 2, onScreen: [1, 2, 3])
        let before = model.placements(screens: [desktop], onScreen: [1, 2, 3], gap: 0)
        // Window 2 leaves for its fullscreen Space, then returns ordered out and on no Space.
        let states: [(spaces: [UInt64], showing: Set<UInt64>)] = [([9], [1]), ([9], [9]), ([], [1]), ([1], [1])]
        for state in states {
            let verdict = WindowDeparturePlanner.verdict(
                exists: true, announcedClosing: false, isMinimized: false,
                isHomeShowing: state.showing.contains(1), spaces: state.spaces, showingSpaces: state.showing
            )
            guard verdict == .hidden else {
                fail("a window between Spaces is out of view, not closed: \(state)")
            }
        }
        guard model.placements(screens: [fullscreen], onScreen: [], gap: 0).isEmpty else {
            fail("nothing is tiled while the fullscreen Space shows")
        }
        let during = model.placements(screens: [desktop], onScreen: [1, 3], gap: 0)
        guard during[2] == nil, during.count == 2 else {
            fail("the window away in fullscreen takes no space")
        }
        let after = model.placements(screens: [desktop], onScreen: [1, 2, 3], gap: 0)
        guard after == before else {
            fail("every window returns to its own tile\nbefore: \(before)\nafter:  \(after)")
        }
    }

    /// Switching tabs of a merged window group hands the shown tab's tile to the selected one.
    private static func testStateExchangeKeepsZoomAndFocusWithTheTile() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var state = ScreenTileState()
        state.insert(1)
        state.insert(2, near: 1)
        state.insert(3, near: 2)
        state.markFocused(1)
        state.toggleZoom(1)
        let before = state.frames(in: frame, gap: 0, hidden: [3])
        guard state.exchange(1, 3), state.zoomedWindowID == 3, state.focusedWindowID == 3 else {
            fail("zoom and focus follow the tile to the selected tab")
        }
        let after = state.frames(in: frame, gap: 0, hidden: [1])
        guard after[3] == before[1], after[2] == before[2] else {
            fail("the selected tab sits exactly where the tab before it was")
        }
    }

    private static func testDepartureNeedsEvidenceOfClosing() {
        func verdict(
            exists: Bool = true, closing: Bool = false, minimized: Bool = false, home: Bool = true,
            spaces: [UInt64] = []
        ) -> WindowDeparturePlanner.Verdict {
            WindowDeparturePlanner.verdict(
                exists: exists, announcedClosing: closing, isMinimized: minimized,
                isHomeShowing: home, spaces: spaces, showingSpaces: [1]
            )
        }
        guard verdict(exists: false) == .gone, verdict(exists: false, minimized: true) == .gone else {
            fail("a window the server no longer has is gone")
        }
        guard verdict(closing: true) == .gone, verdict(closing: true, spaces: [1]) == .gone else {
            fail("a window whose app announced its close and that left the listing is gone")
        }
        guard verdict() == .hidden, verdict(spaces: [1]) == .hidden else {
            fail("a window ordered out without a close is only out of view")
        }
        guard verdict(closing: true, minimized: true) == .hidden else {
            fail("an element rebuilt while minimized is not a close")
        }
        guard verdict(closing: true, spaces: [9]) == .rebuilt else {
            fail("a window announced closed but alive on another Space had its element rebuilt")
        }
        guard verdict(closing: true, home: false, spaces: [1]) == .hidden else {
            fail("an announcement waits until the window's own desktop shows")
        }
    }

    private static func testModelFloatAndTile() {
        let main = screen()
        let key = main.workspaceKey(index: 0)
        var model = TilingModel()
        model.adoptTiled(window(1), in: key, onScreen: [1])
        model.adoptFloating(window(2), in: main.scope)
        guard model.floating[2] == main.scope, model.workspace(of: 2) == nil else {
            fail("a floating window is in no tree")
        }
        guard model.placements(screens: [main], onScreen: [1, 2], gap: 0)[2] == nil else {
            fail("a floating window is never placed")
        }
        model.tile(2, in: key, onScreen: [1, 2])
        guard model.floating[2] == nil, model.workspace(of: 2) == key else {
            fail("tiling a floating window adds it to the tree")
        }
        model.float(1, in: main.scope)
        guard model.workspace(of: 1) == nil, model.floating[1] == main.scope else {
            fail("floating a tiled window removes it from the tree")
        }
    }

    private static func testModelMoveBetweenWorkspaces() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(2), in: main.workspaceKey(index: 0), onScreen: [1, 2])
        model.move(2, to: main.workspaceKey(index: 2), onScreen: [1, 2])
        guard model.workspace(of: 2) == main.workspaceKey(index: 2) else {
            fail("window should be in the target workspace")
        }
        let placements = model.placements(screens: [main], onScreen: [1, 2], gap: 0)
        expectPlacement(placements[1], .tile(screenFrame), "remaining window fills the workspace")
        expectPlacement(placements[2], .parked(main), "moved window is parked")
        model.move(1, to: main.workspaceKey(index: 2), onScreen: [1, 2])
        guard model.trees[main.workspaceKey(index: 0)] == nil else {
            fail("an emptied workspace keeps no tree")
        }
    }

    private static func testModelDeleteWorkspaceShiftsHigherWorkspaces() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(3), in: main.workspaceKey(index: 2), onScreen: [1, 3])
        model.setActiveIndex(2, in: main.scope)
        model.deleteWorkspace(index: 1, workspaceCount: 3)
        guard model.workspace(of: 3) == main.workspaceKey(index: 1), model.activeIndex(in: main.scope) == 1 else {
            fail("workspaces above the deleted one move down, and the showing one stays showing")
        }
        guard model.workspace(of: 1) == main.workspaceKey(index: 0) else {
            fail("workspaces below the deleted one stay put")
        }
    }

    private static func testModelDeletionRules() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        guard model.deletionBlockReason(index: 0, workspaceCount: 1) == "Only Workspace",
              model.deletionBlockReason(index: 0, workspaceCount: 3) == "Not Empty",
              model.deletionBlockReason(index: 1, workspaceCount: 3) == nil,
              model.deletionBlockReason(index: 5, workspaceCount: 3) == "Unavailable" else {
            fail("unexpected deletion rule")
        }
        model.adoptFloating(window(2), in: main.scope)
        model.setActiveIndex(1, in: main.scope)
        guard model.deletionBlockReason(index: 1, workspaceCount: 3) == "Not Empty" else {
            fail("a floating window on the showing workspace keeps it from being deleted")
        }
    }

    private static func testModelMergeAllIntoActiveWorkspaces() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(2), in: main.workspaceKey(index: 1), onScreen: [1, 2])
        model.adoptTiled(window(3), in: main.workspaceKey(index: 3), onScreen: [1, 2, 3])
        model.edit(main.workspaceKey(index: 0)) { $0.toggleZoom(1) }
        model.mergeAllIntoActiveWorkspaces()
        guard model.trees.count == 1, model.trees[main.workspaceKey(index: 0)]?.windowIDs == [1, 2, 3] else {
            fail("every window should end up in the showing workspace")
        }
        guard model.trees[main.workspaceKey(index: 0)]?.zoomedWindowID == nil else {
            fail("merging ends any zoom")
        }
    }

    private static func testModelEvacuatesAndRestoresDisplay() {
        let main = screen("main", space: 1)
        let external = screen("external", space: 7, x: 1000)
        var model = TilingModel()
        model.adoptTiled(window(1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptTiled(window(2), in: external.workspaceKey(index: 0), onScreen: [1, 2])
        model.adoptTiled(window(3), in: external.workspaceKey(index: 2), onScreen: [1, 2, 3])

        var orphans: [[WindowID]] = []
        let moved = model.reconcileDisplays([main], onScreen: [1, 2, 3]) { windows in
            orphans.append(windows)
            return main
        }
        guard orphans.sorted(by: { $0[0] < $1[0] }) == [[2], [3]] else {
            fail("the fallback is asked about each orphaned workspace's windows, got \(orphans)")
        }
        guard moved.isEmpty,
              model.workspace(of: 2) == main.workspaceKey(index: 0),
              model.workspace(of: 3) == main.workspaceKey(index: 2) else {
            fail("an unplugged display's workspaces move to the remaining display with their indices")
        }

        let restored = model.reconcileDisplays([main, external], onScreen: [1, 2, 3]) { _ in main }
        guard restored == [2, 3],
              model.workspace(of: 1) == main.workspaceKey(index: 0),
              model.workspace(of: 2) == external.workspaceKey(index: 0),
              model.workspace(of: 3) == external.workspaceKey(index: 2) else {
            fail("windows go back to the display they came from when it returns")
        }
        guard model.reconcileDisplays([main, external], onScreen: [1, 2, 3], fallback: { _ in main }).isEmpty else {
            fail("a display is only restored once")
        }
    }

    private static func testModelAccommodatesLearnedMinimum() {
        let main = screen()
        let key = main.workspaceKey(index: 0)
        var model = TilingModel()
        model.adoptTiled(window(1), in: key, onScreen: [1])
        model.adoptTiled(window(2), in: key, near: 1, onScreen: [1, 2])
        model.setMinimumSize(CGSize(width: 700, height: 0), of: 2)
        let placements = model.placements(screens: [main], onScreen: [1, 2], gap: 0)
        guard case .tile(let frame)? = placements[2], frame.width >= 700 else {
            fail("a window gets at least the size its app insists on")
        }
        model.setMinimumSize(.zero, of: 2)
        expectPlacement(
            model.placements(screens: [main], onScreen: [1, 2], gap: 0)[2],
            .tile(CGRect(x: 500, y: 0, width: 500, height: 800)),
            "forgetting the minimum restores the even split"
        )
    }

    private static func testModelForgetRemovesEverywhere() {
        let main = screen()
        var model = TilingModel()
        model.adoptTiled(window(1, pid: 1), in: main.workspaceKey(index: 0), onScreen: [1])
        model.adoptFloating(window(2, pid: 1), in: main.scope)
        model.adoptTiled(window(3, pid: 2), in: main.workspaceKey(index: 0), onScreen: [1, 3])
        model.forget(1)
        model.forget(2)
        guard model.windows.keys.sorted() == [3], model.floating.isEmpty, model.workspace(of: 1) == nil else {
            fail("a forgotten window is removed from every structure")
        }
    }

    // MARK: - Planners

    private static func testServerWindowStandardFilter() {
        func serverWindow(level: Int32 = 0, parent: WindowID = 0, tags: UInt64, attributes: UInt64 = 3) -> ServerWindow {
            ServerWindow(id: 1, pid: 1, level: level, parent: parent, tags: tags, attributes: attributes, bounds: .zero, space: 1)
        }
        // Tag values observed for real windows on macOS 27.2.
        guard serverWindow(tags: 0x0300_0001_0008_2401).isStandard,
              serverWindow(tags: 0x0300_0001_0048_2001).isStandard,
              serverWindow(tags: 0x0200_0001_0008_2001).isStandard else {
            fail("document windows must pass the standard-window filter")
        }
        guard !serverWindow(parent: 69, tags: 0x0000_0001_000c_2082).isStandard,
              !serverWindow(parent: 68, tags: 0x0000_0001_400c_2081).isStandard,
              !serverWindow(level: 3, tags: 0x0300_0001_0008_2401).isStandard,
              !serverWindow(tags: 0x0300_0001_0008_2400, attributes: 3).isStandard else {
            fail("sheets, child windows, floating panels and untagged windows are not standard")
        }
    }

    private static func testWindowManageabilityPlannerFailsClosed() {
        func inputs(
            role: AXRead<String> = .value(kAXWindowRole),
            subrole: AXRead<String> = .value(kAXStandardWindowSubrole),
            isModal: AXRead<Bool> = .missing,
            title: String? = "Document",
            positionSettable: AXRead<Bool> = .value(true),
            sizeSettable: AXRead<Bool> = .value(true)
        ) -> WindowManageabilityPlanner.Inputs {
            WindowManageabilityPlanner.Inputs(
                role: role,
                subrole: subrole,
                isModal: isModal,
                title: title,
                positionSettable: positionSettable,
                sizeSettable: sizeSettable
            )
        }
        func expectVerdict(_ inputs: WindowManageabilityPlanner.Inputs, _ expected: WindowManageability, _ message: String) {
            let actual = WindowManageabilityPlanner.manageability(inputs)
            guard actual == expected else {
                fail("\(message): expected \(expected), got \(actual)")
            }
        }
        expectVerdict(inputs(), .manageable, "standard resizable window")
        expectVerdict(inputs(subrole: .missing), .manageable, "absent subrole is admitted")
        expectVerdict(inputs(subrole: .value("AXDialog")), .excluded, "dialog subrole")
        expectVerdict(inputs(subrole: .failed), .unknown, "failed subrole read must fail closed")
        expectVerdict(inputs(role: .failed), .unknown, "failed role read must fail closed")
        expectVerdict(inputs(role: .value("AXSheet")), .excluded, "non-window role")
        expectVerdict(inputs(isModal: .value(true)), .excluded, "modal window")
        expectVerdict(inputs(isModal: .failed), .unknown, "failed modal read must fail closed")
        expectVerdict(inputs(title: "Picture in Picture"), .excluded, "PiP title")
        expectVerdict(inputs(sizeSettable: .value(false)), .excluded, "non-resizable window")
        expectVerdict(inputs(positionSettable: .failed), .unknown, "failed settability must fail closed")
    }

    private static func testFrameVerificationClassifierVerdicts() {
        let target = CGRect(x: 0, y: 0, width: 500, height: 400)
        func expectVerdict(_ observed: CGRect, _ expected: FrameVerificationVerdict, _ message: String) {
            let actual = FrameVerificationClassifier.classify(target: target, observed: observed, tolerance: 2)
            guard actual == expected else {
                fail("\(message): expected \(expected), got \(actual)")
            }
        }
        expectVerdict(target, .applied, "exact match")
        expectVerdict(CGRect(x: 1, y: -1, width: 501, height: 399), .applied, "within tolerance")
        expectVerdict(
            CGRect(x: 0, y: 0, width: 760, height: 400),
            .clamped(observedMinimum: CGSize(width: 760, height: 0)),
            "width-only clamp reports width only"
        )
        expectVerdict(
            CGRect(x: 0, y: 0, width: 760, height: 620),
            .clamped(observedMinimum: CGSize(width: 760, height: 620)),
            "both-axis clamp"
        )
        expectVerdict(CGRect(x: 80, y: 0, width: 500, height: 400), .rejected, "moved window")
        expectVerdict(CGRect(x: 0, y: 0, width: 400, height: 400), .rejected, "shrunken window")
        expectVerdict(CGRect(x: 80, y: 0, width: 760, height: 400), .rejected, "moved and oversized is not a clamp")
    }

    private static func testSlidePlannerMovesOutgoingAndIncomingWindows() {
        let main = screen()
        let transitions = WorkspaceSlidePlanner.transitions(
            outgoing: [(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))],
            incoming: [(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 800))],
            screen: main,
            direction: .forward,
            screens: [main]
        )
        guard transitions.count == 2 else {
            fail("expected one transition per window")
        }
        expectEqual(transitions[0].endFrame, CGRect(x: -999, y: 0, width: 1000, height: 800), "outgoing window leaves on the left")
        expectEqual(transitions[1].startFrame, CGRect(x: 999, y: 0, width: 500, height: 800), "incoming window enters from the right")
        expectEqual(transitions[1].endFrame, CGRect(x: 0, y: 0, width: 500, height: 800), "incoming window ends in its tile")
        guard !transitions[0].needsInitialFrame, transitions[1].needsInitialFrame else {
            fail("only incoming windows need placing before the slide")
        }
        let halfway = WorkspaceSlidePlanner.interpolatedOrigin(
            from: transitions[1].startFrame, to: transitions[1].endFrame, progress: 0.5
        )
        guard halfway.x < 499, halfway.x > 0 else {
            fail("ease-out should be past the midpoint halfway through, got \(halfway.x)")
        }
    }

    private static func testSlidePlannerRefusesToCrossAnotherDisplay() {
        let main = screen("main")
        let right = screen("right", space: 2, x: 1000)
        let transitions = WorkspaceSlidePlanner.transitions(
            outgoing: [(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))],
            incoming: [],
            screen: main,
            direction: .backward,
            screens: [main, right]
        )
        guard transitions.isEmpty else {
            fail("a slide that would show a window on the next display is not animated")
        }
    }

    private static func testChainedSlideContinuesFromCurrentPosition() {
        let main = screen()
        let previous = [
            WorkspaceSlideTransition(
                window: 1,
                startFrame: CGRect(x: 999, y: 0, width: 1000, height: 800),
                endFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                needsInitialFrame: true
            )
        ]
        let transitions = WorkspaceSlidePlanner.chainedTransitions(
            previous: previous,
            currentOrigins: [1: CGPoint(x: 400, y: 0)],
            incoming: [(id: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))],
            screen: main,
            direction: .forward,
            screens: [main]
        )
        guard transitions.count == 2 else {
            fail("expected the moving window and the new target window")
        }
        expectEqual(transitions[0].startFrame, CGRect(x: 400, y: 0, width: 1000, height: 800), "a moving window continues from where it is")
        expectEqual(transitions[0].endFrame, CGRect(x: -999, y: 0, width: 1000, height: 800), "and leaves on the outgoing edge")
        guard !transitions[0].needsInitialFrame, transitions[1].needsInitialFrame else {
            fail("only the newly incoming window needs placing")
        }
    }

    private static func testChainedSlideSkipsAlreadyHiddenNonTargetWindows() {
        let main = screen()
        let hiddenLeft = CGRect(x: -199, y: 100, width: 200, height: 300)
        let transitions = WorkspaceSlidePlanner.chainedTransitions(
            previous: [
                WorkspaceSlideTransition(
                    window: 1,
                    startFrame: CGRect(x: 20, y: 100, width: 200, height: 300),
                    endFrame: hiddenLeft,
                    needsInitialFrame: false
                )
            ],
            currentOrigins: [1: hiddenLeft.origin],
            incoming: [(id: 2, frame: CGRect(x: 100, y: 100, width: 200, height: 300))],
            screen: main,
            direction: .backward,
            screens: [main]
        )
        guard transitions.map(\.window) == [2] else {
            fail("an already hidden window must stay hidden instead of crossing the screen")
        }
    }

    private static func testFocusNavigatorPicksNeighborByGeometry() {
        let source = CGRect(x: 0, y: 0, width: 500, height: 800)
        let candidates: [(id: WindowID, frame: CGRect)] = [
            (1, CGRect(x: 500, y: 0, width: 500, height: 400)),
            (2, CGRect(x: 500, y: 400, width: 500, height: 400)),
            (3, CGRect(x: 1500, y: 0, width: 500, height: 800))
        ]
        guard WindowFocusNavigator.neighbor(of: source, direction: .right, among: candidates) != 3 else {
            fail("the nearest window in the direction wins")
        }
        guard WindowFocusNavigator.neighbor(of: source, direction: .left, among: candidates) == nil else {
            fail("nothing lies to the left")
        }
    }

    private static func testFocusNavigatorFindsAdjacentDisplays() {
        let left = screen("left")
        let right = screen("right", space: 2, x: 1000)
        guard WindowFocusNavigator.adjacentScreen(to: left, direction: .right, screens: [left, right])?.key == "right",
              WindowFocusNavigator.adjacentScreen(to: left, direction: .left, screens: [left, right]) == nil,
              WindowFocusNavigator.adjacentScreen(to: right, direction: .left, screens: [left, right])?.key == "left" else {
            fail("adjacent display lookup is wrong")
        }
        let entry = WindowFocusNavigator.entryWindow(
            from: CGRect(x: 500, y: 0, width: 500, height: 400),
            direction: .right,
            among: [
                (1, CGRect(x: 1500, y: 0, width: 500, height: 800)),
                (2, CGRect(x: 1000, y: 0, width: 500, height: 400))
            ]
        )
        guard entry == 2 else {
            fail("entering a display lands on the window across the shared edge")
        }
    }

    private static func testDropPlannerActions() {
        let target = CGRect(x: 0, y: 0, width: 900, height: 600)
        guard WindowDropPlanner.dropAction(cursor: CGPoint(x: 450, y: 300), targetFrame: target) == .swap,
              WindowDropPlanner.dropAction(cursor: CGPoint(x: 20, y: 300), targetFrame: target) == .split(.left),
              WindowDropPlanner.dropAction(cursor: CGPoint(x: 880, y: 300), targetFrame: target) == .split(.right),
              WindowDropPlanner.dropAction(cursor: CGPoint(x: 450, y: 10), targetFrame: target) == .split(.up),
              WindowDropPlanner.dropAction(cursor: CGPoint(x: 450, y: 590), targetFrame: target) == .split(.down) else {
            fail("drop zones are wrong")
        }
    }

    private static func testDropPlannerTarget() {
        let candidates: [(id: WindowID, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 500, height: 800)),
            (2, CGRect(x: 500, y: 0, width: 500, height: 800))
        ]
        let moving = CGRect(x: 600, y: 100, width: 300, height: 300)
        guard WindowDropPlanner.target(cursor: CGPoint(x: 100, y: 100), movingFrame: moving, candidates: candidates)?.id == 1 else {
            fail("the tile under the pointer wins")
        }
        guard WindowDropPlanner.target(cursor: CGPoint(x: 2000, y: 100), movingFrame: moving, candidates: candidates)?.id == 2 else {
            fail("otherwise the tile the window overlaps most wins")
        }
        guard WindowDropPlanner.target(cursor: .zero, movingFrame: moving, candidates: []) == nil else {
            fail("an empty display has no drop target")
        }
    }

    private static func testParkOriginKeepsCornerOnSingleDisplay() {
        let origin = FramePlanner.parkOrigin(
            windowSize: CGSize(width: 600, height: 500),
            screenFrame: screenFrame,
            otherScreenFrames: []
        )
        guard origin == CGPoint(x: 999, y: 799) else {
            fail("a single display parks at its bottom-right corner, got \(origin)")
        }
    }

    private static func testParkOriginAvoidsNeighboringDisplays() {
        let size = CGSize(width: 600, height: 500)
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let middle = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let below = CGRect(x: 0, y: 800, width: 1000, height: 800)
        func park(_ screen: CGRect, _ others: [CGRect]) -> CGRect {
            CGRect(origin: FramePlanner.parkOrigin(windowSize: size, screenFrame: screen, otherScreenFrames: others), size: size)
        }
        guard park(left, [middle]) == CGRect(x: -599, y: 799, width: 600, height: 500) else {
            fail("park from the left display should extend away from the right neighbor")
        }
        guard park(middle, [left]) == CGRect(x: 1999, y: 799, width: 600, height: 500) else {
            fail("park with only a left neighbor should keep the bottom-right corner")
        }
        let fromMiddle = park(middle, [left, right])
        guard fromMiddle == CGRect(x: 1400, y: 799, width: 600, height: 500),
              !fromMiddle.intersects(left), !fromMiddle.intersects(right) else {
            fail("park from the middle display should extend straight down")
        }
        let fromAbove = park(left, [below])
        guard fromAbove == CGRect(x: 999, y: 300, width: 600, height: 500), !fromAbove.intersects(below) else {
            fail("park with a neighbor below should extend sideways")
        }
    }

    private static func testParkOriginIsDeterministicWhenSurrounded() {
        let size = CGSize(width: 600, height: 500)
        let source = CGRect(x: 1000, y: 800, width: 1000, height: 800)
        let neighbors = [
            CGRect(x: 0, y: 800, width: 1000, height: 800),
            CGRect(x: 2000, y: 800, width: 1000, height: 800),
            CGRect(x: 1000, y: 1600, width: 1000, height: 800)
        ]
        let first = FramePlanner.parkOrigin(windowSize: size, screenFrame: source, otherScreenFrames: neighbors)
        let second = FramePlanner.parkOrigin(windowSize: size, screenFrame: source, otherScreenFrames: neighbors)
        guard first == second else {
            fail("the surrounded fallback should be deterministic")
        }
        let onSource = CGRect(origin: first, size: size).intersection(source)
        guard onSource.width > 0, onSource.height > 0 else {
            fail("a parked window stays anchored on its own display")
        }
    }

    // MARK: - Helpers

    private final class StubWindowHandle: WindowHandle {
        func setSize(_ size: CGSize) -> AXError { .success }
        func setPosition(_ origin: CGPoint) -> AXError { .success }
        func frame() -> CGRect? { nil }
        func title() -> String? { nil }
        func raise() {}
    }

    static func expectEqual(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        guard actual == expected else {
            fail("\(message)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }

    static func expectEqual(_ actual: TileSlot, _ expected: TileSlot, _ message: String) {
        guard abs(actual.x - expected.x) <= 0.001, abs(actual.y - expected.y) <= 0.001,
              abs(actual.width - expected.width) <= 0.001, abs(actual.height - expected.height) <= 0.001 else {
            fail("\(message)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }

    static func expectPlacement(_ actual: Placement?, _ expected: Placement, _ message: String) {
        guard actual == expected else {
            fail("\(message)\nexpected: \(expected)\nactual:   \(String(describing: actual))")
        }
    }

    static func fail(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(1)
    }
}
