import Foundation
import os

/// Signposts for Instruments, plus a plain-text timing log on stderr when `MACPANE_TIMING` is set
/// or the `timingLog` default is on. Safe to call from any thread.
enum PerformanceTrace {
    private static let log = OSLog(subsystem: "com.gigaxel.macpane", category: .pointsOfInterest)
    static let isVerbose: Bool = {
        ProcessInfo.processInfo.environment["MACPANE_TIMING"] != nil
            || UserDefaults.standard.bool(forKey: "timingLog")
    }()
    private static let processStart = now()
    private static let outputLock = NSLock()

    @inline(__always)
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(now() &- start) / 1_000_000
    }

    static func seconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000_000
    }

    /// `detail` is only built when someone is listening.
    static func event(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard isVerbose || log.signpostsEnabled else { return }
        let detail = detail()
        os_signpost(.event, log: log, name: name, "%{public}s", detail)
        if isVerbose {
            emit("\(name) \(detail)")
        }
    }

    static func format(_ milliseconds: Double) -> String {
        String(format: "%.2fms", milliseconds)
    }

    private static func emit(_ text: String) {
        let line = Data("[macpane +\(format(milliseconds(since: processStart)))] \(text)\n".utf8)
        outputLock.lock()
        FileHandle.standardError.write(line)
        outputLock.unlock()
    }
}
