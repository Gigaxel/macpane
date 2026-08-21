import AppKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func make() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        return panel
    }

    func presentWithSpringFade(frame: CGRect) {
        let startFrame = CGRect(
            x: frame.midX - frame.width * 0.94 / 2,
            y: frame.midY - frame.height * 0.94 / 2,
            width: frame.width * 0.94,
            height: frame.height * 0.94
        )
        setFrame(startFrame, display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(frame, display: true)
        }
    }
}

final class OverlayGlassBackgroundView: NSView {
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

final class OverlayCardView: NSView {
    private let onSelect: () -> Void
    private let isProminent: Bool
    private var isHovered = false
    private var isPressed = false
    private var isInteractionSuspended = false
    private var trackingArea: NSTrackingArea?
    private let glassLayer = CALayer()
    private let strokeLayer = CALayer()
    let content: NSView

    init(
        accessibilityLabel: String,
        accessibilityValue: String?,
        isProminent: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.isProminent = isProminent
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
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(accessibilityValue)
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
        addCursorRect(bounds, cursor: isInteractionSuspended ? .arrow : .pointingHand)
    }
    func setInteractionSuspended(_ suspended: Bool) {
        isInteractionSuspended = suspended
        setAccessibilityEnabled(!suspended)
        updateStyle()
        window?.invalidateCursorRects(for: self)
    }
    override func accessibilityPerformPress() -> Bool {
        guard !isInteractionSuspended else { return false }
        select()
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        if isInteractionSuspended {
            return super.hitTest(point)
        }
        return self
    }
    private func updateStyle() {
        let hover = isHovered && !isInteractionSuspended
        let pressed = isPressed && !isInteractionSuspended
        let borderColor: NSColor
        let borderWidth: CGFloat
        let shadowColor: NSColor?
        let shadowOpacity: CGFloat
        let shadowBlur: CGFloat
        if isProminent {
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
        glassLayer.backgroundColor = NSColor.white.withAlphaComponent(isProminent ? 0.10 : 0.055).cgColor
    }
    private func select() {
        guard !isInteractionSuspended else { return }
        onSelect()
    }
}

enum OverlayControls {
    static func configureContainer(_ view: NSVisualEffectView) {
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view.layer?.borderWidth = 1
        let glass = OverlayGlassBackgroundView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    static func makeContentRoot(
        in container: NSVisualEffectView,
        topInset: CGFloat,
        bottomInset: CGFloat,
        spacing: CGFloat
    ) -> NSStackView {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = spacing
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            contentView.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomInset),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        return root
    }
    static func headerRow(title: String, titleSize: CGFloat, subtitle: String) -> NSView {
        let titleLabel = label(title, font: .systemFont(ofSize: titleSize, weight: .bold), color: .labelColor)
        let subtitleLabel = label(subtitle, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        let titleColumn = NSStackView(views: [titleLabel, subtitleLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 3
        let headerRow = NSStackView(views: [titleColumn, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12
        headerRow.distribution = .fill
        return headerRow
    }
    static func cardsGrid(itemCount: Int, makeCard: (Int) -> NSView) -> NSStackView {
        let columns = min(3, max(1, itemCount))
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .width
        grid.spacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < itemCount {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            row.translatesAutoresizingMaskIntoConstraints = false
            for _ in 0..<columns {
                if index < itemCount {
                    row.addArrangedSubview(makeCard(index))
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
    static func hintPill(key: String, text: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        let textLabel = label(text, font: .systemFont(ofSize: 11, weight: .medium), color: .tertiaryLabelColor)
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
    static func hintPillsRow(_ pills: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        pills.forEach { stack.addArrangedSubview($0) }
        return stack
    }
    static func statusPill(text: String, filled: Bool) -> NSView {
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
    static func numberChip(number: Int, isProminent: Bool) -> NSView {
        let numberLabel = NSTextField(labelWithString: "\(number)")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.textColor = isProminent ? .white : .secondaryLabelColor
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.backgroundColor = (isProminent ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.07)).cgColor
        if isProminent {
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
        chip.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 34),
            chip.heightAnchor.constraint(equalToConstant: 24),
            numberLabel.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
        numberLabel.sizeToFit()
        return chip
    }
    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
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
