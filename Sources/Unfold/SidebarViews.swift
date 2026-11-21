import AppKit

enum SidebarMetrics {
    static var rowHeight: CGFloat { InterfaceStyle.isBreathe ? Breathe.sidebarRowHeight : 30 }
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
        setAccessibilityLabel("Chats and projects")
        setAccessibilityHelp("Drag the Projects tab up or down to resize the projects list.")
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override var dividerThickness: CGFloat { 36 }

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
        let label = NSAttributedString(string: "Projects", attributes: [
            .font: Typography.interfaceEmphasis, .foregroundColor: FeedPalette.text
        ])
        let tab = NSRect(x: rect.minX + 8, y: rect.minY,
                         width: min(ceil(label.size().width) + 54, max(0, rect.width - 16)), height: rect.height)
        ChatChrome.drawSelectedTab(in: tab, flipped: isFlipped)
        if hovering || dragging {
            let radius = InterfaceStyle.isBreathe ? Breathe.tabRadius : ChatChrome.tabRadius
            FeedPalette.text.withAlphaComponent(dragging ? 0.09 : 0.045).setFill()
            NSBezierPath(roundedRect: tab.insetBy(dx: 0.5, dy: InterfaceStyle.isBreathe ? 4 : 2),
                         xRadius: radius, yRadius: radius).fill()
        }
        label.draw(at: NSPoint(x: tab.minX + 12, y: tab.midY - label.size().height / 2))
        // Keep a visible resize cue even when the pointer is elsewhere.
        (hovering || dragging ? FeedPalette.text : FeedPalette.muted).setFill()
        for offset: CGFloat in [-2, 2] {
            NSBezierPath(roundedRect: NSRect(x: tab.maxX - 26, y: tab.midY + offset - 0.5,
                                           width: 14, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        arranging = true
        super.resizeSubviews(withOldSize: oldSize)
        let available = max(0, bounds.height - dividerThickness)
        setPosition(min(max(available * chatFraction, 100), max(100, available - 80)), ofDividerAt: 0)
        arranging = false
        updateTrackingAreas()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 100 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(100, bounds.height - dividerThickness - 80)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        updateTrackingAreas()
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
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography.interface, .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor]
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
}
