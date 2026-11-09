import AppKit

/// How much of a chat pane the readable conversation occupies. Dragging the
/// divider in any pane updates that pane and becomes the default for new ones.
enum ConversationSplit {
    static let defaultFraction: CGFloat = 0.25
    static let minimumFraction: CGFloat = 0.04
    static let maximumFraction: CGFloat = 0.85
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

/// A thin, full-width grab strip over the divider between the activity stream
/// and the conversation. Drag up to see more conversation, down to see less;
/// double-click restores the default split.
@MainActor
final class ConversationResizeHandle: NSView {
    static let thickness: CGFloat = 16
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
        toolTip = "Drag to resize the conversation · double-click to reset"
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
        let pill = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 27, y: bounds.midY - 6, width: 54, height: 12),
                                xRadius: 6, yRadius: 6)
        FeedPalette.input.setFill(); pill.fill()
        (active ? NSColor.secondaryLabelColor : FeedPalette.line).setStroke()
        pill.lineWidth = 1; pill.stroke()
        NSColor.secondaryLabelColor.withAlphaComponent(active ? 1 : 0.75).setFill()
        for offset: CGFloat in [-2, 2] {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: bounds.midY + offset - 0.75, width: 24, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}
