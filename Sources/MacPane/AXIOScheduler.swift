import Foundation

final class AXIOScheduler {
    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]
    private var pendingCoalesced: [pid_t: [AnyHashable: () -> Void]] = [:]
    private var drainingPIDs: Set<pid_t> = []
    private let inFlight = DispatchGroup()

    func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[pid] {
            return queue
        }
        let queue = DispatchQueue(label: "com.gigaxel.macpane.ax.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    func async(pid: pid_t, _ work: @escaping () -> Void) {
        inFlight.enter()
        queue(for: pid).async { [inFlight] in
            work()
            inFlight.leave()
        }
    }

    func enqueueCoalesced(pid: pid_t, key: AnyHashable, _ work: @escaping () -> Void) {
        lock.lock()
        pendingCoalesced[pid, default: [:]][key] = work
        let shouldStartDrain = !drainingPIDs.contains(pid)
        if shouldStartDrain {
            drainingPIDs.insert(pid)
        }
        lock.unlock()
        guard shouldStartDrain else { return }
        async(pid: pid) { [weak self] in
            self?.drainCoalesced(pid: pid)
        }
    }

    private func drainCoalesced(pid: pid_t) {
        while true {
            lock.lock()
            let batch = pendingCoalesced.removeValue(forKey: pid) ?? [:]
            if batch.isEmpty {
                drainingPIDs.remove(pid)
                lock.unlock()
                return
            }
            lock.unlock()
            for work in batch.values {
                work()
            }
        }
    }

    func removeQueues(forPIDs pids: Set<pid_t>) {
        guard !pids.isEmpty else { return }
        lock.lock()
        for pid in pids {
            queues.removeValue(forKey: pid)
            pendingCoalesced.removeValue(forKey: pid)
        }
        lock.unlock()
    }

    @discardableResult
    func flush(timeout: TimeInterval) -> Bool {
        inFlight.wait(timeout: .now() + timeout) == .success
    }
}

final class AppResponsivenessTracker {
    private let lock = NSLock()
    private var unresponsiveUntil: [pid_t: Date] = [:]

    func isResponsive(_ pid: pid_t, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = unresponsiveUntil[pid] else { return true }
        if now >= until {
            unresponsiveUntil.removeValue(forKey: pid)
            return true
        }
        return false
    }

    func markUnresponsive(_ pid: pid_t, for duration: TimeInterval, now: Date = Date()) {
        lock.lock()
        unresponsiveUntil[pid] = now.addingTimeInterval(duration)
        lock.unlock()
    }

    func markResponsive(_ pid: pid_t) {
        lock.lock()
        unresponsiveUntil.removeValue(forKey: pid)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        unresponsiveUntil.removeAll()
        lock.unlock()
    }
}
