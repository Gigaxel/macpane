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
    /// Inverse of `frame(in:gap:smartOuterGap:)`: the slot a frame occupies, given the slot it was
    /// last rendered from. That slot says which edges carry half an inner gap, so an untouched edge
    /// maps back to exactly where it was instead of reading as a small resize.
    static func observed(from frame: CGRect, in screen: CGRect, gap: CGFloat, rendered: TileSlot) -> TileSlot {
        let gap = max(0, gap)
        let usable = screen.insetBy(dx: gap, dy: gap)
        guard usable.width > 0, usable.height > 0 else { return rendered }
        let half = gap / 2
        let left = frame.minX - (rendered.x > TileLayout.epsilon ? half : 0)
        let right = frame.maxX + (rendered.maxX < 1 - TileLayout.epsilon ? half : 0)
        let top = frame.minY - (rendered.y > TileLayout.epsilon ? half : 0)
        let bottom = frame.maxY + (rendered.maxY < 1 - TileLayout.epsilon ? half : 0)
        let x = clamped((left - usable.minX) / usable.width, minimum: 0, maximum: 1)
        let y = clamped((top - usable.minY) / usable.height, minimum: 0, maximum: 1)
        let maxX = clamped((right - usable.minX) / usable.width, minimum: 0, maximum: 1)
        let maxY = clamped((bottom - usable.minY) / usable.height, minimum: 0, maximum: 1)
        return TileSlot(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
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
    static let resizeReflectionThreshold: CGFloat = 0.018
    static let minimumWindowFrameSize = CGSize(width: 180, height: 120)
    static let minimumAccommodationRatio: CGFloat = 0.02
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
    /// Every read and edit takes a `hidden` set: leaves that keep their place in the tree but take no
    /// space right now (minimized, hidden app, native fullscreen). A split with nothing visible on
    /// one side hands its whole slot to the other side and cannot be resized or rotated.
    func slots(hidden: Set<ID> = []) -> [ID: TileSlot] {
        guard let root else { return [:] }
        var output: [ID: TileSlot] = [:]
        root.collectSlots(in: TileSlot(x: 0, y: 0, width: 1, height: 1), hidden: hidden) { id, slot in
            output[id] = slot
        }
        return output
    }
    func slotList(hidden: Set<ID> = []) -> [(id: ID, slot: TileSlot)] {
        guard let root else { return [] }
        var output: [(id: ID, slot: TileSlot)] = []
        root.collectSlots(in: TileSlot(x: 0, y: 0, width: 1, height: 1), hidden: hidden) { id, slot in
            output.append((id, slot))
        }
        return output
    }

    func slotsAccommodating(
        minimums: [ID: CGSize],
        in screenFrame: CGRect,
        gap: CGFloat,
        hidden: Set<ID> = []
    ) -> [ID: TileSlot] {
        guard let root else { return [:] }
        guard !minimums.isEmpty else { return slots(hidden: hidden) }
        let gap = max(0, gap)
        let usable = screenFrame.insetBy(dx: gap, dy: gap)
        guard usable.width > 0, usable.height > 0 else { return slots(hidden: hidden) }
        var output: [ID: TileSlot] = [:]
        root.collectAccommodatedSlots(
            in: TileSlot(x: 0, y: 0, width: 1, height: 1),
            unitSize: usable.size,
            minimums: minimums,
            defaultMinimum: TileLayout.minimumWindowFrameSize,
            gap: gap,
            hidden: hidden,
            into: &output
        )
        return output
    }
    mutating func remove(_ id: ID) {
        root = root?.removing(id)
    }
    mutating func insert(
        _ id: ID,
        near requestedTarget: ID?,
        placement: TilePlacement = .automatic,
        hidden: Set<ID> = []
    ) {
        guard root != nil else {
            root = .leaf(id)
            return
        }
        guard !contains(id) else { return }
        let currentSlots = slots(hidden: hidden)
        guard let targetID = resolvedTargetID(requestedTarget, hidden: hidden) else {
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
    mutating func move(_ id: ID, onto target: ID, placement: TilePlacement, hidden: Set<ID> = []) -> Bool {
        guard id != target, contains(id), contains(target) else { return false }
        if placement == .swap {
            return swap(id, target)
        }
        remove(id)
        insert(id, near: target, placement: placement, hidden: hidden)
        return true
    }
    func largestLeafID(hidden: Set<ID> = []) -> ID? {
        var best: (id: ID, slot: TileSlot)?
        for item in slotList(hidden: hidden) {
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
    func neighborID(from focusedID: ID, direction: SnapDirection, hidden: Set<ID> = []) -> ID? {
        let allSlots = slotList(hidden: hidden)
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
    /// Puts `replacement` in the leaf `id` occupies.
    mutating func replace(_ id: ID, with replacement: ID) -> Bool {
        guard id != replacement, let currentRoot = root,
              currentRoot.contains(id), !currentRoot.contains(replacement) else {
            return false
        }
        root = currentRoot.mapIDs { $0 == id ? replacement : $0 }
        return true
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
    mutating func resize(focusedID: ID, direction: SnapDirection, hidden: Set<ID> = []) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.resize(
            focusedID: focusedID,
            direction: direction,
            step: TileLayout.resizeStep,
            minimumRatio: TileLayout.minimumSplitRatio,
            hidden: hidden
        )
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func reflectResize(focusedID: ID, observedSlot: TileSlot, hidden: Set<ID> = []) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.reflectResize(
            focusedID: focusedID,
            observedSlot: observedSlot,
            in: TileSlot(x: 0, y: 0, width: 1, height: 1),
            minimumRatio: TileLayout.minimumSplitRatio,
            hidden: hidden
        )
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func toggleOrientation(focusedID: ID, hidden: Set<ID> = []) -> Bool {
        guard var currentRoot = root, currentRoot.contains(focusedID) else { return false }
        let changed = currentRoot.toggleOrientation(containing: focusedID, hidden: hidden)
        if changed {
            root = currentRoot
        }
        return changed
    }
    mutating func balance() {
        guard !ids.isEmpty else { return }
        root = BSPNode.balanced(from: ids[...], axis: .horizontal)
    }
    private func resolvedTargetID(_ requested: ID?, hidden: Set<ID>) -> ID? {
        if let requested, contains(requested), !hidden.contains(requested) {
            return requested
        }
        return largestLeafID(hidden: hidden) ?? firstID
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
    func hasVisibleLeaf(_ hidden: Set<ID>) -> Bool {
        guard !hidden.isEmpty else { return true }
        switch self {
        case .leaf(let id):
            return !hidden.contains(id)
        case .split(_, _, let first, let second):
            return first.hasVisibleLeaf(hidden) || second.hasVisibleLeaf(hidden)
        }
    }
    /// The slots the two children occupy, or nil for a child with nothing visible in it.
    func childSlots(
        of slot: TileSlot,
        axis: TileAxis,
        ratio: CGFloat,
        first: BSPNode<ID>,
        second: BSPNode<ID>,
        hidden: Set<ID>
    ) -> (first: TileSlot?, second: TileSlot?) {
        switch (first.hasVisibleLeaf(hidden), second.hasVisibleLeaf(hidden)) {
        case (true, true):
            let (firstSlot, secondSlot) = splitSlots(slot, axis: axis, ratio: ratio)
            return (firstSlot, secondSlot)
        case (true, false):
            return (slot, nil)
        case (false, true):
            return (nil, slot)
        case (false, false):
            return (nil, nil)
        }
    }
    func collectSlots(in slot: TileSlot, hidden: Set<ID>, _ emit: (ID, TileSlot) -> Void) {
        switch self {
        case .leaf(let id):
            if !hidden.contains(id) {
                emit(id, slot)
            }
        case .split(let axis, let ratio, let first, let second):
            let slots = childSlots(of: slot, axis: axis, ratio: ratio, first: first, second: second, hidden: hidden)
            if let firstSlot = slots.first {
                first.collectSlots(in: firstSlot, hidden: hidden, emit)
            }
            if let secondSlot = slots.second {
                second.collectSlots(in: secondSlot, hidden: hidden, emit)
            }
        }
    }

    /// The space a subtree needs, measured in tile-slot pixels. A frame gives up half a gap on each
    /// side it shares, so one full gap per leaf is the bound that holds wherever the leaf sits.
    func requiredMinimumSize(
        minimums: [ID: CGSize],
        defaultMinimum: CGSize,
        gap: CGFloat,
        hidden: Set<ID>
    ) -> CGSize {
        switch self {
        case .leaf(let id):
            guard !hidden.contains(id) else { return .zero }
            let minimum = minimums[id] ?? defaultMinimum
            return CGSize(width: minimum.width + gap, height: minimum.height + gap)
        case .split(let axis, _, let first, let second):
            let firstMinimum = first.requiredMinimumSize(minimums: minimums, defaultMinimum: defaultMinimum, gap: gap, hidden: hidden)
            let secondMinimum = second.requiredMinimumSize(minimums: minimums, defaultMinimum: defaultMinimum, gap: gap, hidden: hidden)
            switch axis {
            case .horizontal:
                return CGSize(
                    width: firstMinimum.width + secondMinimum.width,
                    height: max(firstMinimum.height, secondMinimum.height)
                )
            case .vertical:
                return CGSize(
                    width: max(firstMinimum.width, secondMinimum.width),
                    height: firstMinimum.height + secondMinimum.height
                )
            }
        }
    }

    func collectAccommodatedSlots(
        in slot: TileSlot,
        unitSize: CGSize,
        minimums: [ID: CGSize],
        defaultMinimum: CGSize,
        gap: CGFloat,
        hidden: Set<ID>,
        into output: inout [ID: TileSlot]
    ) {
        switch self {
        case .leaf(let id):
            if !hidden.contains(id) {
                output[id] = slot
            }
        case .split(let axis, let ratio, let first, let second):
            let firstVisible = first.hasVisibleLeaf(hidden)
            let secondVisible = second.hasVisibleLeaf(hidden)
            guard firstVisible, secondVisible else {
                let only = firstVisible ? first : second
                if firstVisible || secondVisible {
                    only.collectAccommodatedSlots(
                        in: slot,
                        unitSize: unitSize,
                        minimums: minimums,
                        defaultMinimum: defaultMinimum,
                        gap: gap,
                        hidden: hidden,
                        into: &output
                    )
                }
                return
            }
            let firstMinimum = first.requiredMinimumSize(minimums: minimums, defaultMinimum: defaultMinimum, gap: gap, hidden: hidden)
            let secondMinimum = second.requiredMinimumSize(minimums: minimums, defaultMinimum: defaultMinimum, gap: gap, hidden: hidden)
            let availablePixels: CGFloat
            let firstMinimumPixels: CGFloat
            let secondMinimumPixels: CGFloat
            switch axis {
            case .horizontal:
                availablePixels = slot.width * unitSize.width
                firstMinimumPixels = firstMinimum.width
                secondMinimumPixels = secondMinimum.width
            case .vertical:
                availablePixels = slot.height * unitSize.height
                firstMinimumPixels = firstMinimum.height
                secondMinimumPixels = secondMinimum.height
            }
            var resolvedRatio = clamped(
                ratio,
                minimum: TileLayout.minimumSplitRatio,
                maximum: 1 - TileLayout.minimumSplitRatio
            )
            if availablePixels > 0 {
                let firstFraction = firstMinimumPixels / availablePixels
                let secondFraction = secondMinimumPixels / availablePixels
                if firstFraction + secondFraction <= 1 {
                    resolvedRatio = clamped(resolvedRatio, minimum: firstFraction, maximum: 1 - secondFraction)
                } else if firstMinimumPixels + secondMinimumPixels > 0 {
                    resolvedRatio = firstMinimumPixels / (firstMinimumPixels + secondMinimumPixels)
                }
            }
            resolvedRatio = clamped(
                resolvedRatio,
                minimum: TileLayout.minimumAccommodationRatio,
                maximum: 1 - TileLayout.minimumAccommodationRatio
            )
            let (firstSlot, secondSlot) = splitSlotsUnclamped(slot, axis: axis, ratio: resolvedRatio)
            first.collectAccommodatedSlots(
                in: firstSlot,
                unitSize: unitSize,
                minimums: minimums,
                defaultMinimum: defaultMinimum,
                gap: gap,
                hidden: hidden,
                into: &output
            )
            second.collectAccommodatedSlots(
                in: secondSlot,
                unitSize: unitSize,
                minimums: minimums,
                defaultMinimum: defaultMinimum,
                gap: gap,
                hidden: hidden,
                into: &output
            )
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
    mutating func resize(
        focusedID: ID,
        direction: SnapDirection,
        step: CGFloat,
        minimumRatio: CGFloat,
        hidden: Set<ID>
    ) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, var ratio, var first, var second):
            let isInFirst = first.contains(focusedID)
            guard isInFirst || second.contains(focusedID) else { return false }
            let resizedChild = isInFirst
                ? first.resize(focusedID: focusedID, direction: direction, step: step, minimumRatio: minimumRatio, hidden: hidden)
                : second.resize(focusedID: focusedID, direction: direction, step: step, minimumRatio: minimumRatio, hidden: hidden)
            if resizedChild {
                self = .split(axis: axis, ratio: ratio, first: first, second: second)
                return true
            }
            guard first.hasVisibleLeaf(hidden), second.hasVisibleLeaf(hidden) else { return false }
            return updateRatio(&ratio, direction: direction, step: step, axis: axis, first: first, second: second, minimumRatio: minimumRatio)
        }
    }
    mutating func reflectResize(
        focusedID: ID,
        observedSlot: TileSlot,
        in slot: TileSlot,
        minimumRatio: CGFloat,
        hidden: Set<ID>
    ) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, var ratio, var first, var second):
            let isInFirst = first.contains(focusedID)
            guard isInFirst || second.contains(focusedID) else { return false }
            let slots = childSlots(of: slot, axis: axis, ratio: ratio, first: first, second: second, hidden: hidden)
            guard let childSlot = isInFirst ? slots.first : slots.second else { return false }
            let reflectedChild = isInFirst
                ? first.reflectResize(focusedID: focusedID, observedSlot: observedSlot, in: childSlot, minimumRatio: minimumRatio, hidden: hidden)
                : second.reflectResize(focusedID: focusedID, observedSlot: observedSlot, in: childSlot, minimumRatio: minimumRatio, hidden: hidden)
            if reflectedChild {
                self = .split(axis: axis, ratio: ratio, first: first, second: second)
                return true
            }
            guard slots.first != nil, slots.second != nil else { return false }
            // The shared edge is the focused window's far edge when it is the first child and
            // its near edge when it is the second.
            let sharedEdge: CGFloat
            switch (axis, isInFirst) {
            case (.horizontal, true): sharedEdge = observedSlot.maxX - slot.x
            case (.horizontal, false): sharedEdge = observedSlot.x - slot.x
            case (.vertical, true): sharedEdge = observedSlot.maxY - slot.y
            case (.vertical, false): sharedEdge = observedSlot.y - slot.y
            }
            let extent = axis == .horizontal ? slot.width : slot.height
            return setReflectedRatio(
                sharedEdge / max(TileLayout.epsilon, extent),
                axis: axis,
                ratio: &ratio,
                first: first,
                second: second,
                minimumRatio: minimumRatio
            )
        }
    }
    mutating func toggleOrientation(containing focusedID: ID, hidden: Set<ID>) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(let axis, let ratio, var first, var second):
            let isInFirst = first.contains(focusedID)
            guard isInFirst || second.contains(focusedID) else { return false }
            let toggledChild = isInFirst
                ? first.toggleOrientation(containing: focusedID, hidden: hidden)
                : second.toggleOrientation(containing: focusedID, hidden: hidden)
            if toggledChild {
                self = .split(axis: axis, ratio: ratio, first: first, second: second)
                return true
            }
            guard first.hasVisibleLeaf(hidden), second.hasVisibleLeaf(hidden) else { return false }
            self = .split(axis: axis.toggled, ratio: ratio, first: first, second: second)
            return true
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
    return splitSlotsUnclamped(slot, axis: axis, ratio: ratio)
}

private func splitSlotsUnclamped(_ slot: TileSlot, axis: TileAxis, ratio: CGFloat) -> (TileSlot, TileSlot) {
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
