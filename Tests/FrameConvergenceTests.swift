import ApplicationServices
import CoreGraphics
import Foundation

extension TilingTests {
    static func runFrameConvergenceTests() {
        testConvergedWindowIsLeftAlone()
        testMismatchWritesOnceAndWaitsForTheAnswer()
        testGoalChangeStartsOver()
        testWrittenFrameIsGivenTimeToShowUp()
        testFrameThatLandsLateConverges()
        testMovingFrameRestartsTheSettleClock()
        testAttemptBudgetStopsAFight()
        testAttemptBudgetComesBackAfterAWhile()
        testLostAnswerIsNotWaitedOnForever()
        testPointerDragIsNotFought()
        testWindowBeingLaidOutIsNotMistakenForADrag()
        testSettledClampIsLearnedOnce()
        testClampIsNotLearnedFromAnUnconfirmedWrite()
        testSettledShortfallIsAccepted()
        testTimeoutBacksOff()
        testStaleAnswerIsIgnored()
        testParkGoalOnlyCaresAboutOrigin()
        testParkStoppedShortOfTheCornerIsAccepted()
        testParkLeftInViewIsNotAccepted()
        testParkOnNeighboringDisplayIsNotAccepted()
        testFrameTwoPointsOffSettlesWithoutLooping()
        testUnansweredWritesAreRetriedLater()
        testSanitizedFrameRoundsToWholePoints()
    }

    private static let target = CGRect(x: 100, y: 50, width: 500, height: 400)
    private static let elsewhere = CGRect(x: 400, y: 50, width: 500, height: 400)
    private static let millisecond: UInt64 = 1_000_000
    private static let second: UInt64 = 1_000_000_000
    private static let settle = FramePlanner.settleDelay

    private static func decide(
        _ goal: FrameGoal = .tile(target),
        observed: CGRect,
        record: inout FrameRecord?,
        pointerDown: Bool = false,
        now: UInt64 = 0
    ) -> FrameDecision {
        FramePlanner.decide(goal: goal, observed: observed, record: &record, pointerDown: pointerDown, now: now)
    }

    /// Runs a write decision and has the app acknowledge it, the way the tiler does.
    private static func write(
        observed: CGRect,
        record: inout FrameRecord?,
        token: Int,
        now: UInt64 = 0,
        error: AXError = .success
    ) {
        guard decide(observed: observed, record: &record, now: now) == .write else {
            fail("expected a write for \(observed) at \(now)")
        }
        record?.pendingToken = token
        record?.pendingSince = now
        FramePlanner.absorb(token: token, error: error, record: &record, now: now)
    }

    private static func testConvergedWindowIsLeftAlone() {
        var record: FrameRecord?
        guard decide(observed: target, record: &record) == .none, record?.hasConverged == true else {
            fail("a window on its goal needs nothing")
        }
        guard decide(observed: target.offsetBy(dx: 1, dy: -1), record: &record) == .none else {
            fail("one point of drift is not worth a write")
        }
    }

    private static func testMismatchWritesOnceAndWaitsForTheAnswer() {
        var record: FrameRecord?
        guard decide(observed: elsewhere, record: &record) == .write else {
            fail("a window off its goal is written")
        }
        record?.pendingToken = 1
        guard decide(observed: elsewhere, record: &record) == .settling(until: FramePlanner.pendingWriteTimeout + 1),
              record?.attempts == 1 else {
            fail("no second write, and no second attempt counted, while the first is unanswered")
        }
    }

    private static func testGoalChangeStartsOver() {
        var record: FrameRecord?
        _ = decide(observed: elsewhere, record: &record)
        record?.pendingToken = 1
        let newGoal = FrameGoal.tile(target.offsetBy(dx: 0, dy: 200))
        guard decide(newGoal, observed: elsewhere, record: &record) == .write,
              record?.goal == newGoal, record?.pendingToken == nil, record?.attempts == 1 else {
            fail("a new goal is written straight away, whatever the old write is doing")
        }
    }

    private static func testWrittenFrameIsGivenTimeToShowUp() {
        var record: FrameRecord?
        write(observed: elsewhere, record: &record, token: 1)
        guard decide(observed: elsewhere, record: &record, now: millisecond) == .settling(until: millisecond + settle) else {
            fail("the frame an app just acknowledged is not judged at once")
        }
        guard decide(observed: elsewhere, record: &record, now: 20 * millisecond) == .settling(until: millisecond + settle) else {
            fail("the settle deadline does not move while the frame holds still")
        }
        guard decide(observed: elsewhere, record: &record, now: millisecond + settle) == .write, record?.attempts == 2 else {
            fail("a frame that held still off its goal is written again")
        }
    }

    private static func testFrameThatLandsLateConverges() {
        var record: FrameRecord?
        write(observed: elsewhere, record: &record, token: 1)
        _ = decide(observed: elsewhere, record: &record, now: millisecond)
        guard decide(observed: target, record: &record, now: 9 * millisecond) == .none,
              record?.hasConverged == true, record?.attempts == 0, record?.settling == nil else {
            fail("the frame showing up a moment after the answer converges the window")
        }
    }

    private static func testMovingFrameRestartsTheSettleClock() {
        var record: FrameRecord?
        let wide = CGRect(x: 100, y: 50, width: 900, height: 400)
        write(observed: wide, record: &record, token: 1)
        _ = decide(observed: wide, record: &record, now: millisecond)
        // An animated resize passes through sizes that look exactly like a minimum.
        let halfway = CGRect(x: 100, y: 50, width: 700, height: 400)
        guard decide(observed: halfway, record: &record, now: 40 * millisecond) == .settling(until: 40 * millisecond + settle) else {
            fail("a frame that is still changing restarts the wait")
        }
        guard decide(observed: target, record: &record, now: 80 * millisecond) == .none, record?.hasConverged == true else {
            fail("the animation ending on the goal converges without anything being learned")
        }
    }

    private static func testAttemptBudgetStopsAFight() {
        var record: FrameRecord?
        var now: UInt64 = 0
        for token in 1...FramePlanner.maximumAttempts {
            write(observed: elsewhere, record: &record, token: token, now: now)
            _ = decide(observed: elsewhere, record: &record, now: now + millisecond)
            now += millisecond + settle
        }
        guard decide(observed: elsewhere, record: &record, now: now) == .none, record?.accepted == elsewhere else {
            fail("after the budget is spent the window is left where it insists on being")
        }
        guard decide(observed: elsewhere, record: &record, now: now + second) == .none else {
            fail("an accepted frame stays accepted")
        }
    }

    private static func testAttemptBudgetComesBackAfterAWhile() {
        var record: FrameRecord?
        var now: UInt64 = 0
        for token in 1...FramePlanner.maximumAttempts {
            write(observed: elsewhere, record: &record, token: token, now: now)
            _ = decide(observed: elsewhere, record: &record, now: now + millisecond)
            now += millisecond + settle
        }
        _ = decide(observed: elsewhere, record: &record, now: now)
        let later = FramePlanner.attemptWindow + second
        let moved = elsewhere.offsetBy(dx: 40, dy: 0)
        _ = decide(observed: moved, record: &record, now: later)
        guard decide(observed: moved, record: &record, now: later + settle) == .write, record?.attempts == 1 else {
            fail("once the budget window has passed, a window that moves again is put back")
        }
    }

    private static func testLostAnswerIsNotWaitedOnForever() {
        var record: FrameRecord?
        _ = decide(observed: elsewhere, record: &record)
        record?.pendingToken = 1
        guard decide(observed: elsewhere, record: &record, now: second)
            == .settling(until: FramePlanner.pendingWriteTimeout + 1) else {
            fail("an answer is waited for, with a deadline")
        }
        let late = FramePlanner.pendingWriteTimeout + second
        guard decide(observed: elsewhere, record: &record, now: late) == .settling(until: late + settle),
              record?.pendingToken == nil, record?.lastWriteSucceeded == false else {
            fail("a write whose answer never came stops blocking the window and counts as unconfirmed")
        }
        guard decide(observed: elsewhere, record: &record, now: late + settle) == .write else {
            fail("and the window is written again once it has held still")
        }
    }

    private static func testPointerDragIsNotFought() {
        var record: FrameRecord?
        _ = decide(observed: target, record: &record)
        let dragged = target.offsetBy(dx: 120, dy: 80)
        guard decide(observed: dragged, record: &record, pointerDown: true) == .userMoved, record?.attempts == 0 else {
            fail("a settled window that moves while a button is down is being dragged, at no cost to the budget")
        }
        guard decide(observed: dragged, record: &record, pointerDown: false) == .write else {
            fail("after the drop the window is put back at once if nothing else claimed it")
        }
    }

    private static func testWindowBeingLaidOutIsNotMistakenForADrag() {
        var record: FrameRecord?
        guard decide(observed: elsewhere, record: &record, pointerDown: true) == .write else {
            fail("a window that has never reached its goal is written even while a button is down")
        }
    }

    private static func testSettledClampIsLearnedOnce() {
        var record: FrameRecord?
        let clamped = CGRect(x: 100, y: 50, width: 640, height: 400)
        write(observed: CGRect(x: 100, y: 50, width: 900, height: 700), record: &record, token: 1)
        _ = decide(observed: clamped, record: &record, now: 5 * millisecond)
        guard decide(observed: clamped, record: &record, now: 5 * millisecond + settle)
            == .learnMinimum(CGSize(width: 640, height: 0)) else {
            fail("a larger size that held still after a confirmed write is the app's minimum")
        }
        guard decide(observed: clamped, record: &record, now: second) == .none, record?.accepted == clamped else {
            fail("the minimum is reported once and the frame is left alone")
        }
    }

    private static func testClampIsNotLearnedFromAnUnconfirmedWrite() {
        var record: FrameRecord?
        let oversize = CGRect(x: 100, y: 50, width: 900, height: 400)
        write(observed: oversize, record: &record, token: 1, error: .cannotComplete)
        let retryAt = FramePlanner.timeoutRetryDelay
        guard decide(observed: oversize, record: &record, now: millisecond) == .settling(until: retryAt) else {
            fail("an app that timed out is left alone for a while")
        }
        _ = decide(observed: oversize, record: &record, now: retryAt)
        guard decide(observed: oversize, record: &record, now: retryAt + settle) == .write else {
            fail("a frame the app never confirmed taking is not a minimum; it is written again")
        }
    }

    private static func testSettledShortfallIsAccepted() {
        var record: FrameRecord?
        let snapped = CGRect(x: 100, y: 50, width: 494, height: 391)
        write(observed: elsewhere, record: &record, token: 1)
        _ = decide(observed: snapped, record: &record, now: millisecond)
        guard decide(observed: snapped, record: &record, now: millisecond + settle) == .none,
              record?.accepted == snapped else {
            fail("a window that stopped a little short (terminal cells, a maximum size) is accepted")
        }
    }

    private static func testTimeoutBacksOff() {
        var record: FrameRecord?
        write(observed: elsewhere, record: &record, token: 1, error: .cannotComplete)
        guard record?.retryNotBefore == FramePlanner.timeoutRetryDelay, record?.lastWriteSucceeded == false else {
            fail("a timeout sets a retry time")
        }
        _ = decide(observed: elsewhere, record: &record, now: FramePlanner.timeoutRetryDelay)
        write(
            observed: elsewhere, record: &record, token: 2,
            now: FramePlanner.timeoutRetryDelay + settle, error: .cannotComplete
        )
        guard record?.retryNotBefore == 3 * FramePlanner.timeoutRetryDelay + settle else {
            fail("each further timeout waits longer")
        }
    }

    private static func testStaleAnswerIsIgnored() {
        var record: FrameRecord?
        _ = decide(observed: elsewhere, record: &record)
        record?.pendingToken = 2
        FramePlanner.absorb(token: 1, error: .cannotComplete, record: &record, now: 0)
        guard record?.pendingToken == 2, record?.lastWriteSucceeded == true else {
            fail("the answer to a superseded write changes nothing")
        }
        var missing: FrameRecord?
        FramePlanner.absorb(token: 1, error: .success, record: &missing, now: 0)
        guard missing == nil else {
            fail("an answer for a window that is no longer tracked changes nothing")
        }
    }

    private static func testParkGoalOnlyCaresAboutOrigin() {
        var record: FrameRecord?
        let goal = FrameGoal.park(CGPoint(x: 999, y: 799), clearing: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        guard decide(goal, observed: CGRect(x: 999, y: 799, width: 800, height: 600), record: &record) == .none else {
            fail("a parked window of any size is on its goal")
        }
        guard decide(goal, observed: CGRect(x: 0, y: 0, width: 800, height: 600), record: &record) == .write else {
            fail("a window off its parking spot is moved there")
        }
        record?.pendingToken = 4
        FramePlanner.absorb(token: 4, error: .success, record: &record, now: 0)
        guard decide(goal, observed: CGRect(x: 999, y: 799, width: 640, height: 480), record: &record) == .none,
              record?.hasConverged == true else {
            fail("parking converges on the origin alone")
        }
    }

    private static func testParkStoppedShortOfTheCornerIsAccepted() {
        var record: FrameRecord?
        let goal = FrameGoal.park(CGPoint(x: 999, y: 799), clearing: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        guard decide(goal, observed: CGRect(x: 0, y: 0, width: 800, height: 600), record: &record) == .write else {
            fail("expected the window to be parked")
        }
        record?.pendingToken = 1
        FramePlanner.absorb(token: 1, error: .success, record: &record, now: 0)
        let raised = CGRect(x: 999, y: 768, width: 800, height: 600)
        _ = decide(goal, observed: raised, record: &record, now: millisecond)
        guard decide(goal, observed: raised, record: &record, now: millisecond + settle) == .none,
              record?.accepted == raised, record?.attempts == 1 else {
            fail("a window the app holds a little above the corner is parked well enough")
        }
    }

    private static func testParkLeftInViewIsNotAccepted() {
        var record: FrameRecord?
        // Parked straight down between two neighbors: the origin's x is where the window already was.
        let display = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let goal = FrameGoal.park(CGPoint(x: 1400, y: 799), clearing: [display])
        let inView = CGRect(x: 1400, y: 100, width: 600, height: 500)
        guard decide(goal, observed: inView, record: &record) == .write else {
            fail("expected the window to be parked")
        }
        record?.pendingToken = 1
        FramePlanner.absorb(token: 1, error: .success, record: &record, now: 0)
        _ = decide(goal, observed: inView, record: &record, now: millisecond)
        guard decide(goal, observed: inView, record: &record, now: millisecond + settle) == .write else {
            fail("a window still in plain view is not parked, whatever its x")
        }
    }

    private static func testFrameTwoPointsOffSettlesWithoutLooping() {
        var record: FrameRecord?
        // An app that rounds its frames its own way never lands exactly, however often it is asked.
        let rounded = target.offsetBy(dx: 2, dy: 0)
        var now: UInt64 = 0
        var writes = 0
        for _ in 0..<40 {
            if decide(observed: rounded, record: &record, now: now) == .write {
                writes += 1
                record?.pendingToken = writes
                record?.pendingSince = now
                FramePlanner.absorb(token: writes, error: .success, record: &record, now: now)
            }
            now += settle
        }
        guard writes == FramePlanner.maximumAttempts, record?.accepted == rounded else {
            fail("a frame that stays two points off is written a few times and then left alone, got \(writes) writes")
        }
    }

    private static func testUnansweredWritesAreRetriedLater() {
        var record: FrameRecord?
        var now: UInt64 = 0
        for token in 1...FramePlanner.maximumAttempts {
            write(observed: elsewhere, record: &record, token: token, now: now, error: .cannotComplete)
            now = record!.retryNotBefore
            _ = decide(observed: elsewhere, record: &record, now: now)
            now += settle
        }
        guard decide(observed: elsewhere, record: &record, now: now) == .settling(until: FramePlanner.attemptWindow + 1),
              record?.accepted == nil else {
            fail("an app that never answered has not refused the frame; it is tried again later")
        }
        _ = decide(observed: elsewhere, record: &record, now: FramePlanner.attemptWindow + second)
        guard decide(observed: elsewhere, record: &record, now: FramePlanner.attemptWindow + second + settle) == .write else {
            fail("once the app has had time to recover the frame is written again")
        }
    }

    private static func testParkOnNeighboringDisplayIsNotAccepted() {
        var record: FrameRecord?
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let goal = FrameGoal.park(CGPoint(x: -599, y: 799), clearing: displays)
        // Off its own display, but in plain view on the next one.
        let onNeighbor = CGRect(x: 1200, y: 100, width: 600, height: 500)
        guard decide(goal, observed: onNeighbor, record: &record) == .write else {
            fail("expected the window to be parked")
        }
        record?.pendingToken = 1
        FramePlanner.absorb(token: 1, error: .success, record: &record, now: 0)
        _ = decide(goal, observed: onNeighbor, record: &record, now: millisecond)
        guard decide(goal, observed: onNeighbor, record: &record, now: millisecond + settle) == .write else {
            fail("a window showing on another display is not parked")
        }
    }

    private static func testSanitizedFrameRoundsToWholePoints() {
        expectEqual(
            FramePlanner.sanitized(CGRect(x: 10.4, y: 20.5, width: 300.6, height: 0.2)),
            CGRect(x: 10, y: 21, width: 301, height: 1),
            "frames are whole points and never empty"
        )
    }
}
