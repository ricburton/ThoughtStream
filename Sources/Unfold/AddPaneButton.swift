import AppKit

/// A single native button with a decorative keyboard-shortcut badge.
@MainActor
final class AddPaneButton: NSButton {
    private var hovering = false
    private var hoverArea: NSTrackingArea?

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
        (pressed ? FeedPalette.selection : isEnabled && hovering ? FeedPalette.hover : FeedPalette.surface).setFill()
        shape.fill()
        FeedPalette.line.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let ink = isEnabled ? FeedPalette.text : NSColor.disabledControlTextColor
        let icon = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [ink]))
        icon?.draw(in: NSRect(x: 11, y: (bounds.height - 12) / 2, width: 12, height: 12))
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ink
        ])
        label.draw(at: NSPoint(x: 29, y: (bounds.height - label.size().height) / 2))

        let badgeRect = NSRect(x: bounds.width - 42, y: (bounds.height - 18) / 2, width: 33, height: 18)
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        FeedPalette.backdrop.setFill()
        badge.fill()
        FeedPalette.line.setStroke()
        badge.lineWidth = 0.5
        badge.stroke()
        let shortcut = NSAttributedString(string: "⌘P", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isEnabled ? FeedPalette.muted : NSColor.disabledControlTextColor
        ])
        shortcut.draw(at: NSPoint(x: badgeRect.midX - shortcut.size().width / 2,
                                  y: badgeRect.midY - shortcut.size().height / 2))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}
