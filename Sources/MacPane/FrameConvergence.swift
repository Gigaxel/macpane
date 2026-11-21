import ApplicationServices
import CoreGraphics

/// What a window's frame should become.
enum FrameGoal: Equatable {
    /// An exact frame.
    case tile(CGRect)
    /// An origin only: a parked window keeps whatever size it has. `clearing` is the display it
    /// has to get off.
    case park(CGPoint, clearing: CGRect)
}

/// How far one window has got towards its goal.
struct FrameRecord: Equatable {
    /// A frame seen off the goal after a write, and since when it has looked like that.
    struct Settling: Equatable {
        var frame: CGRect
        var since: UInt64
    }

    var goal: FrameGoal
    var attempts = 0
    var firstAttemptAt: UInt64 = 0
    /// The write whose answer is still outstanding, and when it was sent.
    var pendingToken: Int?
    var pendingSince: UInt64 = 0
    /// False when the app did not confirm the last write, so nothing is concluded from the frame.
    var lastWriteSucceeded = true
    /// Set after a timeout: the app is given until then before it is written to again.
    var retryNotBefore: UInt64 = 0
    /// True once the window has matched this goal. A later mismatch is then a change someone else
    /// made, not a write that has yet to land.
    var hasConverged = false
    var settling: Settling?
    /// Bounds that differ from the goal but are no longer corrected.
    var accepted: CGRect?

    init(goal: FrameGoal) {
        self.goal = goal
    }
}

enum FrameDecision: Equatable {
    case none
    case write
    /// A written frame has not shown up yet, or the window is still moving. Look again at `until`.
    case settling(until: UInt64)
    /// A settled window moved while a pointer button is down: the user is dragging it.
    case userMoved
    /// The app took the write and held a larger size than asked.
    case learnMinimum(CGSize)
}

/// Decides, from a window's goal and what the WindowServer reports, whether to write its frame.
/// Every decision starts from the observed bounds, so nothing here depends on which events arrived.
enum FramePlanner {
    static let maximumAttempts = 3
    /// Attempts are forgotten after this long, so a window that refused its frame is tried again.
    static let attemptWindow: UInt64 = 10_000_000_000
    /// The WindowServer shows a new frame a moment after the app acknowledges it, and some apps
    /// animate. A frame off its goal is only judged once it has held still for this long.
    static let settleDelay: UInt64 = 50_000_000
    static let timeoutRetryDelay: UInt64 = 150_000_000
    /// An answer that has not arrived after this long is treated as lost.
    static let pendingWriteTimeout: UInt64 = 2_000_000_000
    private static let tolerance: CGFloat = 2

    static func decide(
        goal: FrameGoal,
        observed: CGRect,
        record: inout FrameRecord?,
        pointerDown: Bool,
        now: UInt64
    ) -> FrameDecision {
        var current = record.flatMap { $0.goal == goal ? $0 : nil } ?? FrameRecord(goal: goal)
        defer { record = current }

        if matches(goal, observed) {
            current.hasConverged = true
            current.attempts = 0
            current.accepted = nil
            current.settling = nil
            return .none
        }
        if current.pendingToken != nil {
            guard now &- current.pendingSince > pendingWriteTimeout else {
                return .settling(until: current.pendingSince + pendingWriteTimeout + 1)
            }
            // No answer came. Whatever the frame is now, the app never confirmed taking the write.
            current.pendingToken = nil
            current.lastWriteSucceeded = false
        }
        if let accepted = current.accepted {
            if approximatelyEqual(accepted, observed) {
                return .none
            }
            if pointerDown {
                return .userMoved
            }
            current.accepted = nil
            current.settling = nil
        }
        if current.hasConverged, pointerDown {
            return .userMoved
        }
        if current.attempts > 0 {
            if now < current.retryNotBefore {
                return .settling(until: current.retryNotBefore)
            }
            guard let settling = current.settling, approximatelyEqual(settling.frame, observed) else {
                current.settling = FrameRecord.Settling(frame: observed, since: now)
                return .settling(until: now + settleDelay)
            }
            if now &- settling.since < settleDelay {
                return .settling(until: settling.since + settleDelay)
            }
            current.settling = nil
            if current.lastWriteSucceeded, case .tile(let target) = goal {
                if case .clamped(let minimum) = FrameVerificationClassifier.classify(
                    target: target, observed: observed, tolerance: tolerance
                ) {
                    current.accepted = observed
                    return .learnMinimum(minimum)
                }
                if isShortfall(target: target, observed: observed) {
                    // Terminals snap to whole cells and some windows have a maximum size.
                    current.accepted = observed
                    return .none
                }
            }
            if current.lastWriteSucceeded, case .park(_, let display) = goal, isOffDisplay(observed, display) {
                // AppKit keeps a title bar clear of the Dock, so a parked window can stop short of
                // the corner. All but a sliver of it is off the display, which is what hides it.
                current.accepted = observed
                return .none
            }
        }
        if current.attempts > 0, now &- current.firstAttemptAt > attemptWindow {
            current.attempts = 0
        }
        guard current.attempts < maximumAttempts else {
            guard current.lastWriteSucceeded else {
                // The app has not been answering. That is not a refusal: try again later.
                return .settling(until: current.firstAttemptAt + attemptWindow + 1)
            }
            current.accepted = observed
            return .none
        }
        if current.attempts == 0 {
            current.firstAttemptAt = now
        }
        current.attempts += 1
        current.hasConverged = false
        current.settling = nil
        return .write
    }

    /// Notes that the app answered a write. What the write achieved is judged from the window's
    /// frame on the reconciles that follow, never from the answer.
    static func absorb(token: Int, error: AXError, record: inout FrameRecord?, now: UInt64) {
        guard var current = record, current.pendingToken == token else { return }
        current.pendingToken = nil
        current.lastWriteSucceeded = error == .success
        current.settling = nil
        if error == .cannotComplete {
            // The app is not answering. Give it longer each time before writing again.
            current.retryNotBefore = now + timeoutRetryDelay * UInt64(max(current.attempts, 1))
        }
        record = current
    }

    /// On the goal to within a point. The same test applies before and after a write, so a frame
    /// that counts as a match never stops counting as one.
    static func matches(_ goal: FrameGoal, _ observed: CGRect) -> Bool {
        switch goal {
        case .tile(let frame):
            return approximatelyEqual(observed, frame)
        case .park(let origin, _):
            return approximatelyEqual(observed.origin, origin)
        }
    }

    /// True when no more than a sliver of the frame is on the display.
    private static func isOffDisplay(_ frame: CGRect, _ display: CGRect) -> Bool {
        let visible = frame.intersection(display)
        return visible.isNull || visible.width <= tolerance || visible.height <= tolerance
    }

    /// In the right place and no larger than asked: the app stopped short of the size on purpose.
    private static func isShortfall(target: CGRect, observed: CGRect) -> Bool {
        approximatelyEqual(observed.origin, target.origin) &&
            observed.width <= target.width + 1 &&
            observed.height <= target.height + 1
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 && approximatelyEqual(lhs.size, rhs.size)
    }
    static func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
    static func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }

    static func sanitized(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(1, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }

    /// Where a window on a hidden workspace waits: one point of it stays on its own display, on a
    /// corner chosen so the rest does not show up on a neighboring display.
    static func parkOrigin(windowSize: CGSize, screenFrame: CGRect, otherScreenFrames: [CGRect]) -> CGPoint {
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
            return clear.origin
        }
        let scored = viable.map { candidate in
            (candidate, otherScreenFrames.reduce(CGFloat(0)) { total, other in
                let overlap = candidate.intersection(other)
                return total + max(0, overlap.width) * max(0, overlap.height)
            })
        }
        return (scored.min(by: { $0.1 < $1.1 })?.0 ?? candidates[0]).origin
    }
}
