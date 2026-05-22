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
    case balance
    case retile
    var shouldShowWorkspaceSwitchIndicator: Bool {
        switch self {
        case .createWorkspace, .deleteWorkspace, .switchWorkspace, .cycleWorkspace:
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
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var overviewHotKeyRefs: [EventHotKeyRef?] = []
    private var overviewActionIDs: Set<UInt32> = []
    private var hotKeysByID: [UInt32: RegisteredHotKey] = [:]
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
        registerHotKeys()
    }
    func stop() {
        delegate = nil
        unregisterWorkspaceOverviewHotKeys()
        for hotKeyRef in hotKeyRefs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        hotKeyRefs.removeAll()
        hotKeysByID.removeAll()
        nextID = 1
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    func registerWorkspaceOverviewHotKeys(workspaceCount: Int) {
        unregisterWorkspaceOverviewHotKeys()
        for item in workspaceKeyCodes().prefix(min(max(workspaceCount, 0), 9)) {
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
    private func registerHotKeys() {
        for item in directionalKeyCodes() {
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey), action: .focus(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | shiftKey), action: .swap(item.direction))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | controlKey), action: .resize(item.direction))
        }
        for item in workspaceKeyCodes() {
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey), action: .switchWorkspace(item.index))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | controlKey), action: .moveWindowToWorkspace(item.index))
            register(keyCode: item.keyCode, modifiers: UInt32(cmdKey | optionKey | controlKey), action: .moveWindowToWorkspace(item.index))
        }
        register(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(-1))
        register(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(1))
        register(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(-1))
        register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .cycleWorkspace(1))
        register(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .createWorkspace)
        register(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .deleteWorkspace)
        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey), action: .showWorkspaceOverview)
        register(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | optionKey), action: .toggleOrientation)
        register(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey), action: .toggleFloating)
        register(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | optionKey), action: .toggleTiling)
        register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey), action: .balance)
        register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), action: .retile)
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
    private func arrowKeyCodes() -> [(keyCode: UInt32, direction: SnapDirection)] {
        [
            (UInt32(kVK_LeftArrow), .left),
            (UInt32(kVK_DownArrow), .down),
            (UInt32(kVK_UpArrow), .up),
            (UInt32(kVK_RightArrow), .right)
        ]
    }
    private func workspaceKeyCodes() -> [(keyCode: UInt32, index: Int)] {
        [
            (UInt32(kVK_ANSI_1), 0),
            (UInt32(kVK_ANSI_2), 1),
            (UInt32(kVK_ANSI_3), 2),
            (UInt32(kVK_ANSI_4), 3),
            (UInt32(kVK_ANSI_5), 4),
            (UInt32(kVK_ANSI_6), 5),
            (UInt32(kVK_ANSI_7), 6),
            (UInt32(kVK_ANSI_8), 7),
            (UInt32(kVK_ANSI_9), 8)
        ]
    }
    private func directionalKeyCodes() -> [(keyCode: UInt32, direction: SnapDirection)] {
        arrowKeyCodes() + [
            (UInt32(kVK_ANSI_H), .left),
            (UInt32(kVK_ANSI_J), .down),
            (UInt32(kVK_ANSI_K), .up),
            (UInt32(kVK_ANSI_L), .right)
        ]
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
