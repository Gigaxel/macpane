import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: SettingsStore
    let onFinish: () -> Void
    @State private var step: Int = 0

    private let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Skip") {
                        store.markOnboardingCompleted()
                        onFinish()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                stepIndicator
                Spacer()
                if step < stepCount - 1 {
                    Button("Next") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") {
                        store.markOnboardingCompleted()
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 460)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { idx in
                Circle()
                    .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            WelcomeStep()
        case 1:
            AccessibilityStep(store: store)
        default:
            CheatsheetStep()
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "square.split.2x2")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to MacPane")
                .font(.system(size: 24, weight: .semibold))
            Text("A keyboard-driven, BSP tiling window manager for macOS.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(symbol: "rectangle.split.2x2", title: "Automatic tiling", subtitle: "New windows fill space; existing windows reflow.")
                FeatureRow(symbol: "square.stack.3d.up", title: "Virtual workspaces", subtitle: "Up to 9 workspaces per display, with names and overview.")
                FeatureRow(symbol: "keyboard", title: "Hotkey-first", subtitle: "Move focus, swap, resize, and cycle workspaces from the keyboard.")
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: store.accessibilityEnabled ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(store.accessibilityEnabled ? Color.green : Color.accentColor)
            Text(store.accessibilityEnabled ? "Accessibility access granted" : "Accessibility access required")
                .font(.system(size: 22, weight: .semibold))
            Text("MacPane uses the macOS Accessibility API to read, focus, and reposition windows. Without it, tiling can't work.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if !store.accessibilityEnabled {
                Button {
                    store.openAccessibilitySettings()
                } label: {
                    Label("Open System Settings…", systemImage: "arrow.up.right.square")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            Text("After granting access, you can return to this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

private struct CheatsheetStep: View {
    private let groups: [(title: String, rows: [(label: String, glyph: String)])] = [
        (
            "Focus & Move",
            [
                ("Focus neighbor", "⌘⌥ + arrow / HJKL"),
                ("Swap with neighbor", "⌘⇧ + arrow / HJKL"),
                ("Resize focused split", "⌘⌃ + arrow / HJKL"),
                ("Rotate split", "⌘⌥O"),
                ("Toggle floating", "⌘⌥G"),
                ("Balance BSP", "⌘⌥B")
            ]
        ),
        (
            "Workspaces",
            [
                ("Switch workspace 1–9", "⌘⌥ + 1…9"),
                ("Move window to workspace", "⌘⌃ + 1…9"),
                ("Previous / next workspace", "⌃⌥⌘ ← / →"),
                ("Show overview", "⌃⌥⌘V")
            ]
        ),
        (
            "App",
            [
                ("Open settings", "⌘⌥,"),
                ("Toggle tiling", "⌘⌥Y"),
                ("Toggle animations", "⌘⌥A"),
                ("Retile now", "⌘⌥R")
            ]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard cheatsheet")
                .font(.system(size: 22, weight: .semibold))
            Text("All shortcuts are global and rebindable in Settings → Shortcuts.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.rows, id: \.label) { row in
                                HStack {
                                    Text(row.label)
                                    Spacer()
                                    Text(row.glyph)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
