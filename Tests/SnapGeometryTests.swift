import CoreGraphics
import Foundation
@main
struct SnapGeometryTests {
    static func main() {
        testSnapGeometry()
        testTreeInsertionSplitsFocusedTile()
        testRemovalPromotesSibling()
        testDirectionalNeighborAndSwap()
        testTreeReplaceIDsPreservesSlots()
        testTreeRejectsIdentityReplacementCollision()
        testTreeCompactMapIDsPreservesSlots()
        testTreeCompactMapIDsRejectsMissingLeaf()
        testResizeMovesContainingSplitFromEitherSideOnBothAxes()
        testResizeIsLocalToContainingSplit()
        testExplicitDropPlacement()
        testToggleOrientation()
        testBalancePreservesWindows()
        testGaps()
        testNormalizedSlotClampsToUnitBounds()
        testScreenGeometryChoosesLargestIntersection()
        testWindowIdentitySurvivesRenumberByElement()
        testWindowIdentitySurvivesRenumberBySignature()
        testWindowIdentityRejectsReusedNumberWithDifferentSignature()
        testWindowIdentityDoesNotReuseSignatureAcrossDisplays()
        testWindowIdentityPrunesStaleSignatureAliases()
        testWindowIdentityPrunesStaleWindowNumberAliases()
        testWindowIdentityPrunesStaleElementAliases()
        testWindowIdentityRetainsPreservedAliases()
        testWindowIdentityFindsStrongAlias()
        testWindowIdentityDoesNotTreatSignatureAsStrongAlias()
        testWindowIdentityRemovesAliasesForStaleIdentity()
        testWindowIdentityEvictsStaleWindowNumberAlias()
        testWindowIdentityEvictsStaleSignatureAlias()
        testWindowIdentityAvoidsAlreadySeenWindowNumberIdentity()
        testWindowIdentityAvoidsAlreadySeenSignatureIdentity()
        testWindowIdentityCreatesDistinctUnnumberedWindows()
        testWindowLayoutIdentityMatchesStrongComponentWhenTitleChanges()
        testWindowLayoutIdentityRejectsDuplicateWeakMatches()
        testWindowLayoutIdentityRejectsWeakMatchWhenStrongComponentConflicts()
        print("SnapGeometryTests passed")
    }
    private static func testSnapGeometry() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 827)
        let full = screen
        expectEqual(SnapGeometry.targetRect(for: .left, current: full, screen: screen), CGRect(x: 0, y: 25, width: 720, height: 827), "left snap")
        expectEqual(SnapGeometry.targetRect(for: .right, current: full, screen: screen), CGRect(x: 720, y: 25, width: 720, height: 827), "right snap")
        expectEqual(SnapGeometry.targetRect(for: .up, current: full, screen: screen), CGRect(x: 0, y: 25, width: 1440, height: 414), "up snap")
        expectEqual(SnapGeometry.targetRect(for: .down, current: full, screen: screen), CGRect(x: 0, y: 439, width: 1440, height: 414), "down snap")
    }
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
    private static func testTreeReplaceIDsPreservesSlots() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.insert("C", near: "B")
        let before = tree.slots()
        guard tree.replaceIDs(["B": "B2"]) else {
            fail("expected identity replacement to report a change")
        }
        let after = tree.slots()
        guard !tree.contains("B"), tree.contains("B2") else {
            fail("expected old id to be replaced with new id")
        }
        expectEqual(after["A"]!, before["A"]!, "unrelated first slot survives identity replacement")
        expectEqual(after["B2"]!, before["B"]!, "replacement keeps the old tile geometry")
        expectEqual(after["C"]!, before["C"]!, "unrelated second slot survives identity replacement")
    }
    private static func testTreeRejectsIdentityReplacementCollision() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        let before = tree.slots()
        guard !tree.replaceIDs(["A": "B"]) else {
            fail("identity replacement should reject duplicate leaf ids")
        }
        expectEqual(tree.slots()["A"]!, before["A"]!, "collision should leave original first slot untouched")
        expectEqual(tree.slots()["B"]!, before["B"]!, "collision should leave original second slot untouched")
    }
    private static func testTreeCompactMapIDsPreservesSlots() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        tree.insert("C", near: "B")
        let before = tree.slots()
        guard let mapped = tree.compactMapIDs({ ["A": 10, "B": 20, "C": 30][$0] }) else {
            fail("expected complete id map to produce a tree")
        }
        let after = mapped.slots()
        expectEqual(after[10]!, before["A"]!, "mapped first slot should be preserved")
        expectEqual(after[20]!, before["B"]!, "mapped second slot should be preserved")
        expectEqual(after[30]!, before["C"]!, "mapped third slot should be preserved")
    }
    private static func testTreeCompactMapIDsRejectsMissingLeaf() {
        var tree = BSPTree<String>()
        tree.insert("A", near: nil)
        tree.insert("B", near: "A")
        guard tree.compactMapIDs({ ["A": 10][$0] }) == nil else {
            fail("incomplete id maps should not silently drop a persisted layout leaf")
        }
    }
    private static func testResizeMovesContainingSplitFromEitherSideOnBothAxes() {
        var firstTree = BSPTree<String>()
        firstTree.insert("A", near: nil)
        firstTree.insert("B", near: "A")
        guard firstTree.resize(focusedID: "A", direction: .left) else {
            fail("left key should move the containing horizontal split left from the first child")
        }
        var slots = firstTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.445, height: 1), "first child shrinks when divider moves left")
        expectEqual(slots["B"]!, TileSlot(x: 0.445, y: 0, width: 0.555, height: 1), "second child grows when divider moves left")
        guard firstTree.resize(focusedID: "A", direction: .right) else {
            fail("right key should move the containing horizontal split right from the first child")
        }
        slots = firstTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "first child returns to even split")
        expectEqual(slots["B"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "second child returns to even split")
        var secondTree = BSPTree<String>()
        secondTree.insert("A", near: nil)
        secondTree.insert("B", near: "A")
        guard secondTree.resize(focusedID: "B", direction: .right) else {
            fail("right key should move the containing horizontal split right from the second child")
        }
        slots = secondTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.555, height: 1), "first child grows when divider moves right")
        expectEqual(slots["B"]!, TileSlot(x: 0.555, y: 0, width: 0.445, height: 1), "second child shrinks when divider moves right")
        guard secondTree.resize(focusedID: "B", direction: .left) else {
            fail("left key should move the containing horizontal split left from the second child")
        }
        slots = secondTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 0.5, height: 1), "first child returns to even split")
        expectEqual(slots["B"]!, TileSlot(x: 0.5, y: 0, width: 0.5, height: 1), "second child returns to even split")
        var topTree = BSPTree<String>()
        topTree.insert("A", near: nil)
        topTree.insert("B", near: "A", placement: .split(.down))
        guard topTree.resize(focusedID: "A", direction: .up) else {
            fail("up key should move the containing vertical split up from the first child")
        }
        slots = topTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.445), "top child shrinks when divider moves up")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.445, width: 1, height: 0.555), "bottom child grows when divider moves up")
        guard topTree.resize(focusedID: "A", direction: .down) else {
            fail("down key should move the containing vertical split down from the first child")
        }
        slots = topTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.5), "top child returns to even split")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.5, width: 1, height: 0.5), "bottom child returns to even split")
        var bottomTree = BSPTree<String>()
        bottomTree.insert("A", near: nil)
        bottomTree.insert("B", near: "A", placement: .split(.down))
        guard bottomTree.resize(focusedID: "B", direction: .down) else {
            fail("down key should move the containing vertical split down from the second child")
        }
        slots = bottomTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.555), "top child grows when divider moves down")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.555, width: 1, height: 0.445), "bottom child shrinks when divider moves down")
        guard bottomTree.resize(focusedID: "B", direction: .up) else {
            fail("up key should move the containing vertical split up from the second child")
        }
        slots = bottomTree.slots()
        expectEqual(slots["A"]!, TileSlot(x: 0, y: 0, width: 1, height: 0.5), "top child returns to even split")
        expectEqual(slots["B"]!, TileSlot(x: 0, y: 0.5, width: 1, height: 0.5), "bottom child returns to even split")
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
        expectUsableNonOverlappingFrames(tree, screen: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, "balanced tree")
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
    private static func testNormalizedSlotClampsToUnitBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let slot = TileSlot.normalized(from: CGRect(x: 1200, y: 900, width: 200, height: 160), in: screen)
        guard slot.x >= 0, slot.y >= 0, slot.width >= TileLayout.minimumSlotSize,
              slot.height >= TileLayout.minimumSlotSize, slot.maxX <= 1, slot.maxY <= 1 else {
            fail("normalized slot escaped unit bounds: \(slot)")
        }
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
    private static func testWindowIdentitySurvivesRenumberByElement() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let first = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let renumbered = registry.identity(
            for: WindowOrderKey(pid: pid, number: 400),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        guard first == renumbered else {
            fail("same AX element should keep its identity across CG window renumbering")
        }
    }
    private static func testWindowIdentitySurvivesRenumberBySignature() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Mission Control Stable Window")
        let first = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        let renumbered = registry.identity(
            for: WindowOrderKey(pid: pid, number: 400),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: signature
        )
        guard first == renumbered else {
            fail("same stable signature should keep its identity across CG window renumbering")
        }
    }
    private static func testWindowIdentityRejectsReusedNumberWithDifferentSignature() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let first = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: windowSignature(pid: pid, title: "Original Window")
        )
        let reusedNumber = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: windowSignature(pid: pid, title: "Replacement Window")
        )
        guard first != reusedNumber else {
            fail("same CG window number with a different known signature should not inherit stale identity")
        }
    }
    private static func testWindowIdentityDoesNotReuseSignatureAcrossDisplays() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let first = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: windowSignature(pid: pid, title: "Same Title", stateKey: "display-a")
        )
        let otherDisplay = registry.identity(
            for: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: windowSignature(pid: pid, title: "Same Title", stateKey: "display-b")
        )
        guard first != otherDisplay else {
            fail("same title on a different display should not reuse the old tile identity")
        }
    }
    private static func testWindowIdentityPrunesStaleSignatureAliases() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Untitled")
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        registry.retainAliases(for: [])
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: signature
        )
        guard replacement != existing else {
            fail("stale signatures should not identify later unrelated windows after a scan drops the old window")
        }
    }
    private static func testWindowIdentityPrunesStaleWindowNumberAliases() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        registry.retainAliases(for: [])
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: nil
        )
        guard replacement != existing else {
            fail("stale window-number aliases should not identify later unrelated windows after a scan drops the old window")
        }
    }
    private static func testWindowIdentityPrunesStaleElementAliases() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        registry.retainAliases(for: [])
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        guard replacement != existing else {
            fail("stale AX element aliases should not identify later unrelated windows after a scan drops the old window")
        }
    }
    private static func testWindowIdentityRetainsPreservedAliases() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Floating Window")
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        registry.retainAliases(for: [existing])
        let restored = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: signature
        )
        guard restored == existing else {
            fail("retained identities should keep aliases for off-screen floating windows")
        }
    }
    private static func testWindowIdentityFindsStrongAlias() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: windowSignature(pid: pid, title: "Floating Window")
        )
        let byElement = registry.identityForStrongAlias(
            windowKey: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9001)
        )
        let byWindowNumber = registry.identityForStrongAlias(
            windowKey: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002)
        )
        guard byElement == existing, byWindowNumber == existing else {
            fail("strong alias lookup should recognize retained AX element and CG window-number aliases")
        }
    }
    private static func testWindowIdentityDoesNotTreatSignatureAsStrongAlias() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Floating Window")
        _ = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        let strongAlias = registry.identityForStrongAlias(
            windowKey: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9002)
        )
        guard strongAlias == nil else {
            fail("title/document signatures alone should not keep stale floating windows alive on the active display")
        }
    }
    private static func testWindowIdentityRemovesAliasesForStaleIdentity() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Floating Window")
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        registry.removeAliases(for: [existing])
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        guard replacement != existing else {
            fail("removed floating aliases should not attach closed-window state to future windows")
        }
    }
    private static func testWindowIdentityEvictsStaleWindowNumberAlias() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let renumberedExisting = registry.identity(
            for: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: nil
        )
        guard existing == renumberedExisting, replacement != existing else {
            fail("old window-number aliases should be evicted when a window is re-keyed")
        }
    }
    private static func testWindowIdentityEvictsStaleSignatureAlias() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let originalSignature = windowSignature(pid: pid, title: "Original Title")
        let updatedSignature = windowSignature(pid: pid, title: "Updated Title")
        let existing = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: originalSignature
        )
        let updatedExisting = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: updatedSignature
        )
        let replacement = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: originalSignature
        )
        guard existing == updatedExisting, replacement != existing else {
            fail("old signature aliases should be evicted when a window signature changes")
        }
    }
    private static func testWindowIdentityAvoidsAlreadySeenWindowNumberIdentity() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let existing = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let renumberedExisting = registry.identity(
            for: WindowOrderKey(pid: pid, number: 200),
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let replacement = registry.identity(
            for: WindowOrderKey(pid: pid, number: 100),
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: nil,
            avoidingIdentities: [renumberedExisting]
        )
        guard existing == renumberedExisting, replacement != existing else {
            fail("stale window-number fallback should not collapse a new window into an identity already seen this scan")
        }
    }
    private static func testWindowIdentityAvoidsAlreadySeenSignatureIdentity() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let signature = windowSignature(pid: pid, title: "Reusable Title")
        let existing = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: signature
        )
        let replacement = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: signature,
            avoidingIdentities: [existing]
        )
        guard replacement != existing else {
            fail("stale signatures should not collapse a new window into an identity already seen this scan")
        }
    }
    private static func testWindowIdentityCreatesDistinctUnnumberedWindows() {
        var registry = WindowIdentityRegistry()
        let pid: pid_t = 42
        let first = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9001),
            signature: nil
        )
        let second = registry.identity(
            for: nil,
            elementKey: WindowElementKey(pid: pid, hash: 9002),
            signature: nil
        )
        guard first != second else {
            fail("different AX elements without CG window numbers should still become distinct tile identities")
        }
    }
    private static func testWindowLayoutIdentityMatchesStrongComponentWhenTitleChanges() {
        let stored = layoutIdentity(document: "file:///tmp/report.txt", title: "Old Title")
        let visible = layoutIdentity(document: "file:///tmp/report.txt", title: "New Title")
        let replacements = WindowLayoutIdentityMatcher.replacements(
            stored: [(id: "old", identity: stored)],
            visible: [(id: "new", identity: visible)]
        )
        guard replacements["old"] == "new" else {
            fail("layout identity should match by stable document even when a volatile title changes")
        }
    }
    private static func testWindowLayoutIdentityRejectsDuplicateWeakMatches() {
        let stored = [
            (id: "old-a", identity: layoutIdentity(title: "Untitled")),
            (id: "old-b", identity: layoutIdentity(title: "Untitled"))
        ]
        let visible = [(id: "new", identity: layoutIdentity(title: "Untitled"))]
        guard WindowLayoutIdentityMatcher.replacements(stored: stored, visible: visible).isEmpty else {
            fail("duplicate layout identity keys should not be matched ambiguously")
        }
    }
    private static func testWindowLayoutIdentityRejectsWeakMatchWhenStrongComponentConflicts() {
        let stored = layoutIdentity(document: "file:///tmp/old.txt", title: "Untitled")
        let visible = layoutIdentity(document: "file:///tmp/new.txt", title: "Untitled")
        let replacements = WindowLayoutIdentityMatcher.replacements(
            stored: [(id: "old", identity: stored)],
            visible: [(id: "new", identity: visible)]
        )
        guard replacements.isEmpty else {
            fail("layout identity should not fall back to matching weak titles after stable documents conflict")
        }
    }
    private static func windowSignature(pid: pid_t, title: String, stateKey: String = "display-a") -> WindowSignature {
        WindowSignature(
            pid: pid,
            stateKey: stateKey,
            bundleIdentifier: "com.local.test",
            axIdentifier: nil,
            document: nil,
            title: title
        )
    }
    private static func layoutIdentity(
        pid: pid_t = 42,
        axIdentifier: String? = nil,
        document: String? = nil,
        title: String? = nil
    ) -> WindowLayoutIdentity {
        WindowLayoutIdentity(
            pid: pid,
            bundleIdentifier: "com.local.test",
            axIdentifier: axIdentifier,
            document: document,
            title: title
        )
    }
    private static func expectUsableNonOverlappingFrames(_ tree: BSPTree<String>, screen: CGRect, gap: CGFloat, _ message: String) {
        let frames = tree.slotList().map { item in
            item.slot.frame(in: screen, gap: gap, smartOuterGap: true)
        }
        for lhsIndex in frames.indices {
            for rhsIndex in frames.indices where rhsIndex > lhsIndex {
                let intersection = frames[lhsIndex].intersection(frames[rhsIndex])
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                guard area <= 0.001 else {
                    fail("\(message) produced overlapping frames: \(frames[lhsIndex]) and \(frames[rhsIndex])")
                }
            }
        }
    }
    private static func expectEqual(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        guard actual == expected else {
            fail("\(message)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }
    private static func expectEqual(_ actual: TileSlot, _ expected: TileSlot, _ message: String) {
        guard approximatelyEqual(actual.x, expected.x),
              approximatelyEqual(actual.y, expected.y),
              approximatelyEqual(actual.width, expected.width),
              approximatelyEqual(actual.height, expected.height) else {
            fail("\(message)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }
    private static func fail(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(1)
    }
    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= 0.001
    }
}
