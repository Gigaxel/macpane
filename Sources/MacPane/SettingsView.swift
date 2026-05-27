import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: Tab = .general

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case general
        case shortcuts
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralSettingsView(store: store)
        case .shortcuts:
            ShortcutsSettingsView(store: store)
        case .about:
            AboutSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Tiling") {
                Toggle(
                    "Enable tiling",
                    isOn: Binding(
                        get: { store.tilingEnabled },
                        set: { store.setTilingEnabled($0) }
                    )
                )
                Toggle(
                    "Animate workspace switches",
                    isOn: Binding(
                        get: { store.workspaceSwitchAnimationsEnabled },
                        set: { store.setWorkspaceSwitchAnimationsEnabled($0) }
                    )
                )
            }

            Section("Layout") {
                LabeledContent("Window gap") {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { Double(store.gapPixels) },
                                set: { store.setGap(Int($0.rounded())) }
                            ),
                            in: Double(store.gapRange.lowerBound)...Double(store.gapRange.upperBound),
                            step: 1
                        )
                        Text("\(store.gapPixels) px")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Workspaces") {
                    HStack(spacing: 12) {
                        Text("\(store.workspaceCount)")
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .leading)
                        Spacer()
                        Button("Create") { store.createWorkspace() }
                            .disabled(!store.canCreateWorkspace)
                        Button("Delete Current") { store.deleteCurrentWorkspace() }
                            .disabled(!store.canDeleteCurrentWorkspace)
                    }
                }
            }

            Section("Permissions") {
                HStack(spacing: 10) {
                    Image(systemName: store.accessibilityEnabled ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(store.accessibilityEnabled ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.accessibilityEnabled ? "Accessibility access granted" : "Accessibility access required")
                            .font(.callout)
                        if !store.accessibilityEnabled {
                            Text("MacPane needs accessibility access to manage windows.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Open Accessibility Settings…") { store.openAccessibilitySettings() }
                }
            }

            Section("Maintenance") {
                Button("Retile Windows Now") { store.retileNow() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutGroupSpec: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let rows: [ShortcutRowSpec]
}

private struct ShortcutRowSpec: Identifiable {
    let id: String
    let label: String
    let identifier: String
    let mode: ShortcutRecorderView.Mode
    var hint: String? = nil
}

private struct FixedReferenceRow: Identifiable {
    let id = UUID()
    let label: String
    let display: String
}

private let shortcutGroups: [ShortcutGroupSpec] = [
    ShortcutGroupSpec(
        id: "focus-move",
        title: "Focus & Move",
        symbol: "arrow.up.left.and.down.right.magnifyingglass",
        rows: [
            ShortcutRowSpec(id: "focus", label: "Focus neighbor", identifier: "focus", mode: .modifierOnly, hint: "Modifier + arrow / HJKL"),
            ShortcutRowSpec(id: "swap", label: "Swap with neighbor", identifier: "swap", mode: .modifierOnly, hint: "Modifier + arrow / HJKL"),
            ShortcutRowSpec(id: "resize", label: "Resize focused split", identifier: "resize", mode: .modifierOnly, hint: "Modifier + arrow / HJKL")
        ]
    ),
    ShortcutGroupSpec(
        id: "workspaces",
        title: "Workspaces",
        symbol: "square.stack.3d.up",
        rows: [
            ShortcutRowSpec(id: "cycleWorkspace.prev", label: "Previous workspace", identifier: "cycleWorkspace.prev", mode: .atomic),
            ShortcutRowSpec(id: "cycleWorkspace.next", label: "Next workspace", identifier: "cycleWorkspace.next", mode: .atomic),
            ShortcutRowSpec(id: "createWorkspace", label: "Create workspace", identifier: "createWorkspace", mode: .atomic),
            ShortcutRowSpec(id: "deleteWorkspace", label: "Delete workspace", identifier: "deleteWorkspace", mode: .atomic),
            ShortcutRowSpec(id: "showWorkspaceOverview", label: "Show overview", identifier: "showWorkspaceOverview", mode: .atomic)
        ]
    ),
    ShortcutGroupSpec(
        id: "window",
        title: "Window",
        symbol: "macwindow",
        rows: [
            ShortcutRowSpec(id: "toggleFloating", label: "Toggle floating", identifier: "toggleFloating", mode: .atomic),
            ShortcutRowSpec(id: "toggleOrientation", label: "Rotate split", identifier: "toggleOrientation", mode: .atomic),
            ShortcutRowSpec(id: "balance", label: "Balance BSP tree", identifier: "balance", mode: .atomic),
            ShortcutRowSpec(id: "retile", label: "Retile now", identifier: "retile", mode: .atomic)
        ]
    ),
    ShortcutGroupSpec(
        id: "app",
        title: "App",
        symbol: "app.badge",
        rows: [
            ShortcutRowSpec(id: "toggleTiling", label: "Toggle tiling", identifier: "toggleTiling", mode: .atomic),
            ShortcutRowSpec(id: "toggleWorkspaceSwitchAnimations", label: "Toggle workspace animations", identifier: "toggleWorkspaceSwitchAnimations", mode: .atomic),
            ShortcutRowSpec(id: "openSettings", label: "Open settings", identifier: "openSettings", mode: .atomic)
        ]
    ),
    ShortcutGroupSpec(
        id: "gap",
        title: "Gap",
        symbol: "ruler",
        rows: [
            ShortcutRowSpec(id: "decreaseGap", label: "Decrease gap", identifier: "decreaseGap", mode: .atomic),
            ShortcutRowSpec(id: "increaseGap", label: "Increase gap", identifier: "increaseGap", mode: .atomic),
            ShortcutRowSpec(id: "resetGap", label: "Reset gap", identifier: "resetGap", mode: .atomic)
        ]
    )
]

private let fixedReferenceRows: [FixedReferenceRow] = [
    FixedReferenceRow(label: "Switch to workspace 1–9", display: "⌘⌥ + 1…9"),
    FixedReferenceRow(label: "Move focused window to workspace 1–9", display: "⌘⌃ + 1…9"),
    FixedReferenceRow(label: "Vim cycle workspaces", display: "⌃⌥⌘ H / L")
]

private struct ShortcutsSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(shortcutGroups) { group in
                    ShortcutGroupView(store: store, group: group)
                }
                FixedReferenceSection()
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") { store.resetAllShortcuts() }
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
    }
}

private struct ShortcutGroupView: View {
    @ObservedObject var store: SettingsStore
    let group: ShortcutGroupSpec

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    ShortcutRow(store: store, row: row)
                }
            }
            .padding(.vertical, 6)
        } label: {
            Label(group.title, systemImage: group.symbol)
                .font(.headline)
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var store: SettingsStore
    let row: ShortcutRowSpec
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.body)
                    if let hint = row.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                ShortcutRecorderView(
                    displayText: store.displayString(forIdentifier: row.identifier),
                    mode: row.mode
                ) { keyCode, modifiers in
                    if let message = store.setShortcut(identifier: row.identifier, keyCode: keyCode, modifiers: modifiers) {
                        errorMessage = message
                    } else {
                        errorMessage = nil
                    }
                }
                .frame(width: 200, height: 26)
                Button {
                    store.resetShortcut(identifier: row.identifier)
                    errorMessage = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
                .disabled(!store.isOverridden(identifier: row.identifier))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct FixedReferenceSection: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fixedReferenceRows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.display)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("These shortcuts aren't customizable in this version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        } label: {
            Label("Fixed Shortcuts", systemImage: "lock")
                .font(.headline)
        }
    }
}

private struct AboutSettingsView: View {
    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MacPane"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)
            Image(systemName: "square.split.2x2")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)
            Text(appName)
                .font(.system(size: 22, weight: .semibold))
            Text("Version \(appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("BSP tiling window manager for macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 2) {
                Text("Ad-hoc signed for local development.")
                Text("Requires Accessibility permission to manage windows.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
