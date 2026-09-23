import CoreGraphics
import Foundation

enum FrameWriteState: Equatable {
    case notNeeded
    case pending
    case succeeded
    case failed
}

struct FrameCheckState: Equatable {
    let target: CGRect
    let kind: WindowFrameAssignment.Kind
    let screenFrame: CGRect
    var attempts: Int
    var writeState: FrameWriteState
    var writeToken: Int
    var createdAt: Date
    var writeCompletedAt: Date?
    var clampCandidate: CGRect?
    var unobservedReads: Int

    init(
        target: CGRect,
        kind: WindowFrameAssignment.Kind,
        screenFrame: CGRect,
        attempts: Int = 0,
        writeState: FrameWriteState,
        writeToken: Int = 0,
        createdAt: Date,
        writeCompletedAt: Date? = nil,
        clampCandidate: CGRect? = nil,
        unobservedReads: Int = 0
    ) {
        self.target = target
        self.kind = kind
        self.screenFrame = screenFrame
        self.attempts = attempts
        self.writeState = writeState
        self.writeToken = writeToken
        self.createdAt = createdAt
        self.writeCompletedAt = writeCompletedAt
        self.clampCandidate = clampCandidate
        self.unobservedReads = unobservedReads
    }
}

enum FrameVerificationDecision: Equatable {
    case keep(FrameCheckState)
    case applied
    case learnClamp(observedMinimum: CGSize)
    case reassert(FrameCheckState)
    case abandon
}

enum FrameVerificationPlanner {
    struct Policy: Equatable {
        var tolerance: CGFloat = 2
        var maxReassertAttempts: Int = 2
        var maxUnobservedReads: Int = 2
        var settleDelay: TimeInterval = 0.30
        var pendingWriteTimeout: TimeInterval = 4.0

        init() {}
    }

    static func decide(
        check: FrameCheckState,
        observed: CGRect?,
        now: Date,
        policy: Policy = Policy()
    ) -> FrameVerificationDecision {
        guard let observed else {
            var updated = check
            updated.unobservedReads += 1
            return updated.unobservedReads > policy.maxUnobservedReads ? .abandon : .keep(updated)
        }

        let verdict = FrameVerificationClassifier.classify(
            target: check.target,
            observed: observed,
            tolerance: policy.tolerance
        )
        if verdict == .applied {
            return .applied
        }

        switch check.writeState {
        case .pending:
            if now.timeIntervalSince(check.createdAt) > policy.pendingWriteTimeout {
                return .abandon
            }
            return .keep(check)
        case .notNeeded, .failed:
            return reassertOrAbandon(check, now: now, policy: policy)
        case .succeeded:
            if let completedAt = check.writeCompletedAt,
               now.timeIntervalSince(completedAt) < policy.settleDelay {
                return .keep(check)
            }
            guard case .clamped(let observedMinimum) = verdict else {
                return reassertOrAbandon(check, now: now, policy: policy)
            }
            guard check.kind == .visibleTile else {
                return .abandon
            }
            if let candidate = check.clampCandidate,
               WindowFrameApplier.approximatelyEqual(candidate, observed) {
                guard AppSizeConstraintsStore.isPlausibleMinimum(observedMinimum, within: check.screenFrame.size) else {
                    return .abandon
                }
                return .learnClamp(observedMinimum: observedMinimum)
            }
            var updated = check
            updated.clampCandidate = observed
            return .keep(updated)
        }
    }

    @discardableResult
    static func applyingWriteResults(
        _ results: [WindowIdentity: Bool],
        token: Int,
        completedAt: Date,
        to checks: inout [WindowIdentity: FrameCheckState]
    ) -> Set<WindowIdentity> {
        var updatedIDs: Set<WindowIdentity> = []
        for (id, succeeded) in results {
            guard var check = checks[id],
                  check.writeToken == token,
                  check.writeState == .pending else {
                continue
            }
            check.writeState = succeeded ? .succeeded : .failed
            check.writeCompletedAt = completedAt
            checks[id] = check
            updatedIDs.insert(id)
        }
        return updatedIDs
    }

    static func inheritingClampCandidate(
        _ check: FrameCheckState,
        from previous: FrameCheckState?
    ) -> FrameCheckState {
        guard let previous,
              let candidate = previous.clampCandidate,
              WindowFrameApplier.approximatelyEqual(previous.target, check.target) else {
            return check
        }
        var updated = check
        updated.clampCandidate = candidate
        return updated
    }

    private static func reassertOrAbandon(
        _ check: FrameCheckState,
        now: Date,
        policy: Policy
    ) -> FrameVerificationDecision {
        guard check.attempts < policy.maxReassertAttempts else { return .abandon }
        var updated = check
        updated.attempts += 1
        updated.writeState = .pending
        updated.createdAt = now
        updated.writeCompletedAt = nil
        updated.clampCandidate = nil
        updated.unobservedReads = 0
        return .reassert(updated)
    }
}
