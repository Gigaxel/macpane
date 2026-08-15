import Foundation

struct ReassertBudget {
    let maxAttempts: Int
    let interval: TimeInterval
    private var attemptsByID: [WindowIdentity: [Date]] = [:]

    init(maxAttempts: Int = 3, interval: TimeInterval = 10) {
        self.maxAttempts = maxAttempts
        self.interval = interval
    }

    mutating func allowsReassert(of id: WindowIdentity, now: Date = Date()) -> Bool {
        if attemptsByID.count > 512 {
            attemptsByID = attemptsByID.filter { entry in
                entry.value.contains { now.timeIntervalSince($0) < interval }
            }
        }
        let recent = (attemptsByID[id] ?? []).filter { now.timeIntervalSince($0) < interval }
        guard recent.count < maxAttempts else {
            attemptsByID[id] = recent
            return false
        }
        attemptsByID[id] = recent + [now]
        return true
    }

    mutating func reset() {
        attemptsByID.removeAll()
    }
}
