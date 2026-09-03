import CoreGraphics
import Foundation

struct LiveWindowConsistency: Equatable {
    let unknownKeys: Set<WindowOrderKey>
    let missingIDs: Set<WindowIdentity>

    var isConsistent: Bool {
        unknownKeys.isEmpty && missingIDs.isEmpty
    }
}

struct LiveWindowRefresh {
    let visible: [ManagedWindow]
    let missingSinceByID: [WindowIdentity: Date]
    let retained: [ManagedWindow]
}

enum LiveWindowPlanner {
    static func consistency(
        liveWindows: [ManagedWindow],
        visibleNumbersByPID: [pid_t: Set<Int>],
        manageablePIDs: Set<pid_t>,
        knownUnmanageableKeys: Set<WindowOrderKey>
    ) -> LiveWindowConsistency {
        var liveKeys: Set<WindowOrderKey> = []
        var missingIDs: Set<WindowIdentity> = []
        for window in liveWindows {
            guard let number = window.windowNumber else { continue }
            let key = WindowOrderKey(pid: window.id.pid, number: number)
            liveKeys.insert(key)
            if visibleNumbersByPID[window.id.pid]?.contains(number) != true {
                missingIDs.insert(window.id)
            }
        }
        var unknownKeys: Set<WindowOrderKey> = []
        for (pid, numbers) in visibleNumbersByPID where manageablePIDs.contains(pid) {
            for number in numbers {
                let key = WindowOrderKey(pid: pid, number: number)
                if !liveKeys.contains(key), !knownUnmanageableKeys.contains(key) {
                    unknownKeys.insert(key)
                }
            }
        }
        return LiveWindowConsistency(unknownKeys: unknownKeys, missingIDs: missingIDs)
    }

    static func unmanageableKeys(
        visibleNumbersByPID: [pid_t: Set<Int>],
        scannedPIDs: Set<pid_t>,
        liveWindows: [ManagedWindow]
    ) -> Set<WindowOrderKey> {
        let liveKeys = Set(liveWindows.compactMap { window -> WindowOrderKey? in
            window.windowNumber.map { WindowOrderKey(pid: window.id.pid, number: $0) }
        })
        var keys: Set<WindowOrderKey> = []
        for (pid, numbers) in visibleNumbersByPID where scannedPIDs.contains(pid) {
            for number in numbers {
                let key = WindowOrderKey(pid: pid, number: number)
                if !liveKeys.contains(key) {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    static func refreshed(
        liveWindows: [ManagedWindow],
        framesByWindow: [WindowOrderKey: CGRect],
        rankByWindow: [WindowOrderKey: Int],
        missingSinceByID: [WindowIdentity: Date],
        removedIDs: Set<WindowIdentity>,
        expiry: TimeInterval,
        now: Date
    ) -> LiveWindowRefresh {
        var visible: [ManagedWindow] = []
        var retained: [ManagedWindow] = []
        var updatedMissingSince: [WindowIdentity: Date] = [:]
        for window in liveWindows where !removedIDs.contains(window.id) {
            guard let number = window.windowNumber else {
                visible.append(window)
                continue
            }
            let key = WindowOrderKey(pid: window.id.pid, number: number)
            if let frame = framesByWindow[key] {
                visible.append(window.with(frame: frame, orderRank: rankByWindow[key]))
                continue
            }
            let missingSince = missingSinceByID[window.id] ?? now
            if now.timeIntervalSince(missingSince) < expiry {
                updatedMissingSince[window.id] = missingSince
                retained.append(window)
            }
        }
        return LiveWindowRefresh(
            visible: visible.sorted(by: ManagedWindow.shouldOrderBefore),
            missingSinceByID: updatedMissingSince,
            retained: retained
        )
    }

    static func inserting(_ window: ManagedWindow, into liveWindows: [ManagedWindow]) -> [ManagedWindow] {
        var updated = liveWindows.filter { $0.id != window.id }
        updated.append(window)
        return updated.sorted(by: ManagedWindow.shouldOrderBefore)
    }
}
