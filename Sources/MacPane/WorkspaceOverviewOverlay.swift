import AppKit

final class WorkspaceDotView: NSView {
    private let isActive: Bool
    init(isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isActive ? 0 : 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: rect)
        if isActive {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

private final class WorkspaceOverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextFrame(for: super.drawingRect(forBounds: rect), bounds: rect)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredTextFrame(for: rect, bounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredTextFrame(for: rect, bounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    private func centeredTextFrame(for frame: NSRect, bounds: NSRect) -> NSRect {
        let textHeight = min(cellSize(forBounds: bounds).height, frame.height)
        let yOffset = max(0, floor((frame.height - textHeight) / 2))
        return NSRect(
            x: frame.minX,
            y: frame.minY + yOffset,
            width: frame.width,
            height: textHeight
        )
    }
}
final class WorkspaceOverviewOverlay {
    private var panel: WorkspaceOverviewPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var onDismiss: (() -> Void)?
    private var overview: WorkspaceOverview?
    var workspaceCount: Int? {
        overview?.workspaceCount
    }
    func show(_ overview: WorkspaceOverview, onDismiss: @escaping () -> Void) {
        hide(notify: true)
        self.overview = overview
        self.onDismiss = onDismiss
        let panel = ensurePanel()
        let frame = Self.panelFrame(for: overview)
        panel.setFrame(frame, display: true)
        let view = WorkspaceOverviewView(overview: overview)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        scheduleAutoHide()
    }
    @discardableResult
    func beginRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> Bool {
        guard let overview, let view = overviewView else { return false }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = ensurePanel()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        view.beginRenaming(
            text: overview.activeWorkspaceName ?? "",
            onCommit: { [weak self] name in
                self?.finishRenameMode()
                onCommit(name)
            },
            onCancel: { [weak self] in
                self?.finishRenameMode()
                onCancel()
            }
        )
        return true
    }
    private var overviewView: WorkspaceOverviewView? {
        panel?.contentView as? WorkspaceOverviewView
    }
    private func finishRenameMode() {
        overviewView?.endRenaming()
        panel?.ignoresMouseEvents = true
        scheduleAutoHide()
    }
    private func scheduleAutoHide() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: workItem)
    }
    func hide() {
        hide(notify: true)
    }
    private func hide(notify: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        overviewView?.endRenaming()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        guard notify else { return }
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        overview = nil
        onDismiss?()
    }
    func close() {
        hide(notify: true)
        panel?.close()
        panel = nil
    }
    private func ensurePanel() -> WorkspaceOverviewPanel {
        if let panel { return panel }
        let panel = WorkspaceOverviewPanel(
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
        self.panel = panel
        return panel
    }
    private static func panelFrame(for overview: WorkspaceOverview) -> CGRect {
        let screen = overview.displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 760, height: 520)
        let columns = min(3, max(1, overview.items.count))
        let rows = max(1, Int(ceil(Double(max(1, overview.items.count)) / Double(columns))))
        let idealWidth = CGFloat(columns) * 200 + CGFloat(max(0, columns - 1)) * 14 + 56
        let idealHeight = 110 + CGFloat(rows) * 156 + CGFloat(max(0, rows - 1)) * 14 + 56
        let width = min(max(420, idealWidth), max(360, visibleFrame.width - 64))
        let height = min(max(260, idealHeight), max(220, visibleFrame.height - 64))
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
private final class WorkspaceOverviewView: NSVisualEffectView, NSTextFieldDelegate {
    private let overview: WorkspaceOverview
    private weak var activeHeaderLabel: NSTextField?
    private weak var activeRenameField: NSTextField?
    private var activeDetailViews: [NSView] = []
    private var onRenameCommit: ((String) -> Void)?
    private var onRenameCancel: (() -> Void)?
    init(overview: WorkspaceOverview) {
        self.overview = overview
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    private func buildView() {
        activeDetailViews.removeAll()
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        let title = label(
            "MacPane Workspaces",
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: .labelColor
        )
        let subtitle = label(
            "\(overview.displayName) · Workspace \(overview.activeWorkspaceIndex + 1) of \(overview.workspaceCount)",
            font: .systemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor
        )
        let titleColumn = NSStackView(views: [title, subtitle])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2
        let dotsRow = workspaceDotsRow()
        let headerRow = NSStackView(views: [titleColumn, NSView(), dotsRow])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.distribution = .fill
        root.addArrangedSubview(headerRow)
        let grid = workspaceGrid()
        root.addArrangedSubview(grid)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            contentView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            headerRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            grid.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }
    private func workspaceDotsRow() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in overview.items {
            let dot = WorkspaceDotView(isActive: item.isActive)
            stack.addArrangedSubview(dot)
        }
        return stack
    }
    private func workspaceGrid() -> NSStackView {
        let columns = min(3, max(1, overview.items.count))
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .width
        grid.spacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < overview.items.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            row.translatesAutoresizingMaskIntoConstraints = false
            for _ in 0..<columns {
                if index < overview.items.count {
                    row.addArrangedSubview(card(for: overview.items[index]))
                    index += 1
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }
    private func card(for item: WorkspaceOverviewItem) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = item.isActive ? 2 : 1
        card.layer?.borderColor = (item.isActive ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
        card.layer?.backgroundColor = (item.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.55)).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 156).isActive = true
        let numberBackdrop = workspaceNumberBackdrop(for: item)
        card.addSubview(numberBackdrop)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        let header = label(
            workspaceTitle(for: item),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        stack.addArrangedSubview(header)
        if item.isActive {
            activeHeaderLabel = header
            let renameField = renameTextField()
            renameField.isHidden = true
            activeRenameField = renameField
            stack.addArrangedSubview(renameField)
        }
        if item.windows.isEmpty {
            let emptyLabel = label(
                "No tiled windows",
                font: .systemFont(ofSize: 12, weight: .regular),
                color: .tertiaryLabelColor
            )
            stack.addArrangedSubview(emptyLabel)
            if item.isActive {
                activeDetailViews.append(emptyLabel)
            }
        } else {
            for window in item.windows.prefix(4) {
                let label = windowLabel(for: window)
                stack.addArrangedSubview(label)
                if item.isActive {
                    activeDetailViews.append(label)
                }
            }
            if item.windows.count > 4 {
                let moreLabel = label(
                    "+\(item.windows.count - 4) more",
                    font: .systemFont(ofSize: 11, weight: .regular),
                    color: .secondaryLabelColor
                )
                stack.addArrangedSubview(moreLabel)
                if item.isActive {
                    activeDetailViews.append(moreLabel)
                }
            }
        }
        NSLayoutConstraint.activate([
            numberBackdrop.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            numberBackdrop.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            numberBackdrop.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 8),
            numberBackdrop.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }
    func beginRenaming(text: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard let activeRenameField else { return }
        onRenameCommit = onCommit
        onRenameCancel = onCancel
        activeHeaderLabel?.isHidden = true
        activeDetailViews.forEach { $0.isHidden = true }
        activeRenameField.stringValue = text
        activeRenameField.isHidden = false
        DispatchQueue.main.async { [weak self, weak activeRenameField] in
            guard let self, let activeRenameField else { return }
            self.window?.makeFirstResponder(activeRenameField)
            activeRenameField.selectText(nil)
        }
    }
    func endRenaming() {
        activeRenameField?.isHidden = true
        activeHeaderLabel?.isHidden = false
        activeDetailViews.forEach { $0.isHidden = false }
        onRenameCommit = nil
        onRenameCancel = nil
        window?.makeFirstResponder(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitActiveRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelActiveRename()
            return true
        default:
            return false
        }
    }
    private func commitActiveRename() {
        guard let activeRenameField, let onRenameCommit else { return }
        self.onRenameCommit = nil
        self.onRenameCancel = nil
        onRenameCommit(activeRenameField.stringValue)
    }
    private func cancelActiveRename() {
        guard let onRenameCancel else { return }
        self.onRenameCommit = nil
        self.onRenameCancel = nil
        onRenameCancel()
    }
    private func workspaceTitle(for item: WorkspaceOverviewItem) -> String {
        let defaultTitle = "Workspace \(item.index + 1)"
        return item.name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle
    }
    private func workspaceNumberBackdrop(for item: WorkspaceOverviewItem) -> NSTextField {
        let label = NSTextField(labelWithString: "\(item.index + 1)")
        label.font = .monospacedDigitSystemFont(ofSize: 58, weight: .bold)
        label.textColor = NSColor.labelColor.withAlphaComponent(item.isActive ? 0.13 : 0.08)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
    private func renameTextField() -> NSTextField {
        let field = NSTextField(string: "")
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.layer?.masksToBounds = true
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return field
    }
    private func windowLabel(for window: WorkspaceOverviewWindow) -> NSView {
        let detail = window.detail.map { " (\($0))" } ?? ""
        let textColor: NSColor = window.isFocused ? .labelColor : .secondaryLabelColor
        let textField = label(
            "\(window.title)\(detail)",
            font: .systemFont(ofSize: 11, weight: window.isFocused ? .semibold : .regular),
            color: textColor
        )
        let symbolName = window.isFocused ? "chevron.forward.circle.fill" : "app"
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            glyph.image = image
        }
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: window.isFocused ? .semibold : .regular)
        glyph.contentTintColor = window.isFocused ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        let row = NSStackView(views: [glyph, textField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13)
        ])
        return row
    }
    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
