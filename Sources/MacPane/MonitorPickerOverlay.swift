import AppKit

final class MonitorPickerOverlay {
    private var panel: OverlayPanel?
    private var onDismiss: (() -> Void)?
    private var onSelect: ((Int) -> Void)?
    private var optionCount = 0
    private var clickOutsideMonitor: Any?
    private var clickInsideMonitor: Any?
    private var dismissalObservers: [NSObjectProtocol] = []

    func show(
        options: [MonitorPickerOption],
        subtitle: String,
        onSelect: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        hide(notify: true)
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        optionCount = options.count
        let panel = ensurePanel()
        let frame = Self.panelFrame(for: options)
        let view = MonitorPickerView(options: options, subtitle: subtitle) { [weak self] index in
            _ = self?.choose(index: index)
        }
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.presentWithSpringFade(frame: frame)
        installDismissalMonitors()
    }
    @discardableResult
    func choose(index: Int) -> Bool {
        guard index >= 0, index < optionCount, let onSelect else { return false }
        let select = onSelect
        hide(notify: true)
        select(index)
        return true
    }
    func hide() {
        hide(notify: true)
    }
    private func hide(notify: Bool) {
        removeDismissalMonitors()
        panel?.orderOut(nil)
        guard notify else { return }
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        self.onSelect = nil
        optionCount = 0
        onDismiss?()
    }
    func close() {
        hide(notify: true)
        panel?.close()
        panel = nil
    }
    private func installDismissalMonitors() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
        clickInsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let self, event.window !== self.panel {
                self.hide()
            }
            return event
        }
        dismissalObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.hide()
        })
        dismissalObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        })
    }
    private func removeDismissalMonitors() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if let clickInsideMonitor {
            NSEvent.removeMonitor(clickInsideMonitor)
            self.clickInsideMonitor = nil
        }
        for observer in dismissalObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        dismissalObservers.removeAll()
    }
    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel.make()
        self.panel = panel
        return panel
    }
    private static func panelFrame(for options: [MonitorPickerOption]) -> CGRect {
        let sourceDisplayID = options.first(where: \.isSource)?.displayID
        let screen = sourceDisplayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 600)
        let columns = min(3, max(1, options.count))
        let rows = max(1, Int(ceil(Double(max(1, options.count)) / Double(columns))))
        let cardSize = Self.cardSize
        let idealWidth = CGFloat(columns) * cardSize.width + CGFloat(max(0, columns - 1)) * 14 + 48
        let idealHeight = 22 + 40 + CGFloat(rows) * cardSize.height + CGFloat(max(0, rows - 1)) * 14 + 30 + 14
        let width = min(idealWidth, max(360, visibleFrame.width - 64))
        let height = min(idealHeight, max(200, visibleFrame.height - 64))
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
    fileprivate static let cardSize = CGSize(width: 216, height: 96)
}

private final class MonitorPickerView: NSVisualEffectView {
    private let options: [MonitorPickerOption]
    private let onSelected: (Int) -> Void
    init(options: [MonitorPickerOption], subtitle: String, onSelected: @escaping (Int) -> Void) {
        self.options = options
        self.onSelected = onSelected
        super.init(frame: .zero)
        buildView(subtitle: subtitle)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    private func buildView(subtitle: String) {
        OverlayControls.configureContainer(self)
        let root = OverlayControls.makeContentRoot(in: self, topInset: 20, bottomInset: 14, spacing: 12)
        root.addArrangedSubview(OverlayControls.headerRow(title: "Move to Monitor", titleSize: 17, subtitle: subtitle))
        let grid = OverlayControls.cardsGrid(itemCount: options.count) { index in
            card(at: index)
        }
        root.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(OverlayControls.hintPillsRow([
            OverlayControls.hintPill(key: "1–9", text: "Move"),
            OverlayControls.hintPill(key: "esc", text: "Cancel")
        ]))
    }
    private func card(at index: Int) -> NSView {
        let option = options[index]
        let number = index + 1
        let card = OverlayCardView(
            accessibilityLabel: "\(number). \(option.name)",
            accessibilityValue: option.isSource ? "Current monitor" : nil,
            isProminent: option.isSource,
            onSelect: { [weak self] in
                self?.onSelected(index)
            }
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: MonitorPickerOverlay.cardSize.height).isActive = true
        let top = NSStackView()
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 7
        top.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(top)
        top.addArrangedSubview(OverlayControls.numberChip(number: number, isProminent: option.isSource))
        top.addArrangedSubview(OverlayControls.label(option.name, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor))
        if option.isSource {
            top.addArrangedSubview(OverlayControls.statusPill(text: "Current", filled: true))
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -14),
            top.centerYAnchor.constraint(equalTo: card.content.centerYAnchor)
        ])
        return card
    }
}
