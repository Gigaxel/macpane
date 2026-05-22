import AppKit
import ApplicationServices

final class WorkspaceSwitchIndicatorOverlay {
    private var panel: NSPanel?
    private var indicatorView: WorkspaceSwitchIndicatorView?
    private var fadeWorkItem: DispatchWorkItem?
    private var generation = 0
    func show(workspaceNumber: Int, displayID: CGDirectDisplayID?) {
        show(text: "\(workspaceNumber)", displayID: displayID)
    }
    func show(text: String, displayID: CGDirectDisplayID?) {
        generation += 1
        let currentGeneration = generation
        fadeWorkItem?.cancel()
        let panel = ensurePanel()
        indicatorView?.setText(text)
        panel.setFrame(Self.panelFrame(displayID: displayID), display: true)
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, self.generation == currentGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: {
                guard self.generation == currentGeneration else { return }
                panel.orderOut(nil)
            }
        }
        fadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }
    func close() {
        generation += 1
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        indicatorView = nil
    }
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        let indicatorView = WorkspaceSwitchIndicatorView()
        panel.contentView = indicatorView
        self.indicatorView = indicatorView
        self.panel = panel
        return panel
    }
    private static func panelFrame(displayID: CGDirectDisplayID?) -> CGRect {
        let screen = displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? Self.screenContainingCursor() ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 150, height: 150)
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
    private static func screenContainingCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) }
    }
}
private final class WorkspaceSwitchIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    func setText(_ text: String) {
        label.stringValue = text
        label.font = text.count <= 1
            ? .monospacedDigitSystemFont(ofSize: 76, weight: .bold)
            : .systemFont(ofSize: 58, weight: .bold)
    }
    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.26).cgColor
        layer?.borderWidth = 1
        label.font = .monospacedDigitSystemFont(ofSize: 76, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }
}
