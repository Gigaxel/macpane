import Foundation
import os

enum PerformanceTrace {
    private static let log = OSLog(subsystem: "com.gigaxel.macpane", category: .pointsOfInterest)
    static let isVerbose: Bool = {
        ProcessInfo.processInfo.environment["MACPANE_TIMING"] != nil
            || UserDefaults.standard.bool(forKey: "timingLog")
    }()
    private static var eventMark: (name: String, at: UInt64)?
    private static let processStart = now()

    @inline(__always)
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(now() &- start) / 1_000_000
    }

    @discardableResult
    static func interval<T>(_ name: StaticString, detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        let start = now()
        defer {
            os_signpost(.end, log: log, name: name, signpostID: id)
            if isVerbose {
                emit("\(name) \(detail()) \(format(milliseconds(since: start)))ms")
            }
        }
        return try body()
    }

    static func event(_ name: StaticString, _ detail: String = "") {
        os_signpost(.event, log: log, name: name, "%{public}s", detail)
        if isVerbose {
            emit("\(name) \(detail)")
        }
    }

    static func markEvent(_ name: String) {
        eventMark = (name, now())
        if isVerbose {
            emit("event \(name)")
        }
    }

    static func reportEventLatency(_ stage: StaticString) {
        guard let mark = eventMark else { return }
        eventMark = nil
        event(stage, "\(mark.name) +\(format(milliseconds(since: mark.at)))ms")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func emit(_ text: String) {
        let uptime = format(milliseconds(since: processStart))
        FileHandle.standardError.write(Data("[macpane +\(uptime)ms] \(text)\n".utf8))
    }
}
