import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    enum Mode {
        case atomic
        case modifierOnly
        case fixed
    }

    let displayText: String
    let mode: Mode
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to nsView: ShortcutRecorderNSView) {
        nsView.displayText = displayText
        nsView.mode = mode
        nsView.onCapture = onCapture
    }
}

final class ShortcutRecorderNSView: NSView {
    var displayText: String = "" { didSet { needsDisplay = true } }
    var mode: ShortcutRecorderView.Mode = .atomic {
        didSet {
            if mode == .fixed {
                endRecording()
            }
            needsDisplay = true
        }
    }
    var onCapture: ((UInt32, UInt32) -> Void)?
    private var windowObserverTokens: [NSObjectProtocol] = []

    private(set) var isRecording: Bool = false {
        didSet { needsDisplay = true }
    }

    deinit {
        removeWindowObservers()
        endRecording()
    }

    override var acceptsFirstResponder: Bool { mode != .fixed }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 26)
    }

    override func mouseDown(with event: NSEvent) {
        guard mode != .fixed else { return }
        if isRecording {
            endRecording()
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result && mode != .fixed {
            beginRecording()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            endRecording()
            removeWindowObservers()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = HotKeyGlyphs.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        let keyCode = UInt32(event.keyCode)
        endRecording()
        window?.makeFirstResponder(nil)
        onCapture?(keyCode, modifiers)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 0.5
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 5,
            yRadius: 5
        )
        let fill: NSColor
        let stroke: NSColor
        let strokeWidth: CGFloat
        switch (mode, isRecording) {
        case (.fixed, _):
            fill = NSColor.controlColor.withAlphaComponent(0.5)
            stroke = NSColor.separatorColor
            strokeWidth = 1.0
        case (_, true):
            fill = NSColor.controlAccentColor.withAlphaComponent(0.18)
            stroke = NSColor.controlAccentColor
            strokeWidth = 1.5
        default:
            fill = NSColor.controlColor
            stroke = NSColor.separatorColor
            strokeWidth = 1.0
        }
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()

        let text: String
        if mode == .fixed {
            text = displayText.isEmpty ? "—" : displayText
        } else if isRecording {
            text = mode == .modifierOnly ? "Hold modifiers + key" : "Type new shortcut"
        } else {
            text = displayText.isEmpty ? "—" : displayText
        }
        let textColor: NSColor
        switch (mode, isRecording) {
        case (.fixed, _): textColor = .tertiaryLabelColor
        case (_, true): textColor = .secondaryLabelColor
        default: textColor = .labelColor
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrString.size()
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attrString.draw(in: textRect)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        HotKeyManager.shared.endShortcutRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        HotKeyManager.shared.beginShortcutRecording()
        isRecording = true
    }

    private func installWindowObservers() {
        guard windowObserverTokens.isEmpty, let window else { return }
        let center = NotificationCenter.default
        windowObserverTokens = [
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.endRecording()
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.endRecording()
            }
        ]
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObserverTokens {
            center.removeObserver(token)
        }
        windowObserverTokens.removeAll()
    }
}
