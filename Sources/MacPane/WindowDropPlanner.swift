import CoreGraphics

/// Decides what dropping a dragged window means from where the pointer let go.
enum WindowDropPlanner {
    /// The middle third of a tile swaps the two windows; anywhere else splits the tile on the
    /// nearest edge.
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

    /// The tile a window was dropped on: the one under the pointer, else the one it overlaps most,
    /// else the nearest. `candidates` are the other tiles on the display the drop landed on.
    static func target(
        cursor: CGPoint,
        movingFrame: CGRect,
        candidates: [(id: WindowID, frame: CGRect)]
    ) -> (id: WindowID, frame: CGRect)? {
        if let containing = candidates
            .filter({ $0.frame.contains(cursor) })
            .min(by: { $0.frame.area < $1.frame.area }) {
            return containing
        }
        let overlapping = candidates.compactMap { candidate -> (candidate: (id: WindowID, frame: CGRect), area: CGFloat)? in
            let intersection = candidate.frame.intersection(movingFrame)
            let area = intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
            guard area > min(candidate.frame.area, movingFrame.area) * 0.08 else { return nil }
            return (candidate, area)
        }.max { $0.area < $1.area }
        if let overlapping {
            return overlapping.candidate
        }
        return candidates.min { $0.frame.distanceSquared(to: cursor) < $1.frame.distanceSquared(to: cursor) }
    }
}
