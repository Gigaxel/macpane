import Carbon
import Foundation

enum HotKeyBindingScope {
    case atomic
    case directionTemplate
    case fixed
}

struct HotKeyBindingEntry {
    let identifier: String
    let keyCode: UInt32
    let defaultModifiers: UInt32
    let scope: HotKeyBindingScope
    let action: HotKeyAction
}

struct HotKeyBindingOverride: Codable, Equatable {
    var keyCode: UInt32?
    var modifiers: UInt32
}

enum HotKeyBindingDefaults {
    static let entries: [HotKeyBindingEntry] = buildEntries()

    private static func buildEntries() -> [HotKeyBindingEntry] {
        var entries: [HotKeyBindingEntry] = []
        let cmdOpt = UInt32(cmdKey | optionKey)
        let cmdShift = UInt32(cmdKey | shiftKey)
        let cmdCtrl = UInt32(cmdKey | controlKey)
        let cmdOptCtrl = UInt32(cmdKey | optionKey | controlKey)

        for item in directionalKeyCodes {
            entries.append(HotKeyBindingEntry(
                identifier: "focus",
                keyCode: item.keyCode,
                defaultModifiers: cmdOpt,
                scope: .directionTemplate,
                action: .focus(item.direction)
            ))
            entries.append(HotKeyBindingEntry(
                identifier: "swap",
                keyCode: item.keyCode,
                defaultModifiers: cmdShift,
                scope: .directionTemplate,
                action: .swap(item.direction)
            ))
            entries.append(HotKeyBindingEntry(
                identifier: "resize",
                keyCode: item.keyCode,
                defaultModifiers: cmdCtrl,
                scope: .directionTemplate,
                action: .resize(item.direction)
            ))
        }

        for item in workspaceKeyCodes {
            entries.append(HotKeyBindingEntry(
                identifier: "switchWorkspace.\(item.index)",
                keyCode: item.keyCode,
                defaultModifiers: cmdOpt,
                scope: .fixed,
                action: .switchWorkspace(item.index)
            ))
            entries.append(HotKeyBindingEntry(
                identifier: "moveWindowToWorkspace.\(item.index)",
                keyCode: item.keyCode,
                defaultModifiers: cmdCtrl,
                scope: .fixed,
                action: .moveWindowToWorkspace(item.index)
            ))
            entries.append(HotKeyBindingEntry(
                identifier: "moveWindowToWorkspace.alt.\(item.index)",
                keyCode: item.keyCode,
                defaultModifiers: cmdOptCtrl,
                scope: .fixed,
                action: .moveWindowToWorkspace(item.index)
            ))
        }

        entries.append(HotKeyBindingEntry(
            identifier: "cycleWorkspace.prev",
            keyCode: UInt32(kVK_LeftArrow),
            defaultModifiers: cmdOptCtrl,
            scope: .atomic,
            action: .cycleWorkspace(-1)
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "cycleWorkspace.next",
            keyCode: UInt32(kVK_RightArrow),
            defaultModifiers: cmdOptCtrl,
            scope: .atomic,
            action: .cycleWorkspace(1)
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "cycleWorkspace.prev.vim",
            keyCode: UInt32(kVK_ANSI_H),
            defaultModifiers: cmdOptCtrl,
            scope: .fixed,
            action: .cycleWorkspace(-1)
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "cycleWorkspace.next.vim",
            keyCode: UInt32(kVK_ANSI_L),
            defaultModifiers: cmdOptCtrl,
            scope: .fixed,
            action: .cycleWorkspace(1)
        ))

        entries.append(HotKeyBindingEntry(
            identifier: "createWorkspace",
            keyCode: UInt32(kVK_ANSI_Equal),
            defaultModifiers: cmdOptCtrl,
            scope: .atomic,
            action: .createWorkspace
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "deleteWorkspace",
            keyCode: UInt32(kVK_ANSI_Minus),
            defaultModifiers: cmdOptCtrl,
            scope: .atomic,
            action: .deleteWorkspace
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "showWorkspaceOverview",
            keyCode: UInt32(kVK_ANSI_V),
            defaultModifiers: cmdOptCtrl,
            scope: .atomic,
            action: .showWorkspaceOverview
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "toggleOrientation",
            keyCode: UInt32(kVK_ANSI_O),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .toggleOrientation
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "toggleFloating",
            keyCode: UInt32(kVK_ANSI_G),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .toggleFloating
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "toggleTiling",
            keyCode: UInt32(kVK_ANSI_Y),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .toggleTiling
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "toggleWorkspaceSwitchAnimations",
            keyCode: UInt32(kVK_ANSI_A),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .toggleWorkspaceSwitchAnimations
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "balance",
            keyCode: UInt32(kVK_ANSI_B),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .balance
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "retile",
            keyCode: UInt32(kVK_ANSI_R),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .retile
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "openSettings",
            keyCode: UInt32(kVK_ANSI_Comma),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .openSettings
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "decreaseGap",
            keyCode: UInt32(kVK_ANSI_LeftBracket),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .decreaseGap
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "increaseGap",
            keyCode: UInt32(kVK_ANSI_RightBracket),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .increaseGap
        ))
        entries.append(HotKeyBindingEntry(
            identifier: "resetGap",
            keyCode: UInt32(kVK_ANSI_0),
            defaultModifiers: cmdOpt,
            scope: .atomic,
            action: .resetGap
        ))

        return entries
    }
}

let workspaceKeyCodes: [(keyCode: UInt32, index: Int)] = [
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

let directionalKeyCodes: [(keyCode: UInt32, direction: SnapDirection)] = [
    (UInt32(kVK_LeftArrow), .left),
    (UInt32(kVK_DownArrow), .down),
    (UInt32(kVK_UpArrow), .up),
    (UInt32(kVK_RightArrow), .right),
    (UInt32(kVK_ANSI_H), .left),
    (UInt32(kVK_ANSI_J), .down),
    (UInt32(kVK_ANSI_K), .up),
    (UInt32(kVK_ANSI_L), .right)
]

final class HotKeyBindingStore {
    enum BindingError: Error, Equatable {
        case notRebindable
        case conflict(existingIdentifier: String)
        case invalidModifiers
    }

    private let defaults: UserDefaults
    private static let storageKey = "hotKeyBindingOverrides_v1"
    private static let requiredGlobalModifierMask = UInt32(cmdKey | optionKey | controlKey)
    private var overridesByIdentifier: [String: HotKeyBindingOverride]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: HotKeyBindingOverride].self, from: data) {
            self.overridesByIdentifier = decoded
        } else {
            self.overridesByIdentifier = [:]
        }
    }

    func effectiveBindings() -> [(entry: HotKeyBindingEntry, keyCode: UInt32, modifiers: UInt32)] {
        let entries = HotKeyBindingDefaults.entries
        let overridesByIdentifier = self.overridesByIdentifier
        return entries.map { entry in
            let override = entry.scope == .fixed ? nil : overridesByIdentifier[entry.identifier]
            let keyCode: UInt32
            let modifiers: UInt32
            switch entry.scope {
            case .atomic:
                keyCode = override?.keyCode ?? entry.keyCode
                modifiers = override?.modifiers ?? entry.defaultModifiers
            case .directionTemplate:
                keyCode = entry.keyCode
                modifiers = override?.modifiers ?? entry.defaultModifiers
            case .fixed:
                keyCode = entry.keyCode
                modifiers = entry.defaultModifiers
            }
            return (entry, keyCode, modifiers)
        }
    }

    func override(forIdentifier identifier: String) -> HotKeyBindingOverride? {
        overridesByIdentifier[identifier]
    }

    @discardableResult
    func setOverride(forIdentifier identifier: String, keyCode: UInt32, modifiers: UInt32) -> Result<Void, BindingError> {
        guard let entry = HotKeyBindingDefaults.entries.first(where: { $0.identifier == identifier }) else {
            return .failure(.notRebindable)
        }
        guard entry.scope != .fixed else {
            return .failure(.notRebindable)
        }
        guard modifiers & Self.requiredGlobalModifierMask != 0 else {
            return .failure(.invalidModifiers)
        }
        let override: HotKeyBindingOverride
        switch entry.scope {
        case .atomic:
            override = HotKeyBindingOverride(keyCode: keyCode, modifiers: modifiers)
        case .directionTemplate:
            override = HotKeyBindingOverride(keyCode: nil, modifiers: modifiers)
        case .fixed:
            return .failure(.notRebindable)
        }
        var trial = overridesByIdentifier
        trial[identifier] = override
        if let conflict = firstConflict(in: effectiveBindings(usingOverrides: trial), excludingIdentifier: identifier) {
            return .failure(.conflict(existingIdentifier: conflict))
        }
        overridesByIdentifier[identifier] = override
        persist()
        return .success(())
    }

    func resetOverride(forIdentifier identifier: String) {
        guard overridesByIdentifier.removeValue(forKey: identifier) != nil else { return }
        persist()
    }

    func resetAll() {
        guard !overridesByIdentifier.isEmpty else { return }
        overridesByIdentifier.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overridesByIdentifier) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func effectiveBindings(usingOverrides overrides: [String: HotKeyBindingOverride])
        -> [(entry: HotKeyBindingEntry, keyCode: UInt32, modifiers: UInt32)] {
        HotKeyBindingDefaults.entries.map { entry in
            let override = entry.scope == .fixed ? nil : overrides[entry.identifier]
            let keyCode: UInt32
            let modifiers: UInt32
            switch entry.scope {
            case .atomic:
                keyCode = override?.keyCode ?? entry.keyCode
                modifiers = override?.modifiers ?? entry.defaultModifiers
            case .directionTemplate:
                keyCode = entry.keyCode
                modifiers = override?.modifiers ?? entry.defaultModifiers
            case .fixed:
                keyCode = entry.keyCode
                modifiers = entry.defaultModifiers
            }
            return (entry, keyCode, modifiers)
        }
    }

    private func firstConflict(
        in bindings: [(entry: HotKeyBindingEntry, keyCode: UInt32, modifiers: UInt32)],
        excludingIdentifier identifier: String
    ) -> String? {
        struct Key: Hashable { let keyCode: UInt32; let modifiers: UInt32 }
        var seen: [Key: String] = [:]
        for binding in bindings {
            let key = Key(keyCode: binding.keyCode, modifiers: binding.modifiers)
            let owner = binding.entry.identifier
            if owner == identifier {
                if let existing = seen[key], existing != identifier {
                    return existing
                }
                seen[key] = owner
                continue
            }
            if let existing = seen[key] {
                if existing == identifier {
                    return owner
                }
                continue
            }
            seen[key] = owner
        }
        return nil
    }
}
