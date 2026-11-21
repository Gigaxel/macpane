import AppKit
import ApplicationServices
import CoreGraphics

typealias WindowID = CGWindowID

/// One window as the WindowServer reports it right now.
struct ServerWindow: Equatable {
    let id: WindowID
    let pid: pid_t
    let level: Int32
    let parent: WindowID
    let tags: UInt64
    let attributes: UInt64
    let bounds: CGRect
    let space: UInt64

    /// Tag bits observed on macOS 13 through 27. A window that is ordered out keeps its Space and
    /// its bounds, and these say why it is not showing.
    var isMinimized: Bool { tags & 0x1000_0000_0000_0000 != 0 }
    var isHiddenWithApplication: Bool { tags & 0x0000_0080_0000_0000 != 0 }

    /// A top-level document-style window: the same test yabai applies before it asks AX anything.
    var isStandard: Bool {
        guard level == 0, parent == 0 else { return false }
        guard attributes & 0x2 != 0 || tags & 0x0400_0000_0000_0000 != 0 else { return false }
        return tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0)
    }
}

struct DisplaySpace: Equatable {
    let id: UInt64
    /// Only ordinary desktops are tiled. Fullscreen and system Spaces are left alone.
    let isUser: Bool
}

/// Reads window state straight from the WindowServer.
///
/// The private SkyLight calls are resolved with `dlsym`, so a macOS release that drops one
/// degrades to the public CoreGraphics path instead of failing to launch.
final class WindowServer {
    static let shared = WindowServer()

    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private struct Functions {
        let mainConnection: @convention(c) () -> Int32
        let copyWindows: @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
        let queryWindows: @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
        let queryResultCopyWindows: @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
        let iteratorAdvance: @convention(c) (CFTypeRef) -> Bool
        let iteratorWindowID: @convention(c) (CFTypeRef) -> UInt32
        let iteratorPID: @convention(c) (CFTypeRef) -> pid_t
        let iteratorLevel: @convention(c) (CFTypeRef) -> Int32
        let iteratorTags: @convention(c) (CFTypeRef) -> UInt64
        let iteratorAttributes: @convention(c) (CFTypeRef) -> UInt64
        let iteratorParent: @convention(c) (CFTypeRef) -> UInt32
        let iteratorBounds: @convention(c) (CFTypeRef) -> CGRect
        let currentSpace: @convention(c) (Int32, CFString) -> UInt64
        let copySpacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        let spaceType: @convention(c) (Int32, UInt64) -> Int32
        let windowBounds: @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    }
    private struct EventFunctions {
        let registerNotifyProc: @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
        let requestNotifications: @convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32
    }
    private struct FocusFunctions {
        let setFrontProcess: @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
        let postEventRecord: @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
        let processForPID: @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    }
    private struct FrontProcessFunctions {
        let frontProcess: @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
        let connectionForPSN: @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32
        let connectionPID: @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    }

    private let functions: Functions?
    private let eventFunctions: EventFunctions?
    private let focusFunctions: FocusFunctions?
    private let frontProcessFunctions: FrontProcessFunctions?
    private let connection: Int32
    private var eventHandler: (() -> Void)?
    private var registeredEvents = false
    /// SkyLight has no call to take a callback back, so it is registered once per process.
    private var requestedEvents = false
    private var allEventsRegistered = false
    private var subscribedWindows: [WindowID] = []

    /// Window closed, moved, resized, reordered, changed level, shown and hidden; Dock geometry;
    /// Mission Control; window created and destroyed; Space created, destroyed and switched; front
    /// app changed. The numbers are undocumented, so each one is only a wake-up: state is always
    /// re-read from the server and never taken from an event's payload.
    private static let wakeEvents: [UInt32] = [
        804, 806, 807, 808, 811, 815, 816, 1201, 1204, 1325, 1326, 1327, 1328, 1401, 1508
    ]

    private init() {
        let disabled = ProcessInfo.processInfo.environment["MACPANE_DISABLE_SKYLIGHT"] != nil
        let handle = disabled ? nil : dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        typealias F = Functions
        if let mainConnection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
           let copyWindows = symbol("SLSCopyWindowsWithOptionsAndTags", as: (@convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?).self),
           let queryWindows = symbol("SLSWindowQueryWindows", as: (@convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?).self),
           let queryResultCopyWindows = symbol("SLSWindowQueryResultCopyWindows", as: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self),
           let iteratorAdvance = symbol("SLSWindowIteratorAdvance", as: (@convention(c) (CFTypeRef) -> Bool).self),
           let iteratorWindowID = symbol("SLSWindowIteratorGetWindowID", as: (@convention(c) (CFTypeRef) -> UInt32).self),
           let iteratorPID = symbol("SLSWindowIteratorGetPID", as: (@convention(c) (CFTypeRef) -> pid_t).self),
           let iteratorLevel = symbol("SLSWindowIteratorGetLevel", as: (@convention(c) (CFTypeRef) -> Int32).self),
           let iteratorTags = symbol("SLSWindowIteratorGetTags", as: (@convention(c) (CFTypeRef) -> UInt64).self),
           let iteratorAttributes = symbol("SLSWindowIteratorGetAttributes", as: (@convention(c) (CFTypeRef) -> UInt64).self),
           let iteratorParent = symbol("SLSWindowIteratorGetParentID", as: (@convention(c) (CFTypeRef) -> UInt32).self),
           let iteratorBounds = symbol("SLSWindowIteratorGetBounds", as: (@convention(c) (CFTypeRef) -> CGRect).self),
           let currentSpace = symbol("SLSManagedDisplayGetCurrentSpace", as: (@convention(c) (Int32, CFString) -> UInt64).self),
           let spaceType = symbol("SLSSpaceGetType", as: (@convention(c) (Int32, UInt64) -> Int32).self),
           let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self),
           let windowBounds = symbol("SLSGetWindowBounds", as: (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32).self) {
            functions = F(
                mainConnection: mainConnection,
                copyWindows: copyWindows,
                queryWindows: queryWindows,
                queryResultCopyWindows: queryResultCopyWindows,
                iteratorAdvance: iteratorAdvance,
                iteratorWindowID: iteratorWindowID,
                iteratorPID: iteratorPID,
                iteratorLevel: iteratorLevel,
                iteratorTags: iteratorTags,
                iteratorAttributes: iteratorAttributes,
                iteratorParent: iteratorParent,
                iteratorBounds: iteratorBounds,
                currentSpace: currentSpace,
                copySpacesForWindows: copySpacesForWindows,
                spaceType: spaceType,
                windowBounds: windowBounds
            )
            connection = mainConnection()
        } else {
            functions = nil
            connection = 0
        }
        if functions != nil,
           let registerNotifyProc = symbol("SLSRegisterNotifyProc", as: (@convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32).self),
           let requestNotifications = symbol("SLSRequestNotificationsForWindows", as: (@convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32).self) {
            eventFunctions = EventFunctions(
                registerNotifyProc: registerNotifyProc,
                requestNotifications: requestNotifications
            )
        } else {
            eventFunctions = nil
        }
        let processForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map {
            unsafeBitCast($0, to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
        }
        if let processForPID,
           let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError).self),
           let postEventRecord = symbol("SLPSPostEventRecordTo", as: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError).self) {
            focusFunctions = FocusFunctions(
                setFrontProcess: setFrontProcess,
                postEventRecord: postEventRecord,
                processForPID: processForPID
            )
        } else {
            focusFunctions = nil
        }
        if functions != nil,
           let frontProcess = symbol("_SLPSGetFrontProcess", as: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32).self),
           let connectionForPSN = symbol("SLSGetConnectionIDForPSN", as: (@convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32).self),
           let connectionPID = symbol("SLSConnectionGetPID", as: (@convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32).self) {
            frontProcessFunctions = FrontProcessFunctions(
                frontProcess: frontProcess,
                connectionForPSN: connectionForPSN,
                connectionPID: connectionPID
            )
        } else {
            frontProcessFunctions = nil
        }
    }

    /// False when the SkyLight query calls are missing and the public CoreGraphics list is used.
    var usesSkyLight: Bool { functions != nil }
    /// True once `startEvents` has registered for WindowServer events.
    var deliversEvents: Bool { registeredEvents }
    var canFocusDirectly: Bool { focusFunctions != nil }

    // MARK: - Spaces

    /// The native Space a display is showing, or nil when SkyLight is unavailable. With "Displays
    /// have separate Spaces" off every display shares the Space registered under "Main".
    func currentSpace(ofDisplay uuid: String) -> DisplaySpace? {
        guard let functions else { return nil }
        var id = functions.currentSpace(connection, uuid as CFString)
        if id == 0 {
            id = functions.currentSpace(connection, "Main" as CFString)
        }
        guard id != 0 else { return nil }
        return DisplaySpace(id: id, isUser: functions.spaceType(connection, id) == 0)
    }

    /// The Space a window is assigned to, whether or not it is showing.
    func space(of window: WindowID) -> UInt64? {
        guard let functions,
              let spaces = functions.copySpacesForWindows(connection, 0x7, [NSNumber(value: window)] as CFArray)?
                  .takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return spaces.first?.uint64Value
    }

    // MARK: - Windows

    /// Every ordered-in window on the given Spaces, front to back. `shared` holds the windows that
    /// show on more than one of those Spaces at once.
    func windows(onSpaces spaces: [UInt64]) -> (windows: [ServerWindow], shared: Set<WindowID>) {
        guard let functions else { return (publicWindowList(), []) }
        guard !spaces.isEmpty,
              let list = copyWindowList(onSpaces: spaces, functions: functions) else {
            return ([], [])
        }
        var spaceByWindow: [WindowID: UInt64] = [:]
        var shared: Set<WindowID> = []
        if spaces.count > 1 {
            // One list across every Space keeps the global front-to-back order; a list per Space
            // says which Space each window is on.
            for space in spaces {
                guard let members = copyWindowList(onSpaces: [space], functions: functions) as? [NSNumber] else {
                    continue
                }
                for member in members {
                    if spaceByWindow.updateValue(space, forKey: member.uint32Value) != nil {
                        shared.insert(member.uint32Value)
                    }
                }
            }
        }
        var windows: [ServerWindow] = []
        windows.reserveCapacity(CFArrayGetCount(list))
        iterate(list, functions: functions) { window in
            windows.append(ServerWindow(
                id: window.id,
                pid: window.pid,
                level: window.level,
                parent: window.parent,
                tags: window.tags,
                attributes: window.attributes,
                bounds: window.bounds,
                space: spaceByWindow[window.id] ?? spaces[0]
            ))
        }
        return (windows, shared)
    }

    private func copyWindowList(onSpaces spaces: [UInt64], functions: Functions) -> CFArray? {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        return functions.copyWindows(
            connection, 0, spaces.map { NSNumber(value: $0) } as CFArray, 0x2, &setTags, &clearTags
        )?.takeRetainedValue()
    }

    /// What the server knows about some windows wherever they are: minimized, hidden, closed but
    /// kept around, or on another Space. A window missing from the result no longer exists.
    func describe(_ candidates: [WindowID]) -> [WindowID: ServerWindow] {
        guard !candidates.isEmpty else { return [:] }
        var described: [WindowID: ServerWindow] = [:]
        guard let functions else {
            let descriptions = CGWindowListCreateDescriptionFromArray(Self.rawWindowIDs(candidates)) as? [[String: Any]] ?? []
            for description in descriptions {
                guard let id = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                described[id] = ServerWindow(
                    id: id,
                    pid: (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                    level: 0, parent: 0, tags: 0, attributes: 0, bounds: .zero, space: 0
                )
            }
            return described
        }
        iterate(candidates.map { NSNumber(value: $0) } as CFArray, functions: functions) { window in
            described[window.id] = window
        }
        return described
    }

    func bounds(of window: WindowID) -> CGRect? {
        if let functions {
            var rect = CGRect.zero
            guard functions.windowBounds(connection, window, &rect) == 0, rect.width > 0, rect.height > 0 else {
                return nil
            }
            return rect
        }
        guard let descriptions = CGWindowListCreateDescriptionFromArray(Self.rawWindowIDs([window]))
                  as? [[String: Any]],
              let boundsDictionary = descriptions.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              rect.width > 0, rect.height > 0 else {
            return nil
        }
        return rect
    }

    /// `CGWindowListCreateDescriptionFromArray` takes the IDs themselves as the array's values, not
    /// boxed numbers.
    private static func rawWindowIDs(_ ids: [WindowID]) -> CFArray {
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil)
    }

    private func iterate(_ list: CFArray, functions: Functions, _ body: (ServerWindow) -> Void) {
        let count = CFArrayGetCount(list)
        guard count > 0,
              let query = functions.queryWindows(connection, list, Int32(count))?.takeRetainedValue(),
              let iterator = functions.queryResultCopyWindows(query)?.takeRetainedValue() else {
            return
        }
        while functions.iteratorAdvance(iterator) {
            body(ServerWindow(
                id: functions.iteratorWindowID(iterator),
                pid: functions.iteratorPID(iterator),
                level: functions.iteratorLevel(iterator),
                parent: functions.iteratorParent(iterator),
                tags: functions.iteratorTags(iterator),
                attributes: functions.iteratorAttributes(iterator),
                bounds: functions.iteratorBounds(iterator),
                space: 0
            ))
        }
    }

    /// Public fallback. It cannot see tags or parents, so every layer-0 window passes the
    /// `isStandard` test and AX makes the final call.
    private func publicWindowList() -> [ServerWindow] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return infoList.compactMap { info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else {
                return nil
            }
            return ServerWindow(
                id: number,
                pid: pid,
                level: (info[kCGWindowLayer as String] as? NSNumber)?.int32Value ?? 0,
                parent: 0,
                tags: 0x1,
                attributes: 0x2,
                bounds: bounds,
                space: 0
            )
        }
    }

    // MARK: - Events

    /// Calls `handler` on the main thread whenever the WindowServer reports a change. Returns false
    /// when the private event calls are unavailable and the caller has to rely on Accessibility
    /// notifications instead.
    @discardableResult
    func startEvents(_ handler: @escaping () -> Void) -> Bool {
        eventHandler = handler
        guard let eventFunctions else { return false }
        let callback: NotifyProc = { _, _, _, _ in
            if Thread.isMainThread {
                WindowServer.shared.eventHandler?()
            } else {
                DispatchQueue.main.async {
                    WindowServer.shared.eventHandler?()
                }
            }
        }
        if !requestedEvents {
            requestedEvents = true
            // Every event has to register: missing one means changes that nothing announces.
            allEventsRegistered = Self.wakeEvents.allSatisfy { eventFunctions.registerNotifyProc(callback, $0, nil) == 0 }
        }
        registeredEvents = allEventsRegistered
        return registeredEvents
    }

    func stopEvents() {
        eventHandler = nil
        registeredEvents = false
        subscribedWindows = []
    }

    /// Per-window events are only delivered for windows named in the most recent request.
    func subscribe(to windows: [WindowID]) {
        guard let eventFunctions, registeredEvents, windows != subscribedWindows else { return }
        // A request that fails is not remembered, so the next reconcile makes it again.
        if windows.isEmpty || eventFunctions.requestNotifications(connection, windows, Int32(windows.count)) == 0 {
            subscribedWindows = windows
        }
    }

    // MARK: - Focus

    func frontmostPID() -> pid_t? {
        if let frontProcessFunctions {
            var psn = ProcessSerialNumber()
            var processConnection: Int32 = 0
            var pid: pid_t = 0
            if frontProcessFunctions.frontProcess(&psn) == 0,
               frontProcessFunctions.connectionForPSN(connection, &psn, &processConnection) == 0,
               frontProcessFunctions.connectionPID(processConnection, &pid) == 0,
               pid > 0 {
                return pid
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Makes one window key without activating the rest of its app, the way the Dock does.
    @discardableResult
    func focus(pid: pid_t, window: WindowID) -> Bool {
        guard let focusFunctions, window != 0 else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard focusFunctions.processForPID(pid, &psn) == noErr,
              focusFunctions.setFrontProcess(&psn, window, 0x200) == .success else {
            return false
        }
        var activate = Self.keyWindowRecord(kind: 0x01, window: window)
        var deactivate = Self.keyWindowRecord(kind: 0x02, window: window)
        guard focusFunctions.postEventRecord(&psn, &activate) == .success else { return false }
        return focusFunctions.postEventRecord(&psn, &deactivate) == .success
    }

    private static func keyWindowRecord(kind: UInt8, window: WindowID) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = kind
        bytes[0x3a] = 0x10
        for index in 0x20..<0x30 {
            bytes[index] = 0xff
        }
        withUnsafeBytes(of: window.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() {
                bytes[0x3c + offset] = byte
            }
        }
        return bytes
    }
}
