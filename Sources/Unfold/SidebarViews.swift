import AppKit
import QuartzCore

enum SidebarMetrics {
    static var rowHeight: CGFloat { InterfaceStyle.isBreathe ? Breathe.sidebarRowHeight : 30 }
}

/// Navigation and its contents share the same rounded outline.
@MainActor
final class SidebarSurface: WorkspaceSurface {
    static let inset: CGFloat = 4
    static let radius: CGFloat = 18

    override init(fill: NSColor = FeedPalette.sidebar) {
        super.init(fill: fill)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.04)).cgColor
        layer?.borderWidth = 1
    }
}

/// Draw inside the canvas so NSSplitView cannot clip the rail's drop shadow.
/// This decoration never takes clicks, divider drags, or scroll-wheel events.
@MainActor
final class SidebarEdgeShadow: NSView {
    var scrollOffset: CGFloat = 0 { didSet { if scrollOffset != oldValue { updateVisibility() } } }
    var isSuppressed = false { didSet { if isSuppressed != oldValue { updateVisibility() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private func updateVisibility() {
        isHidden = isSuppressed || scrollOffset <= 0.5
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isSuppressed, scrollOffset > 0.5,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let strength = min(1, max(0, (scrollOffset - 0.5) / 24))
        context.saveGState()
        context.clip(to: bounds)
        context.setShadow(offset: CGSize(width: 2, height: 0), blur: 8,
                          color: NSColor.black.withAlphaComponent(strength * (dark ? 0.10 : 0.05)).cgColor)
        // The casting surface lies outside this view. Only its soft shadow is
        // painted over the chats, with the same rounded corners as the rail.
        let inset = SidebarSurface.inset
        let caster = CGRect(x: -100, y: inset, width: 100 - inset, height: max(0, bounds.height - 2 * inset))
        context.addPath(CGPath(roundedRect: caster, cornerWidth: SidebarSurface.radius, cornerHeight: SidebarSurface.radius, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}

/// Breathe separates the sidebar with space while keeping the divider draggable.
@MainActor
final class WorkspaceSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        guard InterfaceStyle.isBreathe else { super.drawDivider(in: rect); return }
        FeedPalette.backdrop.setFill()
        rect.fill()
    }
}

@MainActor
final class SidebarSplitView: NSSplitView, NSSplitViewDelegate {
    var chatFraction: CGFloat = 2.0 / 3.0
    /// Room for the project heading, two project rows and the model controls.
    static let projectMinimum: CGFloat = 244
    private var projectMinimum: CGFloat { Self.projectMinimum }
    var minimumChatHeight: CGFloat = 160
    var onResize: (() -> Void)?
    private var arranging = false
    private var hoverArea: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        setAccessibilityLabel("Chats, Projects, and Models")
        setAccessibilityHelp("Drag the grip above Projects to resize the chat and project lists.")
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override var dividerThickness: CGFloat { 20 }

    private var dividerRect: NSRect {
        guard subviews.count == 2 else { return .zero }
        return NSRect(x: bounds.minX, y: min(subviews[0].frame.maxY, subviews[1].frame.maxY),
                      width: bounds.width, height: dividerThickness)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: dividerRect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); hoverArea = area
        hovering = window.map { dividerRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        dragging = dividerRect.contains(convert(event.locationInWindow, from: nil))
        defer { dragging = false; updateTrackingAreas() }
        super.mouseDown(with: event)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        // The resize grip sits above the independently left-aligned folder heading.
        (hovering || dragging ? FeedPalette.text : FeedPalette.muted).setFill()
        for offset: CGFloat in [-2, 2] {
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 14, y: rect.midY + offset - 0.5,
                                           width: 28, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        arranging = true
        super.resizeSubviews(withOldSize: oldSize)
        let available = max(0, bounds.height - dividerThickness)
        setPosition(min(max(available * chatFraction, minimumChatHeight), max(minimumChatHeight, available - projectMinimum)), ofDividerAt: 0)
        arranging = false
        // NSSplitView clips its panes. The search field spans the chat pane's
        // full width, so its focus ring would be cropped at both ends.
        subviews.first?.clipsToBounds = false
        updateTrackingAreas()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimumChatHeight }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(minimumChatHeight, bounds.height - dividerThickness - projectMinimum)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position, ofDividerAt: dividerIndex)
        if !arranging { rememberDividerPosition() }
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        updateTrackingAreas()
        // Auto Layout can deliver a second resize after resizeSubviews returns.
        // Only a deliberate divider move should replace the saved proportion.
        if dragging { rememberDividerPosition() }
    }
    private func rememberDividerPosition() {
        guard !arranging, let chats = subviews.first, bounds.height > dividerThickness else { return }
        chatFraction = chats.frame.height / (bounds.height - dividerThickness)
        onResize?()
    }
}

@MainActor
final class SidebarActionButton: NSButton {
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || hovering {
            FeedPalette.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let iconRect = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        // Symbol images are templates: tint them so they follow dark mode.
        let tint: NSColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        (image?.withSymbolConfiguration(.init(paletteColors: [tint])) ?? image)?.draw(in: iconRect)
        let attributes: [NSAttributedString.Key: Any] = [.font: InterfaceTypography.font(Typography.interface), .foregroundColor: isEnabled ? FeedPalette.text : FeedPalette.muted]
        let label = NSAttributedString(string: title, attributes: attributes)
        label.draw(at: NSPoint(x: 30, y: (bounds.height - label.size().height) / 2))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2; outline.stroke()
        }
    }
}

@MainActor
final class SidebarProjectRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        FeedPalette.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
final class SidebarProjectCell: NSTableCellView {
    init(name: String, chatCount: Int, runningCount: Int, path: String, expanded: Bool = false, onToggleHistory: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
        icon.contentTintColor = runningCount > 0 ? .controlAccentColor : .secondaryLabelColor
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = Typography.interface
        nameLabel.textColor = FeedPalette.text
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let detail = "\(chatCount) \(chatCount == 1 ? "chat" : "chats")" + (runningCount > 0 ? " · \(runningCount) working" : "")
        let detailLabel = NSTextField(labelWithString: "\(chatCount)")
        detailLabel.font = Typography.counter
        detailLabel.textColor = FeedPalette.muted
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setAccessibilityLabel(detail)
        textField = nameLabel; toolTip = "\(path)\n\(detail)"
        let disclosure = onToggleHistory.map { ProjectHistoryDisclosureButton(name: name, expanded: expanded, onToggle: $0) }
        if let disclosure {
            disclosure.translatesAutoresizingMaskIntoConstraints = false; addSubview(disclosure)
            NSLayoutConstraint.activate([
                disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
                disclosure.widthAnchor.constraint(equalToConstant: 24),
                disclosure.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
        for child in [icon, nameLabel, detailLabel] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: disclosure?.leadingAnchor ?? trailingAnchor, constant: disclosure == nil ? -12 : -2),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); InterfaceTypography.apply(to: self) }
}


@MainActor
final class SidebarConversationCell: NSTableCellView {
    init(title: String, project: String, isRunning: Bool, isEmpty: Bool = false) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = isRunning ? Typography.interfaceEmphasis : Typography.interface
        titleLabel.textColor = isEmpty ? FeedPalette.muted : FeedPalette.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel(title + ", " + project + (isRunning ? ", Working" : ""))
        textField = titleLabel
        toolTip = title + "\n" + project + (isRunning ? " · Working" : "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if isRunning {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .small
            spinner.startAnimation(nil); spinner.setAccessibilityLabel("Working")
            spinner.translatesAutoresizingMaskIntoConstraints = false; addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6)
            ])
        } else {
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); InterfaceTypography.apply(to: self) }
}
