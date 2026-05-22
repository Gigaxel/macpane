import CoreGraphics

enum WindowDropPlanner {
    static func dropAction(cursor: CGPoint, targetFrame: CGRect) -> DropAction {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return .split(.right) }
        if targetFrame.contains(cursor) {
            let relativeX = (cursor.x - targetFrame.minX) / targetFrame.width
            let relativeY = (cursor.y - targetFrame.minY) / targetFrame.height
            if relativeX > 0.33, relativeX < 0.67, relativeY > 0.33, relativeY < 0.67 {
                return .swap
            }
        }
        let distances: [(direction: SnapDirection, distance: CGFloat)] = [
            (.left, abs(cursor.x - targetFrame.minX)),
            (.right, abs(cursor.x - targetFrame.maxX)),
            (.up, abs(cursor.y - targetFrame.minY)),
            (.down, abs(cursor.y - targetFrame.maxY))
        ]
        return .split(distances.min { $0.distance < $1.distance }?.direction ?? .right)
    }

    static func targetWindowForDrop(cursor: CGPoint, moving: ManagedWindow, candidates: [ManagedWindow]) -> ManagedWindow? {
        let containing = candidates
            .filter { $0.frame.contains(cursor) }
            .min { lhs, rhs in lhs.frame.area < rhs.frame.area }
        if let containing {
            return containing
        }
        let overlapping = candidates.compactMap { candidate -> (window: ManagedWindow, area: CGFloat)? in
            let intersection = candidate.frame.intersection(moving.frame)
            let area = intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
            guard area > min(candidate.frame.area, moving.frame.area) * 0.08 else { return nil }
            return (candidate, area)
        }.max { lhs, rhs in lhs.area < rhs.area }
        if let overlapping {
            return overlapping.window
        }
        return candidates.min { lhs, rhs in
            lhs.frame.distanceSquared(to: cursor) < rhs.frame.distanceSquared(to: cursor)
        }
    }
}
