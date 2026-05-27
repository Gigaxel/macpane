import AppKit
import ApplicationServices

final class WorkspaceSwitchIndicatorOverlay {
    private var panel: NSPanel?
    private var indicatorView: WorkspaceSwitchIndicatorView?
    private var fadeWorkItem: DispatchWorkItem?
    private var generation = 0
    func show(workspaceNumber: Int, workspaceCount: Int, displayID: CGDirectDisplayID?) {
        present(displayID: displayID) { view in
            view.applyWorkspaceContent(number: workspaceNumber, total: workspaceCount)
        }
    }
    func show(text: String, displayID: CGDirectDisplayID?) {
        present(displayID: displayID) { view in
            view.applyTextContent(text)
        }
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
    private func present(
        displayID: CGDirectDisplayID?,
        configure: (WorkspaceSwitchIndicatorView) -> Void
    ) {
        generation += 1
        let currentGeneration = generation
        fadeWorkItem?.cancel()
        let panel = ensurePanel()
        guard let indicatorView else { return }
        configure(indicatorView)
        panel.setFrame(Self.panelFrame(size: indicatorView.preferredSize, displayID: displayID), display: true)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
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
    private static func panelFrame(size: CGSize, displayID: CGDirectDisplayID?) -> CGRect {
        let screen = displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? Self.screenContainingCursor() ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
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

private final class WorkspaceSwitchIndicatorView: NSVisualEffectView {
    private let bigNumberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let dotsStack = NSStackView()
    private var bigNumberLeading: NSLayoutConstraint?
    private var bigNumberCenterX: NSLayoutConstraint?
    private var textCenterX: NSLayoutConstraint?
    private var textLeadingFromNumber: NSLayoutConstraint?
    private(set) var preferredSize: CGSize = CGSize(width: 180, height: 130)

    init() {
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    func applyWorkspaceContent(number: Int, total: Int) {
        bigNumberLabel.stringValue = "\(number)"
        bigNumberLabel.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        bigNumberLabel.textColor = .labelColor
        bigNumberLabel.isHidden = false
        textLabel.isHidden = true
        rebuildDots(total: total, active: number - 1)
        dotsStack.isHidden = total <= 1
        bigNumberCenterX?.isActive = true
        bigNumberLeading?.isActive = false
        textCenterX?.isActive = false
        textLeadingFromNumber?.isActive = false
        preferredSize = total <= 1
            ? CGSize(width: 150, height: 150)
            : CGSize(width: 160, height: 160)
        invalidateIntrinsicContentSize()
    }

    func applyTextContent(_ text: String) {
        textLabel.stringValue = text
        textLabel.font = text.count <= 2
            ? .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
            : .systemFont(ofSize: 36, weight: .semibold)
        textLabel.textColor = .labelColor
        textLabel.isHidden = false
        bigNumberLabel.isHidden = true
        dotsStack.isHidden = true
        bigNumberCenterX?.isActive = false
        bigNumberLeading?.isActive = false
        textCenterX?.isActive = true
        textLeadingFromNumber?.isActive = false
        preferredSize = CGSize(width: 220, height: 130)
        invalidateIntrinsicContentSize()
    }

    private func buildView() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 1

        bigNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        bigNumberLabel.alignment = .center
        addSubview(bigNumberLabel)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.alignment = .center
        textLabel.isHidden = true
        addSubview(textLabel)

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.orientation = .horizontal
        dotsStack.alignment = .centerY
        dotsStack.spacing = 7
        addSubview(dotsStack)

        bigNumberCenterX = bigNumberLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        bigNumberLeading = bigNumberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28)
        textCenterX = textLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        textLeadingFromNumber = textLabel.leadingAnchor.constraint(equalTo: bigNumberLabel.trailingAnchor, constant: 14)

        NSLayoutConstraint.activate([
            bigNumberLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        bigNumberCenterX?.isActive = true
    }

    private func rebuildDots(total: Int, active: Int) {
        dotsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard total > 1 else { return }
        for index in 0..<total {
            let dot = WorkspaceDotView(isActive: index == active)
            dotsStack.addArrangedSubview(dot)
        }
    }
}
