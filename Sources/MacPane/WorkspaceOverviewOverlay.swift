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
    private var onDismiss: (() -> Void)?
    private var overview: WorkspaceOverview?
    var workspaceCount: Int? {
        overview?.workspaceCount
    }
    func show(_ overview: WorkspaceOverview, onSelect: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        hide(notify: true)
        self.overview = overview
        self.onDismiss = onDismiss
        let panel = ensurePanel()
        let frame = Self.panelFrame(for: overview)
        let cardHeight = Self.workspaceCardHeight(for: overview)
        let view = WorkspaceOverviewView(overview: overview, cardHeight: cardHeight, onWorkspaceSelected: onSelect)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.ignoresMouseEvents = false
        // Start slightly smaller and clear, then spring to full size with a fade.
        let startFrame = CGRect(
            x: frame.midX - frame.width * 0.94 / 2,
            y: frame.midY - frame.height * 0.94 / 2,
            width: frame.width * 0.94,
            height: frame.height * 0.94
        )
        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }
    @discardableResult
    func beginRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> Bool {
        guard let overview, let view = overviewView else { return false }
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
    }
    func hide() {
        hide(notify: true)
    }
    private func hide(notify: Bool) {
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
        panel.hasShadow = true
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
        let idealWidth = CGFloat(columns) * 196 + CGFloat(max(0, columns - 1)) * 14 + 48
        let cardHeight = workspaceCardHeight(for: overview)
        let idealHeight = 56 + 32 + CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * 14 + 38 + 14
        let width = min(max(420, idealWidth), max(360, visibleFrame.width - 64))
        let height = min(max(300, idealHeight), max(260, visibleFrame.height - 64))
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
    private static func workspaceCardHeight(for overview: WorkspaceOverview) -> CGFloat {
        let screen = overview.displayID.flatMap { displayID in
            NSScreen.screens.first { $0.displayID == displayID }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 760, height: 520)
        let columns = min(3, max(1, overview.items.count))
        let rows = max(1, Int(ceil(Double(max(1, overview.items.count)) / Double(columns))))
        let available = visibleFrame.height - 64 - 56 - 32 - 38 - 14 - CGFloat(max(0, rows - 1)) * 14
        let perRow = max(0, available / CGFloat(rows))
        return min(200, max(152, perRow))
    }
}

private final class WorkspaceGlassBackgroundView: NSView {
    private let gradientLayer = CAGradientLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        gradientLayer.cornerRadius = 22
        layer?.addSublayer(gradientLayer)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        if gradientLayer.colors == nil {
            let (top, bottom): (CGFloat, CGFloat)
            if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                (top, bottom) = (0.07, 0.03)
            } else {
                (top, bottom) = (0.11, 0.045)
            }
            gradientLayer.colors = [
                NSColor.white.withAlphaComponent(top).cgColor,
                NSColor.white.withAlphaComponent(bottom).cgColor
            ]
        }
    }
}

private final class WorkspaceCardView: NSView {
    private let onSelect: () -> Void
    private let isActive: Bool
    private var isHovered = false
    private var isRenaming = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private let glassLayer = CALayer()
    private let strokeLayer = CALayer()
    fileprivate let content: NSView

    init(title: String, isActive: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.isActive = isActive
        self.content = NSView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        glassLayer.cornerRadius = 14
        strokeLayer.cornerRadius = 14
        layer?.addSublayer(glassLayer)
        layer?.addSublayer(strokeLayer)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityValue(isActive ? "Current workspace" : nil)
        updateStyle()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    override func layout() {
        super.layout()
        glassLayer.frame = bounds
        strokeLayer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    }
    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateStyle()
    }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateStyle()
    }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        updateStyle()
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            select()
        }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isRenaming ? .arrow : .pointingHand)
    }
    func setRenaming(_ renaming: Bool) {
        isRenaming = renaming
        setAccessibilityEnabled(!renaming)
        updateStyle()
        window?.invalidateCursorRects(for: self)
    }
    override func accessibilityPerformPress() -> Bool {
        guard !isRenaming else { return false }
        select()
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The card owns all clicks except during rename, where the
        // text field must receive them directly.
        guard super.hitTest(point) != nil else { return nil }
        if isRenaming {
            return super.hitTest(point)
        }
        return self
    }
    private func updateStyle() {
        let hover = isHovered && !isRenaming
        let pressed = isPressed && !isRenaming
        let borderColor: NSColor
        let borderWidth: CGFloat
        let shadowColor: NSColor?
        let shadowOpacity: CGFloat
        let shadowBlur: CGFloat
        if isActive {
            borderColor = NSColor.controlAccentColor
            borderWidth = 1.6
            shadowColor = NSColor.controlAccentColor
            shadowOpacity = pressed ? 0.5 : (hover ? 0.45 : 0.30)
            shadowBlur = pressed ? 16 : (hover ? 18 : 14)
        } else if pressed {
            borderColor = NSColor.white.withAlphaComponent(0.30)
            borderWidth = 1
            shadowColor = NSColor.black
            shadowOpacity = 0.22
            shadowBlur = 12
        } else if hover {
            borderColor = NSColor.white.withAlphaComponent(0.30)
            borderWidth = 1
            shadowColor = NSColor.black
            shadowOpacity = 0.20
            shadowBlur = 14
        } else {
            borderColor = NSColor.white.withAlphaComponent(0.08)
            borderWidth = 1
            shadowColor = NSColor.black
            shadowOpacity = 0.12
            shadowBlur = 10
        }
        strokeLayer.borderColor = borderColor.cgColor
        strokeLayer.borderWidth = borderWidth
        layer?.shadowColor = shadowColor?.cgColor
        layer?.shadowOpacity = Float(shadowOpacity)
        layer?.shadowRadius = shadowBlur
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        glassLayer.backgroundColor = NSColor.white.withAlphaComponent(isActive ? 0.10 : 0.055).cgColor
    }
    private func select() {
        guard !isRenaming else { return }
        onSelect()
    }
}

private final class WorkspaceOverviewView: NSVisualEffectView, NSTextFieldDelegate {
    private let overview: WorkspaceOverview
    private let cardHeight: CGFloat
    private let onWorkspaceSelected: (Int) -> Void
    private weak var activeHeaderLabel: NSTextField?
    private weak var activeRenameField: NSTextField?
    private var activeDetailViews: [NSView] = []
    private var onRenameCommit: ((String) -> Void)?
    private var onRenameCancel: (() -> Void)?
    private var workspaceCards: [WorkspaceCardView] = []
    init(overview: WorkspaceOverview, cardHeight: CGFloat, onWorkspaceSelected: @escaping (Int) -> Void) {
        self.overview = overview
        self.cardHeight = cardHeight
        self.onWorkspaceSelected = onWorkspaceSelected
        super.init(frame: .zero)
        buildView()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }
    private func buildView() {
        activeDetailViews.removeAll()
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        let glass = WorkspaceGlassBackgroundView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        let title = label(
            "Workspaces",
            font: .systemFont(ofSize: 20, weight: .bold),
            color: .labelColor
        )
        let subtitle = label(
            "\(overview.displayName) · Workspace \(overview.activeWorkspaceIndex + 1) of \(overview.workspaceCount)",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        let titleColumn = NSStackView(views: [title, subtitle])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 3
        let headerRow = NSStackView(views: [titleColumn, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12
        headerRow.distribution = .fill
        root.addArrangedSubview(headerRow)
        let grid = workspaceGrid()
        root.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let footerRow = footerHintsRow()
        root.addArrangedSubview(footerRow)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
    private func footerHintsRow() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hintPill(key: "1–9", text: "Switch"))
        stack.addArrangedSubview(hintPill(key: "R", text: "Rename"))
        stack.addArrangedSubview(hintPill(key: "esc", text: "Close"))
        return stack
    }
    private func hintPill(key: String, text: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        let textLabel = label(
            text,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .tertiaryLabelColor
        )
        let stack = NSStackView(views: [keyLabel, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        pill.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4)
        ])
        return pill
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
    private func card(for item: WorkspaceOverviewItem) -> WorkspaceCardView {
        let card = WorkspaceCardView(
            title: workspaceTitle(for: item),
            isActive: item.isActive,
            onSelect: { [weak self] in
                self?.onWorkspaceSelected(item.index)
            }
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
        workspaceCards.append(card)
        let top = NSStackView()
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(top)
        let chip = workspaceNumberChip(for: item)
        top.addArrangedSubview(chip)
        let header = label(
            workspaceTitle(for: item),
            font: .systemFont(ofSize: 13.5, weight: .semibold),
            color: .labelColor
        )
        top.addArrangedSubview(header)
        if item.isActive {
            activeHeaderLabel = header
            let renameField = renameTextField()
            renameField.isHidden = true
            activeRenameField = renameField
            top.addArrangedSubview(renameField)
            renameField.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }
        let detail: NSView
        if item.windows.isEmpty {
            detail = emptyStateView()
        } else {
            detail = miniMap(for: item)
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        if item.isActive {
            activeDetailViews.append(detail)
        }
        card.content.addSubview(detail)
        let pill = item.isActive
            ? statusPill(text: "Current", filled: true)
            : statusPill(text: "Idle", filled: false)
        card.content.addSubview(pill)
        if item.isActive {
            activeDetailViews.append(pill)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: card.content.topAnchor, constant: 10),
            detail.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            detail.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -8),
            pill.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 14),
            pill.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -10),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 1)
        ])
        return card
    }
    private func statusPill(text: String, filled: Bool) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = filled ? NSColor.controlAccentColor : .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 999
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = (filled ? NSColor.controlAccentColor.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.10)).cgColor
        pill.layer?.backgroundColor = (filled ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.03)).cgColor
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 16),
            pill.heightAnchor.constraint(equalToConstant: 18)
        ])
        return pill
    }
    private func workspaceNumberChip(for item: WorkspaceOverviewItem) -> NSView {
        let number = NSTextField(labelWithString: "\(item.index + 1)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        number.alignment = .center
        number.translatesAutoresizingMaskIntoConstraints = false
        number.textColor = item.isActive ? .white : .secondaryLabelColor
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.backgroundColor = (item.isActive ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.07)).cgColor
        if item.isActive {
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
        chip.addSubview(number)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 34),
            chip.heightAnchor.constraint(equalToConstant: 24),
            number.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
        number.sizeToFit()
        return chip
    }
    private func emptyStateView() -> NSView {
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: "rectangle.on.rectangle.slash", accessibilityDescription: nil) {
            glyph.image = image
        }
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        glyph.contentTintColor = NSColor.tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        let text = label(
            "No tiled windows",
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .tertiaryLabelColor
        )
        let row = NSStackView(views: [glyph, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 15),
            glyph.heightAnchor.constraint(equalToConstant: 15)
        ])
        return row
    }
    private func miniMap(for item: WorkspaceOverviewItem) -> NSView {
        var rects: [CGRect] = []
        var icons: [NSImage] = []
        var focusedIndex = -1
        for window in item.windows {
            guard let frame = window.frame else { continue }
            rects.append(frame)
            icons.append(AppIconProvider.appIcon(for: window.pid))
            if window.isFocused && focusedIndex == -1 {
                focusedIndex = rects.count - 1
            }
        }
        var titles: [String] = []
        for window in item.windows {
            guard window.frame != nil else { continue }
            titles.append(window.title.isEmpty ? "Untitled window" : window.title)
        }
        let map = WorkspaceMiniMapView(
            rects: rects,
            icons: icons,
            titles: titles,
            boundsFrame: item.screenFrame,
            focusedIndex: focusedIndex
        )
        map.translatesAutoresizingMaskIntoConstraints = false
        if rects.isEmpty {
            map.isHidden = true
        }
        return map
    }
    func beginRenaming(text: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard let activeRenameField else { return }
        workspaceCards.forEach { $0.setRenaming(true) }
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
        workspaceCards.forEach { $0.setRenaming(false) }
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
    private func renameTextField() -> NSTextField {
        let field = NSTextField(string: "")
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .textColor
        field.placeholderAttributedString = NSAttributedString(
            string: "Workspace name",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        field.layer?.masksToBounds = true
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return field
    }
private final class WorkspaceMiniMapView: NSView {
    private let rects: [CGRect]
    private let icons: [NSImage]
    private let titles: [String]
    private let boundsFrame: CGRect
    private let focusedIndex: Int
    init(rects: [CGRect], icons: [NSImage], titles: [String], boundsFrame: CGRect, focusedIndex: Int) {
        self.rects = rects
        self.icons = icons
        self.titles = titles
        self.boundsFrame = boundsFrame
        self.focusedIndex = focusedIndex
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Window layout")
        setAccessibilityValue(titles.joined(separator: ", "))
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 144, height: 90)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.04).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard !rects.isEmpty, boundsFrame.width > 0, boundsFrame.height > 0 else { return }
        let contentInset: CGFloat = 7
        let contentRect = bounds.insetBy(dx: contentInset, dy: contentInset)
        let scaleX = contentRect.width / boundsFrame.width
        let scaleY = contentRect.height / boundsFrame.height
        let windowInset: CGFloat = rects.count > 1 ? 1 : 0
        for (i, rect) in rects.enumerated() {
            let r = NSRect(
                x: contentRect.minX + (rect.minX - boundsFrame.minX) * scaleX,
                y: contentRect.minY + contentRect.height - (rect.maxY - boundsFrame.minY) * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            ).insetBy(dx: windowInset, dy: windowInset)
            let isFocused = i == focusedIndex
            let rounded = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            Self.palette[i % Self.palette.count].withAlphaComponent(isFocused ? 0.42 : 0.30).setFill()
            rounded.fill()
            NSColor.white.withAlphaComponent(isFocused ? 0.22 : 0.10).setStroke()
            rounded.lineWidth = 1
            rounded.stroke()
            if i < icons.count, icons[i].isValid {
                let side = min(r.width, r.height) * 0.55
                if side >= 8 {
                    let iconRect = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
                    icons[i].draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.44, green: 0.56, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.44, green: 0.66, blue: 0.64, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.66, blue: 0.50, alpha: 1),
        NSColor(calibratedRed: 0.72, green: 0.62, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.66, green: 0.50, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.54, blue: 0.72, alpha: 1)
    ]
}

private final class AppIconProvider {
    private static let iconCache = NSCache<NSString, NSImage>()

    static func appIcon(for pid: pid_t) -> NSImage {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let key = NSString(string: runningApp?.bundleIdentifier.map { "bundle-\($0)" } ?? "pid-\(pid)")
        if let cached = iconCache.object(forKey: key) { return cached }
        var image = NSWorkspace.shared.icon(forFile: runningApp?.bundleURL?.path ?? "")
        if let bundleID = runningApp?.bundleIdentifier {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        iconCache.setObject(image, forKey: key)
        return image
    }
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
