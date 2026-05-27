import ApplicationServices
import Carbon
import Foundation

protocol HotKeyHandling: AnyObject {
    func handle(action: HotKeyAction, eventAge: TimeInterval, triggerKeyIsDown: Bool)
}
enum HotKeyAction {
    case focus(SnapDirection)
    case swap(SnapDirection)
    case resize(SnapDirection)
    case createWorkspace
    case deleteWorkspace
    case switchWorkspace(Int)
    case moveWindowToWorkspace(Int)
    case cycleWorkspace(Int)
    case showWorkspaceOverview
    case hideWorkspaceOverview
    case overviewSwitchWorkspace(Int)
    case overviewRenameStart
    case toggleOrientation
    case toggleFloating
    case toggleTiling
    case toggleWorkspaceSwitchAnimations
    case balance
    case retile
    case openSettings
    case decreaseGap
    case increaseGap
    case resetGap
    var shouldShowWorkspaceSwitchIndicator: Bool {
        switch self {
        case .createWorkspace, .deleteWorkspace, .switchWorkspace, .cycleWorkspace:
            return true
        default:
            return false
        }
    }
    var isWorkspaceMutation: Bool {
        switch self {
        case .createWorkspace, .deleteWorkspace, .switchWorkspace, .cycleWorkspace, .moveWindowToWorkspace:
            return true
        default:
            return false
        }
    }
    var shouldDropWhenStale: Bool {
        switch self {
        case .focus, .overviewSwitchWorkspace:
            return true
        default:
            return false
        }
    }
    var shouldDropWhenTriggerReleased: Bool {
        switch self {
        case .focus:
            return true
        default:
            return false
        }
    }
}
private struct RegisteredHotKey {
    let action: HotKeyAction
    let keyCode: UInt32
}
final class HotKeyManager {
    static let shared = HotKeyManager()
    weak var delegate: HotKeyHandling?
    let bindingStore = HotKeyBindingStore()
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var overviewHotKeyRefs: [EventHotKeyRef?] = []
    private var overviewActionIDs: Set<UInt32> = []
    private var hotKeysByID: [UInt32: RegisteredHotKey] = [:]
    private var recordingSuppressionCount = 0
    private var nextID: UInt32 = 1
    private let signature = fourCharCode("MCPN")
    private init() {}
    func start() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            NSLog("MacPane failed to install hotkey handler: \(handlerStatus)")
            return
        }
        registerMainHotKeys()
    }
    func stop() {
        delegate = nil
        unregisterWorkspaceOverviewHotKeys()
        unregisterMainHotKeys()
        recordingSuppressionCount = 0
        nextID = 1
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    func reregisterMainHotKeys() {
        unregisterMainHotKeys()
        guard recordingSuppressionCount == 0 else { return }
        registerMainHotKeys()
    }
    func beginShortcutRecording() {
        guard eventHandler != nil else { return }
        recordingSuppressionCount += 1
        guard recordingSuppressionCount == 1 else { return }
        unregisterMainHotKeys()
    }
    func endShortcutRecording() {
        guard recordingSuppressionCount > 0 else { return }
        recordingSuppressionCount -= 1
        guard recordingSuppressionCount == 0, eventHandler != nil else { return }
        registerMainHotKeys()
    }
    func registerWorkspaceOverviewHotKeys(workspaceCount: Int) {
        unregisterWorkspaceOverviewHotKeys()
        for item in workspaceKeyCodes.prefix(min(max(workspaceCount, 0), 9)) {
            registerOverviewHotKey(keyCode: item.keyCode, modifiers: 0, action: .overviewSwitchWorkspace(item.index))
        }
        registerOverviewHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: 0, action: .overviewRenameStart)
        registerOverviewHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(shiftKey), action: .overviewRenameStart)
        registerOverviewHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, action: .hideWorkspaceOverview)
    }
    func unregisterWorkspaceOverviewHotKeys() {
        for hotKeyRef in overviewHotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        overviewHotKeyRefs.removeAll()
        for id in overviewActionIDs {
            hotKeysByID.removeValue(forKey: id)
        }
        overviewActionIDs.removeAll()
    }
    func handleHotKey(id: UInt32, eventAge: TimeInterval) {
        guard let hotKey = hotKeysByID[id] else { return }
        let triggerKeyIsDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(hotKey.keyCode))
        delegate?.handle(action: hotKey.action, eventAge: eventAge, triggerKeyIsDown: triggerKeyIsDown)
    }
    private func registerMainHotKeys() {
        for binding in bindingStore.effectiveBindings() {
            register(keyCode: binding.keyCode, modifiers: binding.modifiers, action: binding.entry.action)
        }
    }
    private func unregisterMainHotKeys() {
        for hotKeyRef in hotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        hotKeyRefs.removeAll()
        let mainIDs = Set(hotKeysByID.keys).subtracting(overviewActionIDs)
        for id in mainIDs {
            hotKeysByID.removeValue(forKey: id)
        }
    }
    private func register(keyCode: UInt32, modifiers: UInt32, action: HotKeyAction) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            hotKeysByID[id] = RegisteredHotKey(action: action, keyCode: keyCode)
            hotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("MacPane failed to register hotkey id=\(id) key=\(keyCode) modifiers=\(modifiers): \(status)")
        }
    }
    private func registerOverviewHotKey(keyCode: UInt32, modifiers: UInt32, action: HotKeyAction) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            hotKeysByID[id] = RegisteredHotKey(action: action, keyCode: keyCode)
            overviewActionIDs.insert(id)
            overviewHotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("MacPane failed to register overview hotkey id=\(id) key=\(keyCode) modifiers=\(modifiers): \(status)")
        }
    }
}
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr {
        let eventAge = max(0, GetCurrentEventTime() - GetEventTime(event))
        HotKeyManager.shared.handleHotKey(id: hotKeyID.id, eventAge: eventAge)
    }
    return noErr
}
private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(byte)
    }
    return result
}
