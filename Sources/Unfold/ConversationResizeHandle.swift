import AppKit

/// How much of a chat pane the readable conversation occupies. Dragging the
/// divider in any pane updates that pane and becomes the default for new ones.
enum ConversationSplit {
    static let defaultFraction: CGFloat = 0.25
    static let minimumFraction: CGFloat = 0.04
    // The endpoint means logs are fully collapsed, including after a resize.
    static let maximumFraction: CGFloat = 1
    static let minimumHeight: CGFloat = 56
    static let minimumStreamHeight: CGFloat = 80
    static let defaultsKey = "conversationPaneFraction"

    static func clamp(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite else { return defaultFraction }
        return min(maximumFraction, max(minimumFraction, fraction))
    }

    static func stored(in defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = defaults.object(forKey: defaultsKey) as? Double else { return defaultFraction }
        return clamp(CGFloat(value))
    }

    static func store(_ fraction: CGFloat, in defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(fraction)), forKey: defaultsKey)
    }
}

/// A full-width grab strip over the divider between the activity stream
/// and the conversation. Drag up to see more conversation, down to see less;
/// double-click restores the default split.
@MainActor
final class ConversationResizeHandle: NSView {
    static let thickness: CGFloat = 22
    var onBegin: (() -> Void)?
    /// Vertical distance moved since the drag began, in points; upward is positive.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var startY: CGFloat?
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize conversation")
        toolTip = "Drag up to hide logs, down to reveal them · double-click to reset"
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if startY == nil { hovering = false } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { startY = nil; onReset?(); return }
        startY = event.locationInWindow.y
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        onDrag?(event.locationInWindow.y - startY)
    }
    override func mouseUp(with event: NSEvent) {
        guard startY != nil else { return }
        startY = nil
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovering || startY != nil
        if InterfaceStyle.isBreathe {
            // A substantial grip with a little lift, firmer under the pointer.
            FeedPalette.canvas.setFill()
            NSRect(x: bounds.midX - 26, y: bounds.midY - 5, width: 52, height: 10).fill()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(active ? 0.18 : 0.12)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            FeedPalette.muted.withAlphaComponent(active ? 0.85 : 0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 19, y: bounds.midY - 3.5, width: 38, height: 7),
                         xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let pill = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 27, y: bounds.midY - 7, width: 54, height: 14),
                                xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(active ? 0.18 : 0.12)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        FeedPalette.input.setFill(); pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        (active ? NSColor.secondaryLabelColor : FeedPalette.line).setStroke()
        pill.lineWidth = 1; pill.stroke()
        NSColor.secondaryLabelColor.withAlphaComponent(active ? 1 : 0.75).setFill()
        for offset: CGFloat in [-2, 2] {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: bounds.midY + offset - 0.75, width: 24, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}
