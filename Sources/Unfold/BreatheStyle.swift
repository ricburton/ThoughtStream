import AppKit
import QuartzCore

/// Breathe keeps the standard palette and takes chrome away. Each pane has one
/// row of tabs that share its width, its buttons live in a single menu, and
/// live following is implied: scroll up to read, come back down (or use the
/// Latest pill) to follow again. Panes are cards that spring open and closed.
enum Breathe {
    static let tabTopInset: CGFloat = 12
    static let tabSpacing: CGFloat = 6
    static let tabRadius: CGFloat = 9
    static let tabMinimum: CGFloat = 76
    static let tabMaximum: CGFloat = 220
    static let statusHeight: CGFloat = 28
    static let composerBottom: CGFloat = 16
    static let sidebarRowHeight: CGFloat = 34

    @MainActor private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Long titles give way first, so short ones stay whole. The strip only
    /// scrolls once every tab is down to its minimum.
    static func tabWidths(_ natural: [CGFloat], available: CGFloat, spacing: CGFloat,
                                      minimum: CGFloat = 76, minimums: [CGFloat]? = nil) -> [CGFloat] {
        let floors = natural.indices.map { index in
            minimums.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? minimum
        }
        let room = available - spacing * CGFloat(max(0, natural.count - 1))
        guard room > 0, natural.reduce(0, +) > room else { return natural }
        var low: CGFloat = 0, high = max(minimum, natural.max() ?? minimum)
        for _ in 0..<24 {
            let cap = (low + high) / 2
            if zip(natural, floors).reduce(0, { $0 + max($1.1, min($1.0, cap)) }) > room { high = cap } else { low = cap }
        }
        return zip(natural, floors).map { max($0.1, min($0.0, low).rounded(.down)) }
    }

    /// The selected tab's frame inside the strip, without waiting for layout.
    static func tabFrame(at index: Int, widths: [CGFloat], spacing: CGFloat, height: CGFloat) -> NSRect {
        guard widths.indices.contains(index) else { return .zero }
        let x = widths.prefix(index).reduce(0, +) + spacing * CGFloat(index)
        return NSRect(x: x, y: 0, width: widths[index], height: height)
    }

    /// A quiet lift beneath a pane card. Drawn by the pane's host, because the
    /// card itself clips its contents to its rounded corners.
    @MainActor static func drawPaneShadow(around card: NSRect) {
        guard card.width > 0, card.height > 0, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.32 : 0.09)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        FeedPalette.canvas.setFill()
        NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: PaneSurface.radius, yRadius: PaneSurface.radius).fill()
    }

    @MainActor private static func scale(_ value: CGFloat, aboutCenterOf layer: CALayer) -> CATransform3D {
        // AppKit anchors view layers at a corner; scale about the middle instead.
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, value, value, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }

    /// A new pane springs open like a small window instead of appearing in place.
    @MainActor static func popOpen(_ pane: NSView) {
        guard InterfaceStyle.isBreathe, !reducesMotion, pane.window != nil, let layer = pane.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: scale(0.94, aboutCenterOf: layer))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1; spring.stiffness = 340; spring.damping = 27
        spring.duration = min(0.6, spring.settlingDuration)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(spring, forKey: "breathePop")
        layer.add(fade, forKey: "breatheFade")
    }

}

/// The selected tab's surface. It lives behind the tabs and slides between
/// them, so changing chats reads as one movement rather than two repaints.
@MainActor
final class BreatheTabSelection: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ChatChrome.drawSelectedTab(in: bounds, flipped: isFlipped)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    /// Move to a tab; slide there when the selection changed while on screen.
    func move(to frame: NSRect, animated: Bool) {
        let slide = animated && !isHidden && self.frame.width > 0 && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard slide else { self.frame = frame; needsDisplay = true; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            context.allowsImplicitAnimation = true
            animator().frame = frame
        }
    }
}

/// Replaces the Follow live checkbox: it appears over the feed only while the
/// reader is away from the newest activity, and one click returns there.
@MainActor
final class FeedLatestPill: NSButton {
    private(set) var isShown = false

    init() {
        super.init(frame: .zero)
        title = "Latest"
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        alphaValue = 0; isHidden = true
        toolTip = "Go to the latest activity and follow it"
        setAccessibilityLabel("Follow latest activity")
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private var label: NSAttributedString {
        NSAttributedString(string: "Latest", attributes: [.font: InterfaceTypography.font(Typography.caption),
            .foregroundColor: isHighlighted ? FeedPalette.text : FeedPalette.muted])
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.size().width) + 42, height: 28)
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { isHidden = false }
        let instant = window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = instant ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.isHidden = true
            }
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        FeedPalette.canvas.setFill(); shape.fill()
        FeedPalette.text.withAlphaComponent(isHighlighted ? 0.1 : 0.05).setFill(); shape.fill()
        FeedPalette.line.setStroke(); shape.lineWidth = 1; shape.stroke()
        let text = label, size = text.size()
        let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let arrowWidth: CGFloat = arrow == nil ? 0 : 16
        let x = (bounds.width - size.width - arrowWidth) / 2
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        if let arrow {
            let tinted = NSImage(size: arrow.size, flipped: false) { area in
                arrow.draw(in: area)
                FeedPalette.muted.set(); area.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x + size.width + 6, y: (bounds.height - arrow.size.height) / 2,
                                   width: arrow.size.width, height: arrow.size.height))
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// A symbol button that can shed its bezel: quiet, it shows only its glyph and
/// a soft wash under the pointer.
@MainActor
final class QuietIconButton: NSButton {
    /// Off, it draws as the ordinary button it was configured as.
    var isQuiet = false {
        didSet {
            guard isQuiet != oldValue else { return }
            isBordered = !isQuiet
            contentTintColor = isQuiet ? FeedPalette.muted : nil
            needsDisplay = true
        }
    }
    private var hovering = false { didSet { if isQuiet, hovering != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if isQuiet, isEnabled, hovering || isHighlighted {
            FeedPalette.text.withAlphaComponent(isHighlighted ? 0.1 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
