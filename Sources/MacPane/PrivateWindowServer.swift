import ApplicationServices
import Foundation

final class PrivateWindowServer {
    static let shared = PrivateWindowServer()

    private typealias SetFrontProcessFunction = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32
    ) -> CGError
    private typealias PostEventRecordFunction = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError

    private typealias ProcessForPIDFunction = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    private let setFrontProcess: SetFrontProcessFunction?
    private let postEventRecord: PostEventRecordFunction?
    private let processForPID: ProcessForPIDFunction?
    private let userGeneratedOption: UInt32 = 0x200

    private init() {
        processForPID = dlopen(nil, RTLD_LAZY).flatMap { dlsym($0, "GetProcessForPID") }.map {
            unsafeBitCast($0, to: ProcessForPIDFunction.self)
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            setFrontProcess = nil
            postEventRecord = nil
            return
        }
        setFrontProcess = dlsym(handle, "_SLPSSetFrontProcessWithOptions").map {
            unsafeBitCast($0, to: SetFrontProcessFunction.self)
        }
        postEventRecord = dlsym(handle, "SLPSPostEventRecordTo").map {
            unsafeBitCast($0, to: PostEventRecordFunction.self)
        }
    }

    var isAvailable: Bool {
        setFrontProcess != nil && postEventRecord != nil && processForPID != nil
    }

    @discardableResult
    func focusWindow(pid: pid_t, windowNumber: Int) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID, windowNumber > 0 else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard processForPID(pid, &psn) == noErr else { return false }
        let windowID = UInt32(windowNumber)
        guard setFrontProcess(&psn, windowID, userGeneratedOption) == .success else { return false }
        var activate = Self.eventRecord(kind: 0x01, windowID: windowID)
        var deactivate = Self.eventRecord(kind: 0x02, windowID: windowID)
        _ = postEventRecord(&psn, &activate)
        _ = postEventRecord(&psn, &deactivate)
        return true
    }

    private static func eventRecord(kind: UInt8, windowID: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xF8
        bytes[0x08] = kind
        bytes[0x3a] = 0x10
        for index in 0x20..<0x30 {
            bytes[index] = 0xFF
        }
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() {
                bytes[0x3c + offset] = byte
            }
        }
        return bytes
    }
}
