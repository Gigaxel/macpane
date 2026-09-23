import CoreGraphics
import Foundation

extension SnapGeometryTests {
    static func runFrameVerificationTests() {
        testFrameVerificationWaitsForPendingWrite()
        testFrameVerificationAbandonsWriteThatNeverCompletes()
        testFrameVerificationDoesNotLearnFromFailedWrite()
        testFrameVerificationDoesNotLearnWithoutWrite()
        testFrameVerificationHonorsSettleDelay()
        testFrameVerificationConfirmsClampBeforeLearning()
        testFrameVerificationDropsClampCandidateWhenFrameSettles()
        testFrameVerificationRejectsImplausibleClamp()
        testFrameVerificationNeverLearnsFromHiddenPark()
        testFrameVerificationReassertsThenAbandons()
        testFrameVerificationAbandonsUnobservableWindow()
        testFrameVerificationAppliesWriteResultsByToken()
        testFrameVerificationInheritsClampCandidateForSameTarget()
        testSlowAppScenarioNeverLearnsStaleFrame()
        testTimedOutWriteScenarioRewritesInsteadOfLearning()
        testRealClampScenarioLearnsAfterConfirmation()
        testAppSizeConstraintsStoreRejectsImplausibleObservations()
        testAppSizeConstraintsStoreForgetsDisprovedMinimum()
        testAppSizeConstraintsStoreKeepsMinimumThatWindowsRespect()
        testAppSizeConstraintsStorePrunesImplausiblePersistedMinimums()
        testApplicableMinimumIgnoresScreenSizedLearnedValue()
        testLayoutWithScreenSizedLearnedMinimumKeepsSiblingUsable()
    }

    // MARK: - Fixtures

    private static let verificationScreen = CGRect(x: 0, y: 37, width: 3840, height: 1563)
    private static let verificationStart = Date(timeIntervalSince1970: 1_700_000_000)

    private static func frameCheck(
        target: CGRect,
        kind: WindowFrameAssignment.Kind = .visibleTile,
        writeState: FrameWriteState,
        attempts: Int = 0,
        createdAt: Date = verificationStart,
        writeCompletedAt: Date? = nil,
        clampCandidate: CGRect? = nil
    ) -> FrameCheckState {
        FrameCheckState(
            target: target,
            kind: kind,
            screenFrame: verificationScreen,
            attempts: attempts,
            writeState: writeState,
            writeToken: 1,
            createdAt: createdAt,
            writeCompletedAt: writeCompletedAt,
            clampCandidate: clampCandidate
        )
    }

    private static func completedCheck(
        target: CGRect,
        kind: WindowFrameAssignment.Kind = .visibleTile,
        attempts: Int = 0,
        clampCandidate: CGRect? = nil
    ) -> FrameCheckState {
        frameCheck(
            target: target,
            kind: kind,
            writeState: .succeeded,
            attempts: attempts,
            writeCompletedAt: verificationStart,
            clampCandidate: clampCandidate
        )
    }

    private static func settledTime() -> Date {
        verificationStart.addingTimeInterval(FrameVerificationPlanner.Policy().settleDelay + 0.05)
    }

    private static func decide(
        _ check: FrameCheckState,
        observed: CGRect?,
        now: Date = settledTime()
    ) -> FrameVerificationDecision {
        FrameVerificationPlanner.decide(check: check, observed: observed, now: now)
    }

    private static func expectNoLearning(_ decision: FrameVerificationDecision, _ message: String) {
        if case .learnClamp(let observedMinimum) = decision {
            fail("\(message): must not learn a minimum, learned \(observedMinimum)")
        }
    }

    private static func testStore(suite: String) -> (store: AppSizeConstraintsStore, defaults: UserDefaults) {
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not create test defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return (AppSizeConstraintsStore(defaults: defaults), defaults)
    }

    // MARK: - Verification decisions

    private static func testFrameVerificationWaitsForPendingWrite() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFrame = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        let check = frameCheck(target: target, writeState: .pending)
        let decision = decide(check, observed: staleFrame, now: verificationStart.addingTimeInterval(0.3))
        guard case .keep(let kept) = decision else {
            fail("a check whose write is still pending must wait, got \(decision)")
        }
        guard kept.clampCandidate == nil else {
            fail("a pending write must not record a clamp candidate")
        }
        expectNoLearning(decision, "pending write")
    }

    private static func testFrameVerificationAbandonsWriteThatNeverCompletes() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let check = frameCheck(target: target, writeState: .pending)
        let policy = FrameVerificationPlanner.Policy()
        let late = verificationStart.addingTimeInterval(policy.pendingWriteTimeout + 0.5)
        let decision = FrameVerificationPlanner.decide(
            check: check,
            observed: CGRect(x: 8, y: 45, width: 3824, height: 1547),
            now: late,
            policy: policy
        )
        guard decision == .abandon else {
            fail("a write that never reports completion must be abandoned, got \(decision)")
        }
    }

    private static func testFrameVerificationDoesNotLearnFromFailedWrite() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFrame = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        let check = frameCheck(target: target, writeState: .failed, writeCompletedAt: verificationStart)
        let decision = decide(check, observed: staleFrame)
        guard case .reassert(let rewritten) = decision else {
            fail("a timed-out write must be retried rather than trusted, got \(decision)")
        }
        guard rewritten.attempts == 1, rewritten.writeState == .pending, rewritten.writeCompletedAt == nil else {
            fail("a reassert must start a fresh pending write attempt, got \(rewritten)")
        }
        expectNoLearning(decision, "failed write")
    }

    private static func testFrameVerificationDoesNotLearnWithoutWrite() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let grown = CGRect(x: 8, y: 45, width: 2400, height: 1547)
        let check = frameCheck(target: target, writeState: .notNeeded, writeCompletedAt: verificationStart)
        let decision = decide(check, observed: grown)
        guard case .reassert = decision else {
            fail("an unwritten window that drifted must be rewritten, got \(decision)")
        }
        expectNoLearning(decision, "no write")
    }

    private static func testFrameVerificationHonorsSettleDelay() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFrame = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        let check = completedCheck(target: target)
        let tooEarly = verificationStart.addingTimeInterval(0.05)
        let decision = decide(check, observed: staleFrame, now: tooEarly)
        guard case .keep(let kept) = decision, kept.clampCandidate == nil else {
            fail("a just-completed write must be given time to settle, got \(decision)")
        }
        let applied = decide(check, observed: target, now: tooEarly)
        guard applied == .applied else {
            fail("a frame already on target is applied regardless of settle time, got \(applied)")
        }
    }

    private static func testFrameVerificationConfirmsClampBeforeLearning() {
        let target = CGRect(x: 8, y: 45, width: 400, height: 1547)
        let clamped = CGRect(x: 8, y: 45, width: 800, height: 1547)
        let first = decide(completedCheck(target: target), observed: clamped)
        guard case .keep(let candidateCheck) = first, candidateCheck.clampCandidate == clamped else {
            fail("the first clamp sighting must only record a candidate, got \(first)")
        }
        expectNoLearning(first, "first clamp sighting")
        let second = decide(candidateCheck, observed: clamped)
        guard second == .learnClamp(observedMinimum: CGSize(width: 800, height: 0)) else {
            fail("a stable clamp after a successful write must be learned, got \(second)")
        }
    }

    private static func testFrameVerificationDropsClampCandidateWhenFrameSettles() {
        let target = CGRect(x: 8, y: 45, width: 400, height: 1547)
        let stale = CGRect(x: 8, y: 45, width: 800, height: 1547)
        let check = completedCheck(target: target, clampCandidate: stale)
        guard decide(check, observed: target) == .applied else {
            fail("a frame that lands on target after a clamp sighting must count as applied")
        }
        let moved = CGRect(x: 8, y: 45, width: 760, height: 1547)
        let changed = decide(check, observed: moved)
        guard case .keep(let kept) = changed, kept.clampCandidate == moved else {
            fail("a clamp sighting that differs from the candidate restarts confirmation, got \(changed)")
        }
        expectNoLearning(changed, "changed clamp sighting")
    }

    private static func testFrameVerificationRejectsImplausibleClamp() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFull = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        let check = completedCheck(target: target, clampCandidate: staleFull)
        let decision = decide(check, observed: staleFull)
        guard decision == .abandon else {
            fail("a clamp at screen width must be discarded, got \(decision)")
        }
        let atCap = CGRect(x: 8, y: 45, width: 3456, height: 1547)
        let capDecision = decide(completedCheck(target: target, clampCandidate: atCap), observed: atCap)
        guard capDecision == .abandon else {
            fail("a clamp exactly at the plausibility cap must be discarded, got \(capDecision)")
        }
    }

    private static func testFrameVerificationNeverLearnsFromHiddenPark() {
        let target = CGRect(x: 3839, y: 1599, width: 600, height: 500)
        let larger = CGRect(x: 3839, y: 1599, width: 900, height: 500)
        let check = completedCheck(target: target, kind: .hiddenPark, clampCandidate: larger)
        let decision = decide(check, observed: larger)
        guard decision == .abandon else {
            fail("hidden park frames carry no size evidence, got \(decision)")
        }
    }

    private static func testFrameVerificationReassertsThenAbandons() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let elsewhere = CGRect(x: 300, y: 45, width: 1908, height: 1547)
        var check = completedCheck(target: target)
        let policy = FrameVerificationPlanner.Policy()
        for attempt in 1...policy.maxReassertAttempts {
            let decision = decide(check, observed: elsewhere)
            guard case .reassert(let next) = decision, next.attempts == attempt else {
                fail("attempt \(attempt) must reassert, got \(decision)")
            }
            check = next
            check.writeState = .succeeded
            check.writeCompletedAt = verificationStart
        }
        guard decide(check, observed: elsewhere) == .abandon else {
            fail("a window that keeps rejecting its frame must eventually be left alone")
        }
    }

    private static func testFrameVerificationAbandonsUnobservableWindow() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        var check = completedCheck(target: target)
        let policy = FrameVerificationPlanner.Policy()
        for read in 1...policy.maxUnobservedReads {
            let decision = decide(check, observed: nil)
            guard case .keep(let kept) = decision, kept.unobservedReads == read else {
                fail("unobservable read \(read) must keep the check, got \(decision)")
            }
            check = kept
        }
        guard decide(check, observed: nil) == .abandon else {
            fail("a window that can never be observed must be dropped")
        }
    }

    private static func testFrameVerificationAppliesWriteResultsByToken() {
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let current = windowID(1)
        let stale = windowID(2)
        let untouched = windowID(3)
        var checks: [WindowIdentity: FrameCheckState] = [
            current: frameCheck(target: target, writeState: .pending),
            stale: frameCheck(target: target, writeState: .pending),
            untouched: frameCheck(target: target, writeState: .pending)
        ]
        checks[stale]?.writeToken = 7
        let completedAt = verificationStart.addingTimeInterval(0.2)
        let updated = FrameVerificationPlanner.applyingWriteResults(
            [current: true, stale: false, windowID(9): true],
            token: 1,
            completedAt: completedAt,
            to: &checks
        )
        guard updated == [current] else {
            fail("only checks from the completed batch may be marked, got \(updated)")
        }
        guard checks[current]?.writeState == .succeeded, checks[current]?.writeCompletedAt == completedAt else {
            fail("a completed write must be marked with its completion time")
        }
        guard checks[stale]?.writeState == .pending, checks[untouched]?.writeState == .pending else {
            fail("a result for an older batch must not touch a newer check")
        }
        var failedChecks: [WindowIdentity: FrameCheckState] = [current: frameCheck(target: target, writeState: .pending)]
        FrameVerificationPlanner.applyingWriteResults([current: false], token: 1, completedAt: completedAt, to: &failedChecks)
        guard failedChecks[current]?.writeState == .failed else {
            fail("an AX error must mark the write as failed")
        }
    }

    private static func testFrameVerificationInheritsClampCandidateForSameTarget() {
        let target = CGRect(x: 8, y: 45, width: 400, height: 1547)
        let clamped = CGRect(x: 8, y: 45, width: 800, height: 1547)
        let previous = completedCheck(target: target, clampCandidate: clamped)
        let fresh = frameCheck(target: target, writeState: .pending)
        let inherited = FrameVerificationPlanner.inheritingClampCandidate(fresh, from: previous)
        guard inherited.clampCandidate == clamped, inherited.writeState == .pending else {
            fail("a repeated layout pass must keep the clamp sighting for the same target")
        }
        let differentTarget = frameCheck(target: CGRect(x: 8, y: 45, width: 600, height: 1547), writeState: .pending)
        guard FrameVerificationPlanner.inheritingClampCandidate(differentTarget, from: previous).clampCandidate == nil else {
            fail("a new target must start clamp confirmation from scratch")
        }
        guard FrameVerificationPlanner.inheritingClampCandidate(fresh, from: nil) == fresh else {
            fail("no previous check means nothing to inherit")
        }
    }

    // MARK: - Scenarios

    private static func testSlowAppScenarioNeverLearnsStaleFrame() {
        let id = windowID(1)
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFull = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        var checks = [id: frameCheck(target: target, writeState: .pending)]
        let policy = FrameVerificationPlanner.Policy()

        let firstRun = FrameVerificationPlanner.decide(
            check: checks[id]!,
            observed: staleFull,
            now: verificationStart.addingTimeInterval(0.3),
            policy: policy
        )
        guard case .keep(let waiting) = firstRun else {
            fail("verification before the write completed must wait, got \(firstRun)")
        }
        expectNoLearning(firstRun, "slow app, write in flight")
        checks[id] = waiting

        FrameVerificationPlanner.applyingWriteResults(
            [id: true],
            token: 1,
            completedAt: verificationStart.addingTimeInterval(0.9),
            to: &checks
        )
        let duringSettle = FrameVerificationPlanner.decide(
            check: checks[id]!,
            observed: staleFull,
            now: verificationStart.addingTimeInterval(1.0),
            policy: policy
        )
        guard case .keep(let settling) = duringSettle, settling.clampCandidate == nil else {
            fail("the stale frame must not become a clamp candidate during settle, got \(duringSettle)")
        }
        checks[id] = settling

        let landed = FrameVerificationPlanner.decide(
            check: checks[id]!,
            observed: target,
            now: verificationStart.addingTimeInterval(1.3),
            policy: policy
        )
        guard landed == .applied else {
            fail("the applied frame must close the check, got \(landed)")
        }
    }

    private static func testTimedOutWriteScenarioRewritesInsteadOfLearning() {
        let id = windowID(1)
        let target = CGRect(x: 8, y: 45, width: 1908, height: 1547)
        let staleFull = CGRect(x: 8, y: 45, width: 3824, height: 1547)
        var checks = [id: frameCheck(target: target, writeState: .pending)]
        let policy = FrameVerificationPlanner.Policy()
        FrameVerificationPlanner.applyingWriteResults(
            [id: false],
            token: 1,
            completedAt: verificationStart.addingTimeInterval(0.75),
            to: &checks
        )
        let afterTimeout = FrameVerificationPlanner.decide(
            check: checks[id]!,
            observed: staleFull,
            now: verificationStart.addingTimeInterval(1.1),
            policy: policy
        )
        guard case .reassert(let rewrite) = afterTimeout else {
            fail("a timed-out write must be retried, got \(afterTimeout)")
        }
        expectNoLearning(afterTimeout, "timed-out write")
        checks[id] = rewrite
        checks[id]?.writeToken = 2
        FrameVerificationPlanner.applyingWriteResults(
            [id: true],
            token: 2,
            completedAt: verificationStart.addingTimeInterval(1.2),
            to: &checks
        )
        let landed = FrameVerificationPlanner.decide(
            check: checks[id]!,
            observed: target,
            now: verificationStart.addingTimeInterval(1.6),
            policy: policy
        )
        guard landed == .applied else {
            fail("the retried write must be confirmed once the frame lands, got \(landed)")
        }
    }

    private static func testRealClampScenarioLearnsAfterConfirmation() {
        let suite = "com.gigaxel.macpane.tests.realClamp"
        let (store, defaults) = testStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundleID = "com.microsoft.teams2"
        let target = CGRect(x: 8, y: 45, width: 400, height: 1547)
        let clamped = CGRect(x: 8, y: 45, width: 800, height: 1547)

        for pass in 1...2 {
            var check = completedCheck(target: target)
            guard case .keep(let candidate) = decide(check, observed: clamped) else {
                fail("pass \(pass): first sighting must become a candidate")
            }
            check = candidate
            guard case .learnClamp(let observedMinimum) = decide(check, observed: clamped) else {
                fail("pass \(pass): a confirmed clamp must be learned")
            }
            guard store.recordObservedMinimum(observedMinimum, forBundleIdentifier: bundleID, screenSize: verificationScreen.size) else {
                fail("pass \(pass): a plausible minimum must be accepted")
            }
        }
        guard let learned = store.minimumSize(forBundleIdentifier: bundleID), learned.width == 800, learned.height == 0 else {
            fail("two agreeing passes must persist the minimum, got \(String(describing: store.minimumSize(forBundleIdentifier: bundleID)))")
        }
        let applicable = AppSizeConstraintsStore.applicableMinimum(learned, within: verificationScreen.size)
        guard applicable.width == 800 else {
            fail("a real minimum must apply on the screen it was learned on")
        }
    }

    // MARK: - Store

    private static func testAppSizeConstraintsStoreRejectsImplausibleObservations() {
        let suite = "com.gigaxel.macpane.tests.implausible"
        let (store, defaults) = testStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundleID = "com.microsoft.teams2"
        let screen = CGSize(width: 3840, height: 1563)

        for _ in 0..<3 {
            if store.recordObservedMinimum(CGSize(width: 3824, height: 0), forBundleIdentifier: bundleID, screenSize: screen) {
                fail("a screen-wide minimum must be rejected outright")
            }
        }
        guard store.minimumSize(forBundleIdentifier: bundleID) == nil else {
            fail("rejected observations must never persist, got \(String(describing: store.minimumSize(forBundleIdentifier: bundleID)))")
        }
        if store.recordObservedMinimum(CGSize(width: 3456, height: 0), forBundleIdentifier: bundleID, screenSize: screen) {
            fail("an observation exactly at the plausibility cap must be rejected")
        }
        if store.recordObservedMinimum(CGSize(width: 800, height: 1500), forBundleIdentifier: bundleID, screenSize: screen) {
            fail("an observation with one implausible dimension must be rejected as a whole")
        }

        guard store.recordObservedMinimum(CGSize(width: 800, height: 0), forBundleIdentifier: bundleID, screenSize: screen) else {
            fail("a plausible observation must be accepted")
        }
        _ = store.recordObservedMinimum(CGSize(width: 3824, height: 0), forBundleIdentifier: bundleID, screenSize: screen)
        _ = store.recordObservedMinimum(CGSize(width: 800, height: 0), forBundleIdentifier: bundleID, screenSize: screen)
        guard store.minimumSize(forBundleIdentifier: bundleID) == nil else {
            fail("observations separated by a rejected reading are not consecutive")
        }
        _ = store.recordObservedMinimum(CGSize(width: 801, height: 0), forBundleIdentifier: bundleID, screenSize: screen)
        guard store.minimumSize(forBundleIdentifier: bundleID)?.width == 801 else {
            fail("two consecutive plausible observations must persist")
        }
    }

    private static func testAppSizeConstraintsStoreForgetsDisprovedMinimum() {
        let suite = "com.gigaxel.macpane.tests.disproved"
        let (store, defaults) = testStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundleID = "com.google.Chrome"
        let screen = CGSize(width: 1920, height: 1080)
        _ = store.recordObservedMinimum(CGSize(width: 500, height: 652), forBundleIdentifier: bundleID, screenSize: screen)
        _ = store.recordObservedMinimum(CGSize(width: 500, height: 652), forBundleIdentifier: bundleID, screenSize: screen)
        guard store.minimumSize(forBundleIdentifier: bundleID) == CGSize(width: 500, height: 652) else {
            fail("setup: minimum must be learned")
        }
        let window = windowID(4)
        let shorter = CGSize(width: 500, height: 600)
        let start = verificationStart
        let gap = AppSizeConstraintsStore.undercutSightingInterval
        if store.recordObservedFrameSize(shorter, forBundleIdentifier: bundleID, windowKey: window, now: start) {
            fail("one sighting below the minimum must not change the store yet")
        }
        if store.recordObservedFrameSize(shorter, forBundleIdentifier: bundleID, windowKey: window, now: start.addingTimeInterval(0.01)) {
            fail("a repeat sighting inside the same layout event must not confirm anything")
        }
        guard store.recordObservedFrameSize(shorter, forBundleIdentifier: bundleID, windowKey: window, now: start.addingTimeInterval(gap)) else {
            fail("two spaced sightings of the same window below the minimum must forget it")
        }
        guard store.minimumSize(forBundleIdentifier: bundleID) == CGSize(width: 500, height: 0) else {
            fail("only the disproved dimension is forgotten, got \(String(describing: store.minimumSize(forBundleIdentifier: bundleID)))")
        }
        guard AppSizeConstraintsStore(defaults: defaults).minimumSize(forBundleIdentifier: bundleID) == CGSize(width: 500, height: 0) else {
            fail("forgetting a dimension must persist")
        }
        let narrower = CGSize(width: 480, height: 700)
        _ = store.recordObservedFrameSize(narrower, forBundleIdentifier: bundleID, windowKey: window, now: start.addingTimeInterval(gap * 2))
        _ = store.recordObservedFrameSize(narrower, forBundleIdentifier: bundleID, windowKey: window, now: start.addingTimeInterval(gap * 3))
        guard store.minimumSize(forBundleIdentifier: bundleID) == nil,
              AppSizeConstraintsStore(defaults: defaults).minimumSize(forBundleIdentifier: bundleID) == nil else {
            fail("an entry with no dimensions left must be removed from memory and disk")
        }
    }

    private static func testAppSizeConstraintsStoreKeepsMinimumThatWindowsRespect() {
        let suite = "com.gigaxel.macpane.tests.respected"
        let (store, defaults) = testStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundleID = "com.microsoft.teams2"
        let screen = CGSize(width: 1920, height: 1080)
        _ = store.recordObservedMinimum(CGSize(width: 800, height: 0), forBundleIdentifier: bundleID, screenSize: screen)
        _ = store.recordObservedMinimum(CGSize(width: 800, height: 0), forBundleIdentifier: bundleID, screenSize: screen)
        let window = windowID(1)
        var clock = verificationStart
        func tick() -> Date {
            clock = clock.addingTimeInterval(AppSizeConstraintsStore.undercutSightingInterval)
            return clock
        }
        for size in [CGSize(width: 800, height: 900), CGSize(width: 795, height: 900), CGSize(width: 1200, height: 500)] {
            for _ in 0..<2 where store.recordObservedFrameSize(size, forBundleIdentifier: bundleID, windowKey: window, now: tick()) {
                fail("a window at or within tolerance of the minimum is not evidence against it (\(size))")
            }
        }
        _ = store.recordObservedFrameSize(CGSize(width: 700, height: 900), forBundleIdentifier: bundleID, windowKey: window, now: tick())
        _ = store.recordObservedFrameSize(CGSize(width: 600, height: 900), forBundleIdentifier: bundleID, windowKey: window, now: tick())
        if store.recordObservedFrameSize(CGSize(width: 700, height: 900), forBundleIdentifier: bundleID, windowKey: window, now: tick()) {
            fail("inconsistent sightings must not forget a minimum")
        }
        guard store.minimumSize(forBundleIdentifier: bundleID)?.width == 800 else {
            fail("the minimum must survive sightings that do not disprove it")
        }
        _ = store.recordObservedFrameSize(CGSize(width: 700, height: 900), forBundleIdentifier: bundleID, windowKey: windowID(2), now: tick())
        guard store.minimumSize(forBundleIdentifier: bundleID)?.width == 800 else {
            fail("sightings are counted per window")
        }
    }

    private static func testAppSizeConstraintsStorePrunesImplausiblePersistedMinimums() {
        let suite = "com.gigaxel.macpane.tests.prune"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("could not create test defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "com.microsoft.teams2": ["width": 3456.0, "height": 270.0],
            "com.brave.Browser": ["width": 520.0, "height": 390.0],
            "ch.protonvpn.mac": ["width": 340.0, "height": 1500.0]
        ], forKey: "learnedAppMinimumSizes")
        let store = AppSizeConstraintsStore(defaults: defaults)
        let largestScreen = CGSize(width: 3840, height: 1563)
        guard store.pruneImplausibleMinimums(within: largestScreen) else {
            fail("pruning must report the change")
        }
        guard store.minimumSize(forBundleIdentifier: "com.microsoft.teams2") == CGSize(width: 0, height: 270) else {
            fail("the screen-sized width must be dropped while the plausible height stays, got \(String(describing: store.minimumSize(forBundleIdentifier: "com.microsoft.teams2")))")
        }
        guard store.minimumSize(forBundleIdentifier: "com.brave.Browser") == CGSize(width: 520, height: 390) else {
            fail("plausible entries must be untouched")
        }
        guard store.minimumSize(forBundleIdentifier: "ch.protonvpn.mac") == CGSize(width: 340, height: 0) else {
            fail("a screen-sized height must be dropped")
        }
        guard AppSizeConstraintsStore(defaults: defaults).minimumSize(forBundleIdentifier: "com.microsoft.teams2") == CGSize(width: 0, height: 270) else {
            fail("pruning must persist")
        }
        if store.pruneImplausibleMinimums(within: largestScreen) {
            fail("a second prune must find nothing to change")
        }
    }

    private static func testApplicableMinimumIgnoresScreenSizedLearnedValue() {
        let learned = CGSize(width: 3456, height: 270)
        let ultrawide = CGSize(width: 3840, height: 1563)
        guard AppSizeConstraintsStore.applicableMinimum(learned, within: ultrawide) == CGSize(width: 0, height: 270) else {
            fail("a learned width at 90% of the screen must not be applied")
        }
        let laptop = CGSize(width: 1470, height: 919)
        guard AppSizeConstraintsStore.applicableMinimum(CGSize(width: 800, height: 600), within: laptop) == CGSize(width: 800, height: 600) else {
            fail("a plausible minimum must apply unchanged")
        }
        guard AppSizeConstraintsStore.applicableMinimum(CGSize(width: 1400, height: 600), within: laptop) == CGSize(width: 0, height: 600) else {
            fail("a minimum plausible on a big screen must be ignored on a screen it cannot fit")
        }
        guard AppSizeConstraintsStore.applicableMinimum(learned, within: .zero) == learned else {
            fail("an unknown screen size must not filter anything")
        }
    }

    private static func testLayoutWithScreenSizedLearnedMinimumKeepsSiblingUsable() {
        let screen = ScreenInfo(key: "display:ultrawide", frame: verificationScreen, displayID: nil, workspaceIndex: 0)
        let teams = windowID(1)
        let sublime = windowID(2)
        let windows = [
            testManagedWindow(id: teams, screen: screen, frame: CGRect(x: 8, y: 45, width: 3824, height: 1547)),
            testManagedWindow(id: sublime, screen: screen, frame: CGRect(x: 1000, y: 200, width: 900, height: 700), scanIndex: 1)
        ]
        let state = screenState([teams, sublime], focused: sublime)
        let gap: CGFloat = 8
        func sublimeWidth(minimums: [WindowIdentity: CGSize]) -> CGFloat {
            let plan = WindowLayoutPlanner.plan(
                windows: windows,
                screenStates: [screen.stateKey: state],
                currentScreens: [screen],
                floatingWindowIDs: [],
                stateKeyLimit: nil,
                gapPixels: gap,
                minimumSizesByID: minimums
            )
            guard let assignment = plan.assignments.first(where: { $0.window.id == sublime }) else {
                fail("Sublime must receive a tile")
            }
            return assignment.frame.width
        }

        let bogusLearned = CGSize(width: 3456, height: 270)
        let squeezed = sublimeWidth(minimums: [teams: bogusLearned])
        guard squeezed < 400 else {
            fail("test premise: honoring the bogus minimum must squeeze the sibling, got \(squeezed)")
        }

        let applicable = AppSizeConstraintsStore.applicableMinimum(bogusLearned, within: screen.frame.size)
        let filteredMinimums = [teams: CGSize(
            width: max(applicable.width, TileLayout.minimumWindowFrameSize.width),
            height: max(applicable.height, TileLayout.minimumWindowFrameSize.height)
        )]
        let fair = sublimeWidth(minimums: filteredMinimums)
        guard fair >= 1900 else {
            fail("with the bogus minimum filtered, Sublime must get its half of the display, got \(fair)")
        }

        var resized = state
        guard resized.resizeFocused(sublime, direction: .left) else {
            fail("resize must change the tree")
        }
        let plan = WindowLayoutPlanner.plan(
            windows: windows,
            screenStates: [screen.stateKey: resized],
            currentScreens: [screen],
            floatingWindowIDs: [],
            stateKeyLimit: nil,
            gapPixels: gap,
            minimumSizesByID: filteredMinimums
        )
        guard let grown = plan.assignments.first(where: { $0.window.id == sublime })?.frame.width, grown > fair + 100 else {
            fail("a resize step must visibly grow the tile once the bogus minimum is gone")
        }
    }
}
