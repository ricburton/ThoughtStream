import AppKit

/// Keep full labels visible and navigation pairs together as the toolbar wraps.
/// Buttons are sectioned by purpose; a wider gap separates one section from the next.
@MainActor
final class WorkspaceHeaderRow: NSView {
    static let spacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 18
    private let groups: [[NSView]]
    private var sectionIndex: [ObjectIdentifier: Int] = [:]
    private var rowHeight: NSLayoutConstraint!
    private let buttonHeight: CGFloat = 28
    private let spacing = WorkspaceHeaderRow.spacing

    /// Each section lists groups; a group wraps as a unit.
    init(sections: [[[NSView]]]) {
        groups = sections.flatMap { $0 }
        super.init(frame: .zero)
        for (index, section) in sections.enumerated() {
            for button in section.flatMap({ $0 }) {
                sectionIndex[ObjectIdentifier(button)] = index
                addSubview(button)
            }
        }
        rowHeight = heightAnchor.constraint(equalToConstant: 30)
        rowHeight.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        func buttonWidth(_ button: NSView) -> CGFloat {
            ceil(button.intrinsicContentSize.width)
        }
        func gap(_ leading: NSView, _ trailing: NSView) -> CGFloat {
            sectionIndex[ObjectIdentifier(leading)] == sectionIndex[ObjectIdentifier(trailing)]
                ? spacing : WorkspaceHeaderRow.sectionSpacing
        }
        func width(for buttons: [NSView]) -> CGFloat {
            zip(buttons, buttons.dropFirst()).reduce(buttons.reduce(0) { $0 + buttonWidth($1) }) { $0 + gap($1.0, $1.1) }
        }
        var rows: [[NSView]] = []
        var row: [NSView] = []
        for group in groups {
            // A pair stays together unless the viewport cannot hold the pair.
            let chunks = width(for: group) > bounds.width ? group.map { [$0] } : [group]
            for chunk in chunks {
                if !row.isEmpty && width(for: row + chunk) > bounds.width {
                    rows.append(row); row = []
                }
                row += chunk
            }
        }
        if !row.isEmpty { rows.append(row) }
        let height: CGFloat = rows.count <= 1 ? 30 : CGFloat(rows.count) * (buttonHeight + spacing) - spacing
        if rowHeight.constant != height { rowHeight.constant = height }
        func place(_ buttons: [NSView], y: CGFloat) {
            var x = bounds.width - width(for: buttons)
            for (index, button) in buttons.enumerated() {
                let width = buttonWidth(button)
                button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
                x += width + (index + 1 < buttons.count ? gap(button, buttons[index + 1]) : 0)
            }
        }
        for (index, row) in rows.enumerated() {
            place(row, y: rows.count == 1 ? 1 : height - buttonHeight - CGFloat(index) * (buttonHeight + spacing))
        }
    }
}

/// A single native button with a decorative keyboard-shortcut badge.
@MainActor
final class AddPaneButton: NSButton {
    override var title: String { didSet { invalidateContentLayout() } }
    var sizingTitles: [String] = [] { didSet { invalidateContentLayout() } }
    var shortcutTitle = "⌘P" { didSet { invalidateContentLayout() } }
    var symbolName = "plus" { didSet { needsDisplay = true } }
    var isIconOnly = false { didSet { invalidateContentLayout() } }
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private let horizontalPadding: CGFloat = 10
    private let iconSize: CGFloat = 12
    private let iconLabelSpacing: CGFloat = 6
    private let labelShortcutSpacing: CGFloat = 8
    private var labelFont: NSFont { Typography.prose(ofSize: 12, weight: .medium) }
    private var shortcutFont: NSFont { InterfaceTypography.font(NSFont.systemFont(ofSize: 11, weight: .medium)) }
    private var labelWidth: CGFloat {
        ([title] + sizingTitles).map { ceil(($0 as NSString).size(withAttributes: [.font: labelFont]).width) }.max() ?? 0
    }
    private var badgeWidth: CGFloat {
        max(24, ceil((shortcutTitle as NSString).size(withAttributes: [.font: shortcutFont]).width) + 10)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: isIconOnly ? 34 : horizontalPadding * 2 + iconSize + iconLabelSpacing
               + labelWidth + (shortcutTitle.isEmpty ? 0 : labelShortcutSpacing + badgeWidth), height: 28)
    }

    private func invalidateContentLayout() {
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let pressed = isEnabled && isHighlighted
        (pressed || state == .on ? FeedPalette.selection : isEnabled && hovering ? FeedPalette.hover : FeedPalette.surface).setFill()
        shape.fill()
        FeedPalette.line.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let ink = isEnabled ? FeedPalette.text : (InterfaceStyle.isMatrix ? FeedPalette.muted : NSColor.disabledControlTextColor)
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [ink]))
        let iconSize: CGFloat = isIconOnly ? 14 : self.iconSize
        let iconRect = NSRect(x: isIconOnly ? (bounds.width - iconSize) / 2 : horizontalPadding,
                              y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        icon?.draw(in: iconRect)
        if !isIconOnly {
            let label = NSAttributedString(string: title, attributes: [
                .font: labelFont, .foregroundColor: ink
            ])
            let labelX = horizontalPadding + iconSize + iconLabelSpacing
            label.draw(at: NSPoint(x: labelX, y: (bounds.height - label.size().height) / 2))

            if !shortcutTitle.isEmpty {
                // A button stretched to match its neighbours keeps the badge at its trailing edge.
                let badgeX = max(labelX + labelWidth + labelShortcutSpacing, bounds.width - horizontalPadding - badgeWidth)
                let badgeRect = NSRect(x: badgeX, y: (bounds.height - 18) / 2, width: badgeWidth, height: 18)
                let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
                FeedPalette.backdrop.setFill()
                badge.fill()
                FeedPalette.line.setStroke()
                badge.lineWidth = 0.5
                badge.stroke()
                let shortcut = NSAttributedString(string: shortcutTitle, attributes: [
                    .font: shortcutFont,
                    .foregroundColor: isEnabled ? FeedPalette.muted : (InterfaceStyle.isMatrix ? FeedPalette.muted : NSColor.disabledControlTextColor)
                ])
                shortcut.draw(at: NSPoint(x: badgeRect.midX - shortcut.size().width / 2,
                                          y: badgeRect.midY - shortcut.size().height / 2))
            }
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}
