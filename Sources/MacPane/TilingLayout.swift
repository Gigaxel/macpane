import CoreGraphics
struct TileSlot: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var maxX: CGFloat { x + width }
    var maxY: CGFloat { y + height }
    var midX: CGFloat { x + width / 2 }
    var midY: CGFloat { y + height / 2 }
    var area: CGFloat { width * height }
    func frame(in screen: CGRect, gap: CGFloat, smartOuterGap: Bool) -> CGRect {
        let gap = max(0, gap)
        let outerGap = smartOuterGap ? gap : 0
        let usable = screen.insetBy(dx: outerGap, dy: outerGap)
        let halfInnerGap = gap / 2
        var frame = CGRect(
            x: usable.minX + x * usable.width,
            y: usable.minY + y * usable.height,
            width: width * usable.width,
            height: height * usable.height
        )
        if x > TileLayout.epsilon {
            frame.origin.x += halfInnerGap
            frame.size.width -= halfInnerGap
        }
        if maxX < 1 - TileLayout.epsilon {
            frame.size.width -= halfInnerGap
        }
        if y > TileLayout.epsilon {
            frame.origin.y += halfInnerGap
            frame.size.height -= halfInnerGap
        }
        if maxY < 1 - TileLayout.epsilon {
            frame.size.height -= halfInnerGap
        }
        return CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }
    static func normalized(from frame: CGRect, in screen: CGRect) -> TileSlot {
        guard screen.width > 0, screen.height > 0 else {
            return TileSlot(x: 0, y: 0, width: 1, height: 1)
        }
        return TileSlot(
            x: clamped((frame.minX - screen.minX) / screen.width, minimum: 0, maximum: 1),
            y: clamped((frame.minY - screen.minY) / screen.height, minimum: 0, maximum: 1),
            width: clamped(frame.width / screen.width, minimum: TileLayout.minimumSlotSize, maximum: 1),
            height: clamped(frame.height / screen.height, minimum: TileLayout.minimumSlotSize, maximum: 1)
        ).clampedToUnit()
    }
    private func clampedToUnit() -> TileSlot {
        var slot = self
        slot.width = clamped(slot.width, minimum: TileLayout.minimumSlotSize, maximum: 1)
        slot.height = clamped(slot.height, minimum: TileLayout.minimumSlotSize, maximum: 1)
        slot.x = clamped(slot.x, minimum: 0, maximum: max(0, 1 - slot.width))
        slot.y = clamped(slot.y, minimum: 0, maximum: max(0, 1 - slot.height))
        return slot
    }
}
enum TileAxis {
    /// Left/right split. The first child occupies the left side.
    case horizontal
    /// Top/bottom split. The first child occupies the top side.
    case vertical
    static func bestForSplitting(_ slot: TileSlot) -> TileAxis {
        slot.width >= slot.height ? .horizontal : .vertical
    }
    var toggled: TileAxis {
        switch self {
        case .horizontal: return .vertical
        case .vertical: return .horizontal
        }
    }
}
enum TilePlacement: Equatable {
    case automatic
    case split(SnapDirection)
    case swap
}
enum TileLayout {
    static let epsilon: CGFloat = 0.001
    static let resizeStep: CGFloat = 0.055
    static let minimumSplitRatio: CGFloat = 0.12
    static let minimumSlotSize: CGFloat = 0.04
    static let resizeReflectionThreshold: CGFloat = 0.018
    static let minimumWindowFrameSize = CGSize(width: 180, height: 120)
    static func maximumSpatialTileCount(
        in screen: CGRect,
        gap: CGFloat,
        minimumFrameSize: CGSize = TileLayout.minimumWindowFrameSize
    ) -> Int {
        guard screen.width > 0, screen.height > 0,
              minimumFrameSize.width > 0, minimumFrameSize.height > 0 else {
            return 1
        }
        let gap = max(0, gap)
        let maxColumns = floor((screen.width - gap) / (minimumFrameSize.width + gap))
        let maxRows = floor((screen.height - gap) / (minimumFrameSize.height + gap))
        return max(1, Int(maxColumns) * Int(maxRows))
    }
}
extension SnapDirection {
    var splitAxis: TileAxis {
        switch self {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }
    var insertsBeforeTarget: Bool {
        switch self {
        case .left, .up:
            return true
        case .right, .down:
            return false
        }
    }
}
/// A minimal, yabai-inspired binary-space-partition tree.
///
/// The tree contains only leaves and splits. There are deliberately no stack nodes here: every tiled
/// window gets one unique spatial leaf, so two unrelated apps never intentionally receive the same frame.
struct BSPTree<ID: Hashable> {
    private var root: BSPNode<ID>?
    var isEmpty: Bool { root == nil }
    var ids: [ID] { root?.ids ?? [] }
    var firstID: ID? { ids.first }
    var tileCount: Int { ids.count }
    init() {}
    private init(root: BSPNode<ID>?) {
        self.root = root
    }
    init(_ id: ID) {
        root = .leaf(id)
    }
    func contains(_ id: ID) -> Bool {
        root?.contains(id) ?? false
    }
    mutating func replaceIDs(_ replacements: [ID: ID]) -> Bool {
        guard !replacements.isEmpty, let currentRoot = root else { return false }
        var changed = false
        let nextRoot = currentRoot.mapIDs { id in
            let replacement = replacements[id] ?? id
            if replacement != id {
                changed = true
            }
            return replacement
        }
        guard changed else { return false }
        let nextIDs = nextRoot.ids
        guard Set(nextIDs).count == nextIDs.count else { return false }
        root = nextRoot
        return true
    }
    func compactMapIDs<NewID: Hashable>(_ transform: (ID) -> NewID?) -> BSPTree<NewID>? {
        guard let root else { return BSPTree<NewID>() }
        guard let nextRoot = root.compactMapIDs(transform) else { return nil }
        let nextIDs = nextRoot.ids
        guard Set(nextIDs).count == nextIDs.count else { return nil }
        return BSPTree<NewID>(root: nextRoot)
    }
    func slot(for id: ID) -> TileSlot? {
        slots()[id]
    }
    func slots() -> [ID: TileSlot] {
        guard let root else { return [:] }
        var output: [ID: TileSlot] = [:]
        root.collectSlots(in: TileSlot(x: 0, y: 0, width: 1, height: 1), into: &output)
        return output
    }
    func slotList() -> [(id: ID, slot: TileSlot)] {
        guard let root else { return [] }
        var output: [(id: ID, slot: TileSlot)] = []
        root.collectSlotList(in: TileSlot(x: 0, y: 0, width: 1, height: 1), into: &output)
        return output
    }
    mutating func removeMissing(keeping liveIDs: Set<ID>) {
        for id in ids where !liveIDs.contains(id) {
            remove(id)
        }
    }
    mutating func remove(_ id: ID) {
        root = root?.removing(id)
    }
    mutating func insert(_ id: ID, near requestedTarget: ID?, placement: TilePlacement = .automatic) {
        guard root != nil else {
            root = .leaf(id)
            return
        }
        guard !contains(id) else { return }
        let currentSlots = slots()
        let targetID = resolvedTargetID(requestedTarget, slots: currentSlots)
        guard let targetID else {
            root = .leaf(id)
            return
        }
        let targetSlot = currentSlots[targetID] ?? TileSlot(x: 0, y: 0, width: 1, height: 1)
        let axis: TileAxis
        let newFirst: Bool
        switch placement {
        case .automatic, .swap:
            axis = TileAxis.bestForSplitting(targetSlot)
            newFirst = false
        case .split(let direction):
            axis = direction.splitAxis
            newFirst = direction.insertsBeforeTarget
        }
        root = root?.inserting(id, near: targetID, axis: axis, newFirst: newFirst)
    }
    mutating func move(_ id: ID, onto target: ID, placement: TilePlacement) -> Bool {
        guard id != target, contains(id), contains(target) else { return false }
        if placement == .swap {
            return swap(id, target)
        }
        remove(id)
        guard contains(target) else {
            insert(id, near: nil, placement: .automatic)
            return true
        }
        insert(id, near: target, placement: placement)
        return true
    }
    func largestLeafID() -> ID? {
        var best: (id: ID, slot: TileSlot)?
        for item in slotList() {
            guard let current = best else {
                best = item
                continue
            }
            if item.slot.area > current.slot.area + TileLayout.epsilon {
                best = item
            }
        }
        return best?.id
    }
    func neighborID(from focusedID: ID, direction: SnapDirection) -> ID? {
        let allSlots = slotList()
        guard let focused = allSlots.first(where: { $0.id == focusedID })?.slot else { return nil }
        let source = sideCenter(of: focused, leaving: direction)
        var best: (id: ID, score: CGFloat, overlap: CGFloat)?
        for (id, candidate) in allSlots where id != focusedID {
            guard isCandidate(candidate, from: focused, direction: direction) else { continue }
            let target = sideCenter(of: candidate, enteringFrom: direction)
            let dx = source.x - target.x
            let dy = source.y - target.y
            let distanceSquared = dx * dx + dy * dy
            let overlap = perpendicularOverlap(focused, candidate, direction: direction)
            let score = distanceSquared - overlap * overlap * 0.25
            if best == nil || score < best!.score - TileLayout.epsilon ||
                (approximatelyEqual(score, best!.score) && overlap > best!.overlap) {
                best = (id, score, overlap)
            }
        }
        return best?.id
    }
    mutating func swap(_ firstID: ID, _ secondID: ID) -> Bool {
        guard firstID != secondID, let currentRoot = root,
              currentRoot.contains(firstID), currentRoot.contains(secondID) else {
            return false
        }
        root = currentRoot.mapIDs { id in
            if id == firstID { return secondID }
            if id == secondID { return firstID }
            return id
        }
        return true
    }
    mutating func resize(focusedID: ID, direction: SnapDirection) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.resize(
            focusedID: focusedID,
            direction: direction,
            step: TileLayout.resizeStep,
            minimumRatio: TileLayout.minimumSplitRatio
        )
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func reflectResize(focusedID: ID, observedSlot: TileSlot) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.reflectResize(
            focusedID: focusedID,
            observedSlot: observedSlot,
            in: TileSlot(x: 0, y: 0, width: 1, height: 1),
            minimumRatio: TileLayout.minimumSplitRatio
        )
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func toggleOrientation(focusedID: ID) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.toggleOrientation(containing: focusedID)
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func balance() {
        guard !ids.isEmpty else { return }
        root = BSPNode.balanced(from: ids[...], axis: .horizontal)
    }
    mutating func limitTileCount(to maxCount: Int) -> [ID] {
        guard maxCount > 0 else {
            let removed = ids
            root = nil
            return removed
        }
        let currentIDs = ids
        guard currentIDs.count > maxCount else { return [] }
        let kept = Array(currentIDs.prefix(maxCount))
        let removed = Array(currentIDs.dropFirst(maxCount))
        root = BSPNode.balanced(from: kept[...], axis: .horizontal)
        return removed
    }
    private func resolvedTargetID(_ requested: ID?, slots _: [ID: TileSlot]) -> ID? {
        if let requested, contains(requested) {
            return requested
        }
        return largestLeafID() ?? firstID
    }
    private func sideCenter(of slot: TileSlot, leaving direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: slot.x, y: slot.midY)
        case .right: return CGPoint(x: slot.maxX, y: slot.midY)
        case .up: return CGPoint(x: slot.midX, y: slot.y)
        case .down: return CGPoint(x: slot.midX, y: slot.maxY)
        }
    }
    private func sideCenter(of slot: TileSlot, enteringFrom direction: SnapDirection) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: slot.maxX, y: slot.midY)
        case .right: return CGPoint(x: slot.x, y: slot.midY)
        case .up: return CGPoint(x: slot.midX, y: slot.maxY)
        case .down: return CGPoint(x: slot.midX, y: slot.y)
        }
    }
    private func isCandidate(_ candidate: TileSlot, from focused: TileSlot, direction: SnapDirection) -> Bool {
        switch direction {
        case .left: return candidate.midX < focused.midX - TileLayout.epsilon
        case .right: return candidate.midX > focused.midX + TileLayout.epsilon
        case .up: return candidate.midY < focused.midY - TileLayout.epsilon
        case .down: return candidate.midY > focused.midY + TileLayout.epsilon
        }
    }
    private func perpendicularOverlap(_ lhs: TileSlot, _ rhs: TileSlot, direction: SnapDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return max(0, min(lhs.maxY, rhs.maxY) - max(lhs.y, rhs.y))
        case .up, .down:
            return max(0, min(lhs.maxX, rhs.maxX) - max(lhs.x, rhs.x))
        }
    }
}
private indirect enum BSPNode<ID: Hashable> {
    case leaf(ID)
    case split(axis: TileAxis, ratio: CGFloat, first: BSPNode<ID>, second: BSPNode<ID>)
    var ids: [ID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.ids + second.ids
        }
    }
    func contains(_ id: ID) -> Bool {
        switch self {
        case .leaf(let current):
            return current == id
        case .split(_, _, let first, let second):
            return first.contains(id) || second.contains(id)
        }
    }
    static func balanced(from ids: ArraySlice<ID>, axis: TileAxis) -> BSPNode<ID>? {
        guard !ids.isEmpty else { return nil }
        guard ids.count > 1 else { return .leaf(ids[ids.startIndex]) }
        let middle = ids.index(ids.startIndex, offsetBy: ids.count / 2)
        let firstIDs = ids[..<middle]
        let secondIDs = ids[middle...]
        guard let first = balanced(from: firstIDs, axis: axis.toggled),
              let second = balanced(from: secondIDs, axis: axis.toggled) else {
            return nil
        }
        let ratio = clamped(
            CGFloat(firstIDs.count) / CGFloat(ids.count),
            minimum: TileLayout.minimumSplitRatio,
            maximum: 1 - TileLayout.minimumSplitRatio
        )
        return .split(axis: axis, ratio: ratio, first: first, second: second)
    }
    func collectSlots(in slot: TileSlot, into output: inout [ID: TileSlot]) {
        switch self {
        case .leaf(let id):
            output[id] = slot
        case .split(let axis, let ratio, let first, let second):
            let (firstSlot, secondSlot) = splitSlots(slot, axis: axis, ratio: ratio)
            first.collectSlots(in: firstSlot, into: &output)
            second.collectSlots(in: secondSlot, into: &output)
        }
    }
    func collectSlotList(in slot: TileSlot, into output: inout [(id: ID, slot: TileSlot)]) {
        switch self {
        case .leaf(let id):
            output.append((id, slot))
        case .split(let axis, let ratio, let first, let second):
            let (firstSlot, secondSlot) = splitSlots(slot, axis: axis, ratio: ratio)
            first.collectSlotList(in: firstSlot, into: &output)
            second.collectSlotList(in: secondSlot, into: &output)
        }
    }
    func inserting(_ id: ID, near target: ID, axis: TileAxis, newFirst: Bool) -> BSPNode<ID> {
        switch self {
        case .leaf(let current):
            guard current == target else { return self }
            if newFirst {
                return .split(axis: axis, ratio: 0.5, first: .leaf(id), second: self)
            }
            return .split(axis: axis, ratio: 0.5, first: self, second: .leaf(id))
        case .split(let splitAxis, let ratio, let first, let second):
            if first.contains(target) {
                return .split(
                    axis: splitAxis,
                    ratio: ratio,
                    first: first.inserting(id, near: target, axis: axis, newFirst: newFirst),
                    second: second
                )
            }
            if second.contains(target) {
                return .split(
                    axis: splitAxis,
                    ratio: ratio,
                    first: first,
                    second: second.inserting(id, near: target, axis: axis, newFirst: newFirst)
                )
            }
            return self
        }
    }
    func removing(_ id: ID) -> BSPNode<ID>? {
        switch self {
        case .leaf(let current):
            return current == id ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case (.some(let first), .some(let second)):
                return .split(axis: axis, ratio: ratio, first: first, second: second)
            case (.some(let only), .none):
                return only
            case (.none, .some(let only)):
                return only
            case (.none, .none):
                return nil
            }
        }
    }
    func mapIDs(_ transform: (ID) -> ID) -> BSPNode<ID> {
        switch self {
        case .leaf(let id):
            return .leaf(transform(id))
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.mapIDs(transform), second: second.mapIDs(transform))
        }
    }
    func compactMapIDs<NewID: Hashable>(_ transform: (ID) -> NewID?) -> BSPNode<NewID>? {
        switch self {
        case .leaf(let id):
            guard let nextID = transform(id) else { return nil }
            return .leaf(nextID)
        case .split(let axis, let ratio, let first, let second):
            guard let nextFirst = first.compactMapIDs(transform),
                  let nextSecond = second.compactMapIDs(transform) else {
                return nil
            }
            return .split(axis: axis, ratio: ratio, first: nextFirst, second: nextSecond)
        }
    }
    mutating func resize(focusedID: ID, direction: SnapDirection, step: CGFloat, minimumRatio: CGFloat) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, var ratio, var first, var second):
            if first.contains(focusedID) {
                if first.resize(focusedID: focusedID, direction: direction, step: step, minimumRatio: minimumRatio) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                return updateRatio(&ratio, direction: direction, step: step, axis: axis, first: first, second: second, minimumRatio: minimumRatio)
            }
            if second.contains(focusedID) {
                if second.resize(focusedID: focusedID, direction: direction, step: step, minimumRatio: minimumRatio) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                return updateRatio(&ratio, direction: direction, step: step, axis: axis, first: first, second: second, minimumRatio: minimumRatio)
            }
            return false
        }
    }
    mutating func reflectResize(focusedID: ID, observedSlot: TileSlot, in slot: TileSlot, minimumRatio: CGFloat) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, var ratio, var first, var second):
            let (firstSlot, secondSlot) = splitSlots(slot, axis: axis, ratio: ratio)
            if first.contains(focusedID) {
                if first.reflectResize(focusedID: focusedID, observedSlot: observedSlot, in: firstSlot, minimumRatio: minimumRatio) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                let reflectedRatio: CGFloat
                switch axis {
                case .horizontal:
                    reflectedRatio = (observedSlot.maxX - slot.x) / max(TileLayout.epsilon, slot.width)
                case .vertical:
                    reflectedRatio = (observedSlot.maxY - slot.y) / max(TileLayout.epsilon, slot.height)
                }
                return setReflectedRatio(reflectedRatio, axis: axis, ratio: &ratio, first: first, second: second, minimumRatio: minimumRatio)
            }
            if second.contains(focusedID) {
                if second.reflectResize(focusedID: focusedID, observedSlot: observedSlot, in: secondSlot, minimumRatio: minimumRatio) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                let reflectedRatio: CGFloat
                switch axis {
                case .horizontal:
                    reflectedRatio = (observedSlot.x - slot.x) / max(TileLayout.epsilon, slot.width)
                case .vertical:
                    reflectedRatio = (observedSlot.y - slot.y) / max(TileLayout.epsilon, slot.height)
                }
                return setReflectedRatio(reflectedRatio, axis: axis, ratio: &ratio, first: first, second: second, minimumRatio: minimumRatio)
            }
            return false
        }
    }
    mutating func toggleOrientation(containing focusedID: ID) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, let ratio, var first, var second):
            if first.contains(focusedID) {
                if first.toggleOrientation(containing: focusedID) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                self = .split(axis: axis.toggled, ratio: ratio, first: first, second: second)
                return true
            }
            if second.contains(focusedID) {
                if second.toggleOrientation(containing: focusedID) {
                    self = .split(axis: axis, ratio: ratio, first: first, second: second)
                    return true
                }
                self = .split(axis: axis.toggled, ratio: ratio, first: first, second: second)
                return true
            }
            return false
        }
    }
    private mutating func updateRatio(
        _ ratio: inout CGFloat,
        direction: SnapDirection,
        step: CGFloat,
        axis: TileAxis,
        first: BSPNode<ID>,
        second: BSPNode<ID>,
        minimumRatio: CGFloat
    ) -> Bool {
        switch (axis, direction) {
        case (.horizontal, .left), (.vertical, .up):
            return updateRatio(&ratio, delta: -step, axis: axis, first: first, second: second, minimumRatio: minimumRatio)
        case (.horizontal, .right), (.vertical, .down):
            return updateRatio(&ratio, delta: step, axis: axis, first: first, second: second, minimumRatio: minimumRatio)
        default:
            return false
        }
    }
    private mutating func updateRatio(
        _ ratio: inout CGFloat,
        delta: CGFloat,
        axis: TileAxis,
        first: BSPNode<ID>,
        second: BSPNode<ID>,
        minimumRatio: CGFloat
    ) -> Bool {
        let nextRatio = clamped(ratio + delta, minimum: minimumRatio, maximum: 1 - minimumRatio)
        guard !approximatelyEqual(nextRatio, ratio) else { return false }
        ratio = nextRatio
        self = .split(axis: axis, ratio: ratio, first: first, second: second)
        return true
    }
    private mutating func setReflectedRatio(
        _ reflectedRatio: CGFloat,
        axis: TileAxis,
        ratio: inout CGFloat,
        first: BSPNode<ID>,
        second: BSPNode<ID>,
        minimumRatio: CGFloat
    ) -> Bool {
        let nextRatio = clamped(reflectedRatio, minimum: minimumRatio, maximum: 1 - minimumRatio)
        guard abs(nextRatio - ratio) >= TileLayout.resizeReflectionThreshold else { return false }
        ratio = nextRatio
        self = .split(axis: axis, ratio: ratio, first: first, second: second)
        return true
    }
}
private func splitSlots(_ slot: TileSlot, axis: TileAxis, ratio rawRatio: CGFloat) -> (TileSlot, TileSlot) {
    let ratio = clamped(rawRatio, minimum: TileLayout.minimumSplitRatio, maximum: 1 - TileLayout.minimumSplitRatio)
    switch axis {
    case .horizontal:
        return (
            TileSlot(x: slot.x, y: slot.y, width: slot.width * ratio, height: slot.height),
            TileSlot(x: slot.x + slot.width * ratio, y: slot.y, width: slot.width * (1 - ratio), height: slot.height)
        )
    case .vertical:
        return (
            TileSlot(x: slot.x, y: slot.y, width: slot.width, height: slot.height * ratio),
            TileSlot(x: slot.x, y: slot.y + slot.height * ratio, width: slot.width, height: slot.height * (1 - ratio))
        )
    }
}
private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(value, minimum), maximum)
}
private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) <= TileLayout.epsilon
}
