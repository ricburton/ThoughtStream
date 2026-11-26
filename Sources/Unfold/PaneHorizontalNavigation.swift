import AppKit

/// A slim scrollbar outside the panes, leaving composers and resize handles clear.
@MainActor
final class PaneHorizontalNavigation: NSView {
    static let height: CGFloat = 12
    let scroller: NSScroller = PanePositionScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 11))

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.isContinuous = true
        scroller.setAccessibilityLabel("Horizontal chat position")
        scroller.toolTip = "Drag to scroll chats left or right. You can also swipe sideways or Shift-scroll."
        addSubview(scroller)
    }

    required init?(coder: NSCoder) { fatalError("Not implemented") }

    func update(visible: NSRect, contentWidth: CGFloat) {
        let range = max(0, contentWidth - visible.width)
        scroller.isEnabled = range > 0.5
        scroller.knobProportion = contentWidth > 0 ? min(1, visible.width / contentWidth) : 1
        scroller.doubleValue = range > 0 ? Double(min(1, max(0, visible.minX / range))) : 0
        scroller.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let thickness = NSScroller.scrollerWidth(for: scroller.controlSize, scrollerStyle: .legacy)
        scroller.frame = NSRect(x: 4, y: (bounds.height - thickness) / 2,
                                width: max(0, bounds.width - 8), height: thickness)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Use native thumb geometry, tracking and accessibility, but paint the track
/// explicitly so the system's auto-hiding scrollbar preference cannot hide it.
@MainActor
private final class PanePositionScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 3, dy: max(0, (bounds.height - 2) / 2))
        let trackColor = NSColor.quaternaryLabelColor
        trackColor.withAlphaComponent(trackColor.alphaComponent * 0.5).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        guard isEnabled else { return }
        let nativeKnob = rect(for: .knob)
        let knob = nativeKnob.insetBy(dx: 0, dy: max(0, (nativeKnob.height - 3) / 2))
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
