import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
typealias SpaceID = UInt64
struct SpaceTarget {
    let displayID: CGDirectDisplayID?
    let displayIdentifier: String
    let spaceID: SpaceID
}
struct ManagedSpaceInfo {
    let id: SpaceID
    let type: Int
    let index: Int
    var isUserSpace: Bool { type == 0 }
}
struct ManagedDisplaySpaces {
    let displayIdentifier: String
    let currentSpaceID: SpaceID?
    let spaces: [ManagedSpaceInfo]
    var currentUserSpaceID: SpaceID? {
        guard let currentSpaceID,
              spaces.contains(where: { $0.id == currentSpaceID && $0.isUserSpace }) else {
            return nil
        }
        return currentSpaceID
    }
    static func fromSkyLightDictionary(
        _ dictionary: [String: Any],
        currentSpaceFallback: ((String) -> SpaceID?)? = nil
    ) -> ManagedDisplaySpaces? {
        guard let displayIdentifier = dictionary["Display Identifier"] as? String ?? dictionary["displayIdentifier"] as? String else {
            return nil
        }
        let currentSpaceID = spaceIDValue(dictionary["Current Space"])
            ?? spaceIDValue(dictionary["currentSpace"])
            ?? currentSpaceFallback?(displayIdentifier)
        let rawSpaces = dictionary["Spaces"] as? [[String: Any]] ?? dictionary["spaces"] as? [[String: Any]] ?? []
        let spaces = rawSpaces.enumerated().compactMap { index, spaceDictionary -> ManagedSpaceInfo? in
            guard let id = spaceIDValue(spaceDictionary) else { return nil }
            let type = intValue(spaceDictionary["type"]) ?? intValue(spaceDictionary["ManagedSpaceType"]) ?? 0
            return ManagedSpaceInfo(id: id, type: type, index: index)
        }
        return ManagedDisplaySpaces(displayIdentifier: displayIdentifier, currentSpaceID: currentSpaceID, spaces: spaces)
    }
    private static func spaceIDValue(_ value: Any?) -> SpaceID? {
        if let dictionary = value as? [String: Any] {
            return spaceIDValue(dictionary["id64"])
                ?? spaceIDValue(dictionary["ManagedSpaceID"])
                ?? spaceIDValue(dictionary["id"])
                ?? spaceIDValue(dictionary["wsid"])
        }
        if let value = value as? SpaceID { return value }
        if let value = value as? UInt { return SpaceID(value) }
        if let value = value as? UInt32 { return SpaceID(value) }
        if let value = value as? Int { return value > 0 ? SpaceID(value) : nil }
        if let value = value as? Int64 { return value > 0 ? SpaceID(value) : nil }
        if let value = value as? NSNumber { return value.uint64Value > 0 ? value.uint64Value : nil }
        if let value = value as? String { return SpaceID(value) }
        return nil
    }
    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
final class SpacesController {
    static let shared = SpacesController()
    private let api = SkyLightPrivateAPI()
    private init() {}
    func currentSpaceID(for displayID: CGDirectDisplayID?) -> SpaceID? {
        currentUserSpaceID(for: displayID)
    }
    func currentUserSpaceID(for displayID: CGDirectDisplayID?) -> SpaceID? {
        layout(for: displayID)?.currentUserSpaceID
    }
    func managedDisplaySpaces() -> [ManagedDisplaySpaces] {
        api.managedDisplaySpaces()
    }
    func switchToSpace(_ target: SpaceTarget) -> Bool {
        api.switchToSpace(target.spaceID, displayIdentifier: target.displayIdentifier)
    }
    func createSpace(on displayID: CGDirectDisplayID?, completion: @escaping (SpaceTarget?) -> Void) {
        let targetDisplayIdentifier = layout(for: displayID)?.displayIdentifier ?? Self.displayIdentifier(for: displayID)
        if let createdID = api.createDesktop(on: targetDisplayIdentifier),
           let target = target(for: createdID, fallbackDisplayID: displayID, fallbackDisplayIdentifier: targetDisplayIdentifier) {
            completion(target)
            return
        }
        let beforeIDs = userSpaceIDs()
        MissionControlSpaceCreator.createSpace(
            on: displayID,
            beforeIDs: beforeIDs,
            spaceSnapshot: { [weak self] in self?.managedDisplaySpaces() ?? [] }
        ) { [weak self] createdID in
            guard let self,
                  let createdID,
                  let target = self.target(
                    for: createdID,
                    fallbackDisplayID: displayID,
                    fallbackDisplayIdentifier: targetDisplayIdentifier
                  ) else {
                completion(nil)
                return
            }
            completion(target)
        }
    }
    private func layout(for displayID: CGDirectDisplayID?) -> ManagedDisplaySpaces? {
        layout(for: displayID, in: managedDisplaySpaces())
    }
    private func layout(containing spaceID: SpaceID, in layouts: [ManagedDisplaySpaces]) -> ManagedDisplaySpaces? {
        layouts.first { layout in
            layout.spaces.contains { $0.id == spaceID }
        }
    }
    private func target(
        for spaceID: SpaceID,
        fallbackDisplayID: CGDirectDisplayID?,
        fallbackDisplayIdentifier: String?
    ) -> SpaceTarget? {
        let layouts = managedDisplaySpaces()
        let containingLayout = layout(containing: spaceID, in: layouts)
        let displayIdentifier = containingLayout?.displayIdentifier ?? fallbackDisplayIdentifier
        guard let displayIdentifier else { return nil }
        return SpaceTarget(
            displayID: containingLayout.flatMap { Self.displayID(for: $0.displayIdentifier) } ?? fallbackDisplayID,
            displayIdentifier: displayIdentifier,
            spaceID: spaceID
        )
    }
    private func userSpaceIDs() -> Set<SpaceID> {
        Set(managedDisplaySpaces().flatMap { layout in
            layout.spaces.filter(\.isUserSpace).map(\.id)
        })
    }
    private func layout(for displayID: CGDirectDisplayID?, in layouts: [ManagedDisplaySpaces]) -> ManagedDisplaySpaces? {
        guard !layouts.isEmpty else { return nil }
        guard let displayID else {
            return layouts.first
        }
        let displayIdentifier = Self.displayIdentifier(for: displayID)
        if let displayIdentifier,
           let exact = layouts.first(where: { $0.displayIdentifier == displayIdentifier }) {
            return exact
        }
        if displayID == CGMainDisplayID(),
           let main = layouts.first(where: { $0.displayIdentifier == "Main" }) {
            return main
        }
        return layouts.count == 1 ? layouts[0] : nil
    }
    static func displayIdentifier(for displayID: CGDirectDisplayID?) -> String? {
        guard let displayID,
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        guard let unmanagedString = CFUUIDCreateString(nil, uuid) else { return nil }
        return unmanagedString as String
    }
    static func displayID(for displayIdentifier: String) -> CGDirectDisplayID? {
        let maxDisplays: UInt32 = 32
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        guard CGGetOnlineDisplayList(maxDisplays, &displays, &displayCount) == .success else {
            return nil
        }
        for display in displays.prefix(Int(displayCount)) {
            if Self.displayIdentifier(for: display) == displayIdentifier {
                return display
            }
        }
        return nil
    }
}
private final class SkyLightPrivateAPI {
    private typealias ConnectionID = UInt32
    private typealias MainConnectionIDFunction = @convention(c) () -> ConnectionID
    private typealias DefaultConnectionForThreadFunction = @convention(c) () -> ConnectionID
    private typealias NewConnectionFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<ConnectionID>) -> Int32
    private typealias CopyManagedDisplaySpacesFunction = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias ManagedDisplayGetCurrentSpaceFunction = @convention(c) (ConnectionID, CFString) -> SpaceID
    private typealias SpaceCreateFunction = @convention(c) (ConnectionID, UInt32, CFDictionary) -> SpaceID
    private typealias SpaceDestroyFunction = @convention(c) (ConnectionID, SpaceID) -> Void
    private typealias MoveManagedSpaceToDisplayIndexFunction = @convention(c) (ConnectionID, SpaceID, CFString, UInt32) -> Void
    private typealias ManagedDisplaySetCurrentSpaceFunction = @convention(c) (ConnectionID, CFString, SpaceID) -> Void
    private typealias PersistenceSaveSpaceConfigurationFunction = @convention(c) (ConnectionID) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let mainConnectionID: MainConnectionIDFunction?
    private let defaultConnectionForThread: DefaultConnectionForThreadFunction?
    private let newConnection: NewConnectionFunction?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFunction?
    private let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpaceFunction?
    private let spaceCreate: SpaceCreateFunction?
    private let spaceDestroy: SpaceDestroyFunction?
    private let moveManagedSpaceToDisplayIndex: MoveManagedSpaceToDisplayIndexFunction?
    private let managedDisplaySetCurrentSpace: ManagedDisplaySetCurrentSpaceFunction?
    private let persistenceSaveSpaceConfiguration: PersistenceSaveSpaceConfigurationFunction?
    private var cachedConnectionID: ConnectionID?
    init() {
        handle = SkyLightPrivateAPI.openSkyLight()
        mainConnectionID = SkyLightPrivateAPI.symbol(
            names: ["SLSMainConnectionID", "CGSMainConnectionID"],
            handle: handle,
            as: MainConnectionIDFunction.self
        )
        defaultConnectionForThread = SkyLightPrivateAPI.symbol(
            names: ["SLSDefaultConnectionForThread", "CGSDefaultConnectionForThread"],
            handle: handle,
            as: DefaultConnectionForThreadFunction.self
        )
        newConnection = SkyLightPrivateAPI.symbol(
            names: ["SLSNewConnection", "CGSNewConnection"],
            handle: handle,
            as: NewConnectionFunction.self
        )
        copyManagedDisplaySpaces = SkyLightPrivateAPI.symbol(
            names: ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"],
            handle: handle,
            as: CopyManagedDisplaySpacesFunction.self
        )
        managedDisplayGetCurrentSpace = SkyLightPrivateAPI.symbol(
            names: ["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"],
            handle: handle,
            as: ManagedDisplayGetCurrentSpaceFunction.self
        )
        spaceCreate = SkyLightPrivateAPI.symbol(
            names: ["SLSSpaceCreate", "CGSSpaceCreate"],
            handle: handle,
            as: SpaceCreateFunction.self
        )
        spaceDestroy = SkyLightPrivateAPI.symbol(
            names: ["SLSSpaceDestroy", "CGSSpaceDestroy"],
            handle: handle,
            as: SpaceDestroyFunction.self
        )
        moveManagedSpaceToDisplayIndex = SkyLightPrivateAPI.symbol(
            names: ["SLSMoveManagedSpaceToDisplayIndex", "CGSMoveManagedSpaceToDisplayIndex"],
            handle: handle,
            as: MoveManagedSpaceToDisplayIndexFunction.self
        )
        managedDisplaySetCurrentSpace = SkyLightPrivateAPI.symbol(
            names: ["SLSManagedDisplaySetCurrentSpace", "CGSManagedDisplaySetCurrentSpace"],
            handle: handle,
            as: ManagedDisplaySetCurrentSpaceFunction.self
        )
        persistenceSaveSpaceConfiguration = SkyLightPrivateAPI.symbol(
            names: ["SLSPersistenceSaveSpaceConfiguration", "CGSPersistenceSaveSpaceConfiguration"],
            handle: handle,
            as: PersistenceSaveSpaceConfigurationFunction.self
        )
    }
    func managedDisplaySpaces() -> [ManagedDisplaySpaces] {
        guard let copyManagedDisplaySpaces,
              let connectionID = connectionID(),
              let unmanaged = copyManagedDisplaySpaces(connectionID) else {
            return []
        }
        let rawArray = unmanaged.takeRetainedValue()
        guard let displayDictionaries = rawArray as? [[String: Any]] else { return [] }
        return displayDictionaries.compactMap(parseDisplaySpaces)
    }
    func switchToSpace(_ spaceID: SpaceID, displayIdentifier: String) -> Bool {
        guard let managedDisplaySetCurrentSpace,
              let connectionID = connectionID() else { return false }
        managedDisplaySetCurrentSpace(connectionID, displayIdentifier as CFString, spaceID)
        return true
    }
    func createDesktop(on displayIdentifier: String?) -> SpaceID? {
        guard let spaceCreate,
              let moveManagedSpaceToDisplayIndex,
              let connectionID = connectionID() else { return nil }
        let targetDisplayIdentifier = displayIdentifier ?? managedDisplaySpaces().first?.displayIdentifier
        guard let targetDisplayIdentifier else { return nil }
        var keyCallbacks = kCFTypeDictionaryKeyCallBacks
        var valueCallbacks = kCFTypeDictionaryValueCallBacks
        let values = CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &keyCallbacks,
            &valueCallbacks
        )
        guard let values else { return nil }
        let createdID = spaceCreate(connectionID, 0, values)
        guard createdID != 0 else { return nil }
        let targetIndex = managedDisplaySpaces()
            .first(where: { $0.displayIdentifier == targetDisplayIdentifier })?
            .spaces
            .count ?? 0
        moveManagedSpaceToDisplayIndex(connectionID, createdID, targetDisplayIdentifier as CFString, UInt32(targetIndex))
        persistenceSaveSpaceConfiguration?(connectionID)
        if managedDisplaySpaces().contains(where: { layout in
            layout.displayIdentifier == targetDisplayIdentifier && layout.spaces.contains(where: { $0.id == createdID && $0.isUserSpace })
        }) {
            return createdID
        }
        spaceDestroy?(connectionID, createdID)
        persistenceSaveSpaceConfiguration?(connectionID)
        return nil
    }
    private func parseDisplaySpaces(_ dictionary: [String: Any]) -> ManagedDisplaySpaces? {
        ManagedDisplaySpaces.fromSkyLightDictionary(dictionary, currentSpaceFallback: currentSpaceViaGetter)
    }
    private func currentSpaceViaGetter(displayIdentifier: String) -> SpaceID? {
        guard let managedDisplayGetCurrentSpace,
              let connectionID = connectionID() else { return nil }
        let sid = managedDisplayGetCurrentSpace(connectionID, displayIdentifier as CFString)
        return sid == 0 ? nil : sid
    }
    private func connectionID() -> ConnectionID? {
        if let cachedConnectionID, cachedConnectionID != 0 {
            return cachedConnectionID
        }
        for candidate in [mainConnectionID?(), defaultConnectionForThread?()] where (candidate ?? 0) != 0 {
            cachedConnectionID = candidate
            return candidate
        }
        guard let newConnection else { return nil }
        var createdConnectionID: ConnectionID = 0
        if newConnection(nil, &createdConnectionID) == 0, createdConnectionID != 0 {
            cachedConnectionID = createdConnectionID
            return createdConnectionID
        }
        return nil
    }
    private static func openSkyLight() -> UnsafeMutableRawPointer? {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) {
            return handle
        }
        if let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW) {
            return handle
        }
        return dlopen(nil, RTLD_NOW)
    }
    private static func symbol<T>(names: [String], handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle else { return nil }
        for name in names {
            if let raw = dlsym(handle, name) {
                return unsafeBitCast(raw, to: type)
            }
        }
        return nil
    }
}
enum MissionControlSpaceCreator {
    static func createSpace(
        on displayID: CGDirectDisplayID?,
        beforeIDs: Set<SpaceID>,
        spaceSnapshot: @escaping () -> [ManagedDisplaySpaces],
        completion: @escaping (SpaceID?) -> Void
    ) {
        DispatchQueue.main.async {
            openMissionControl()
            waitForAddDesktopButton(on: displayID ?? mainDisplayID() ?? CGMainDisplayID(), attemptsRemaining: 60) { button in
                let pressed: Bool
                if let button {
                    pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                } else {
                    pressed = clickEstimatedAddDesktopButton(on: displayID)
                }
                guard pressed else {
                    closeMissionControl()
                    completion(nil)
                    return
                }
                waitForCreatedSpace(beforeIDs: beforeIDs, spaceSnapshot: spaceSnapshot, attemptsRemaining: 100) { createdID in
                    closeMissionControl()
                    completion(createdID)
                }
            }
        }
    }
    private static func openMissionControl() {
        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        if !NSWorkspace.shared.open(missionControlURL) {
            postControlArrow(up: true)
        }
    }
    private static func closeMissionControl() {
        postEscape()
    }
    private static func waitForAddDesktopButton(
        on displayID: CGDirectDisplayID,
        attemptsRemaining: Int,
        completion: @escaping (AXUIElement?) -> Void
    ) {
        if let button = copyAddDesktopButtonViaAccessibility(on: displayID) {
            completion(button)
            return
        }
        guard attemptsRemaining > 0 else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForAddDesktopButton(on: displayID, attemptsRemaining: attemptsRemaining - 1, completion: completion)
        }
    }
    private static func waitForCreatedSpace(
        beforeIDs: Set<SpaceID>,
        spaceSnapshot: @escaping () -> [ManagedDisplaySpaces],
        attemptsRemaining: Int,
        completion: @escaping (SpaceID?) -> Void
    ) {
        let afterIDs = Set(spaceSnapshot().flatMap { layout in
            layout.spaces.filter(\.isUserSpace).map(\.id)
        })
        if let createdID = afterIDs.subtracting(beforeIDs).sorted().first {
            completion(createdID)
            return
        }
        guard attemptsRemaining > 0 else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForCreatedSpace(
                beforeIDs: beforeIDs,
                spaceSnapshot: spaceSnapshot,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }
    private static func copyAddDesktopButtonViaAccessibility(on displayID: CGDirectDisplayID) -> AXUIElement? {
        if let button = copyAddDesktopButtonByIdentifier(on: displayID) {
            return button
        }
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var visited = Set<AXUIElementHash>()
        return findAddDesktopButton(in: dockElement, depth: 0, visited: &visited)
    }
    private static func copyAddDesktopButtonByIdentifier(on displayID: CGDirectDisplayID) -> AXUIElement? {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let missionControlGroup = copyChild(withIdentifier: "mc", in: dockElement),
              let displayGroup = copyDisplayGroup(in: missionControlGroup, displayID: displayID),
              let spacesGroup = copyChild(withIdentifier: "mc.spaces", in: displayGroup) else {
            return nil
        }
        return copyChild(withIdentifier: "mc.spaces.add", in: spacesGroup)
    }
    private static func copyDisplayGroup(in missionControlGroup: AXUIElement, displayID: CGDirectDisplayID) -> AXUIElement? {
        for child in copyAXElements(missionControlGroup, attribute: kAXChildrenAttribute) {
            guard copyString(child, attribute: "AXIdentifier") == "mc.display",
                  copyUInt32(child, attribute: "AXDisplayID") == displayID else {
                continue
            }
            return child
        }
        return nil
    }
    private static func copyChild(withIdentifier identifier: String, in element: AXUIElement) -> AXUIElement? {
        copyAXElements(element, attribute: kAXChildrenAttribute).first { child in
            copyString(child, attribute: "AXIdentifier") == identifier
        }
    }
    private static func findAddDesktopButton(
        in element: AXUIElement,
        depth: Int,
        visited: inout Set<AXUIElementHash>
    ) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let token = AXUIElementHash(element)
        guard !visited.contains(token) else { return nil }
        visited.insert(token)
        if isAddDesktopButton(element) { return element }
        for child in copyAXElements(element, attribute: kAXChildrenAttribute) {
            if let match = findAddDesktopButton(in: child, depth: depth + 1, visited: &visited) {
                return match
            }
        }
        return nil
    }
    private static func isAddDesktopButton(_ element: AXUIElement) -> Bool {
        let role = copyString(element, attribute: kAXRoleAttribute) ?? ""
        guard role == kAXButtonRole || role.localizedCaseInsensitiveContains("button") else {
            return false
        }
        let labels = [
            copyString(element, attribute: kAXTitleAttribute),
            copyString(element, attribute: kAXDescriptionAttribute),
            copyString(element, attribute: kAXHelpAttribute),
            copyString(element, attribute: "AXIdentifier")
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return labels.contains { label in
            let lower = label.lowercased()
            return lower == "+" || lower.contains("add desktop") || lower.contains("add space") || lower.contains("new desktop")
        }
    }
    private static func clickEstimatedAddDesktopButton(on displayID: CGDirectDisplayID?) -> Bool {
        let displayID = displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let point = CGPoint(x: bounds.maxX - 36, y: bounds.minY + 36)
        click(at: point)
        return true
    }
    private static func postControlArrow(up: Bool) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let key = CGKeyCode(up ? kVK_UpArrow : kVK_DownArrow)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = [.maskControl]
        upEvent?.flags = [.maskControl]
        down?.post(tap: .cghidEventTap)
        upEvent?.post(tap: .cghidEventTap)
    }
    private static func postEscape() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    private static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    private static func mainDisplayID() -> CGDirectDisplayID? {
        guard let screen = NSScreen.main else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
    private static func copyAXElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success,
              let rawValue,
              CFGetTypeID(rawValue) == CFArrayGetTypeID() else {
            return []
        }
        return (rawValue as? [AXUIElement]) ?? []
    }
    private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return rawValue as? String
    }
    private static func copyUInt32(_ element: AXUIElement, attribute: String) -> UInt32? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        return (rawValue as? NSNumber)?.uint32Value
    }
}
struct AXUIElementHash: Hashable {
    private let value: CFHashCode
    init(_ element: AXUIElement) {
        value = CFHash(element)
    }
}
enum SystemUIActivity {
    static func isMissionControlLikelyActive() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock" {
            return true
        }
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in infoList {
            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard ownerName == "Dock" else { continue }
            let windowName = (info[kCGWindowName as String] as? String) ?? ""
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let lower = windowName.lowercased()
            if lower.contains("mission control") || lower.contains("spaces") || (lower.contains("desktop") && layer > 0) {
                return true
            }
        }
        return false
    }
}
