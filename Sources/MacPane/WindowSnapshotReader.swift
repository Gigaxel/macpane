import ApplicationServices
import CoreGraphics

enum WindowSnapshotReader {
    // Mission Control / App Exposé makes the Dock process post a full-screen-wide window with
    // bounds y == -1. This is the most reliable signal we can read without private APIs.
    static func isMissionControlActive() -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        for info in infoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock",
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                continue
            }
            if bounds.minY == -1 {
                return true
            }
        }
        return false
    }

    static func readOnScreenWindows() -> OnScreenWindowSnapshot {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return OnScreenWindowSnapshot()
        }

        var snapshot = OnScreenWindowSnapshot()
        var rank = 0
        for info in infoList {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0 else { continue }

            let pid = pid_t(pidNumber.intValue)
            let number = windowNumber.intValue
            let key = WindowOrderKey(pid: pid, number: number)
            snapshot.visibleNumbersByPID[pid, default: []].insert(number)
            if snapshot.rankByWindow[key] == nil {
                snapshot.rankByWindow[key] = rank
            }

            if let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) {
                snapshot.recordsByPID[pid, default: []].append(CGWindowRecord(
                    pid: pid,
                    number: number,
                    frame: frame,
                    title: info[kCGWindowName as String] as? String,
                    rank: rank
                ))
            }
            rank += 1
        }
        return snapshot
    }
}
