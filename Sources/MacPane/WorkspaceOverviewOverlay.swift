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
    private var panel: OverlayPanel?
    private var onDismiss: (() -> Void)?
    private(set) var overview: WorkspaceOverview?
    private var clickOutsideMonitor: Any?
    private var clickInsideMonitor: Any?
    private var dismissalObservers: [NSObjectProtocol] = []
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
        panel.presentWithSpringFade(frame: frame)
        installDismissalMonitors()
    }
    /// Takes window titles that were read after the overview opened. Only VoiceOver reads them, so
    /// nothing on screen changes and the overview is not shown again.
    func updateWindowTitles(from overview: WorkspaceOverview) {
        guard let shown = self.overview, shown.displayID == overview.displayID else { return }
        overviewView?.updateWindowTitles(from: overview)
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
        removeDismissalMonitors()
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
    /// While the overview is up its bare number, R and Escape keys are global shortcuts. It has to
    /// close as soon as attention goes anywhere else, or those keys stay taken from every app.
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
        panel.ignoresMouseEvents = true
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

private final class WorkspaceOverviewView: NSVisualEffectView, NSTextFieldDelegate {
    private let overview: WorkspaceOverview
    private let cardHeight: CGFloat
    private let onWorkspaceSelected: (Int) -> Void
    private weak var activeHeaderLabel: NSTextField?
    private weak var activeRenameField: NSTextField?
    private var activeDetailViews: [NSView] = []
    private var onRenameCommit: ((String) -> Void)?
    private var onRenameCancel: (() -> Void)?
    private var workspaceCards: [OverlayCardView] = []
    private var miniMaps: [Int: WorkspaceMiniMapView] = [:]
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
        OverlayControls.configureContainer(self)
        let root = OverlayControls.makeContentRoot(in: self, topInset: 22, bottomInset: 16, spacing: 18)
        root.addArrangedSubview(OverlayControls.headerRow(
            title: "Workspaces",
            titleSize: 20,
            subtitle: "\(overview.displayName) · Workspace \(overview.activeWorkspaceIndex + 1) of \(overview.workspaceCount)"
        ))
        let grid = OverlayControls.cardsGrid(itemCount: overview.items.count) { index in
            card(for: overview.items[index])
        }
        root.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(OverlayControls.hintPillsRow([
            OverlayControls.hintPill(key: "1–9", text: "Switch"),
            OverlayControls.hintPill(key: "R", text: "Rename"),
            OverlayControls.hintPill(key: "esc", text: "Close")
        ]))
    }
    private func card(for item: WorkspaceOverviewItem) -> OverlayCardView {
        let card = OverlayCardView(
            accessibilityLabel: workspaceTitle(for: item),
            accessibilityValue: item.isActive ? "Current workspace" : nil,
            isProminent: item.isActive,
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
        let chip = OverlayControls.numberChip(number: item.index + 1, isProminent: item.isActive)
        top.addArrangedSubview(chip)
        let header = OverlayControls.label(
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
            ? OverlayControls.statusPill(text: "Current", filled: true)
            : OverlayControls.statusPill(text: "Idle", filled: false)
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
    private func emptyStateView() -> NSView {
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: "rectangle.on.rectangle.slash", accessibilityDescription: nil) {
            glyph.image = image
        }
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        glyph.contentTintColor = NSColor.tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        let text = OverlayControls.label(
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
        let map = WorkspaceMiniMapView(
            rects: rects,
            icons: icons,
            titles: Self.windowTitles(of: item),
            boundsFrame: item.screenFrame,
            focusedIndex: focusedIndex
        )
        map.translatesAutoresizingMaskIntoConstraints = false
        if rects.isEmpty {
            map.isHidden = true
        }
        miniMaps[item.index] = map
        return map
    }
    private static func windowTitles(of item: WorkspaceOverviewItem) -> [String] {
        item.windows.compactMap { window in
            guard window.frame != nil else { return nil }
            return window.title.isEmpty ? "Untitled window" : window.title
        }
    }
    func updateWindowTitles(from overview: WorkspaceOverview) {
        for item in overview.items {
            miniMaps[item.index]?.setTitles(Self.windowTitles(of: item))
        }
    }
    func beginRenaming(text: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard let activeRenameField else { return }
        workspaceCards.forEach { $0.setInteractionSuspended(true) }
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
        workspaceCards.forEach { $0.setInteractionSuspended(false) }
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
    private let boundsFrame: CGRect
    private let focusedIndex: Int
    init(rects: [CGRect], icons: [NSImage], titles: [String], boundsFrame: CGRect, focusedIndex: Int) {
        self.rects = rects
        self.icons = icons
        self.boundsFrame = boundsFrame
        self.focusedIndex = focusedIndex
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Window layout")
        setTitles(titles)
    }
    /// The titles are what VoiceOver reads for the map; none of them is drawn.
    func setTitles(_ titles: [String]) {
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

private enum AppIconProvider {
    static func appIcon(for pid: pid_t) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }
}
}
