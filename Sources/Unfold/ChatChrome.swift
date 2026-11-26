import AppKit
import QuartzCore

/// Keep pane selection and composer outlines in sync with actual window focus.
@MainActor
final class ChatWorkspaceWindow: NSWindow {
    var onInteraction: ((NSView) -> Void)?
    var onResponderChange: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            onInteraction?(hit)
        }
        super.sendEvent(event)
        if event.type == .leftMouseDown { onResponderChange?() }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result {
            if let view = responder as? NSView { onInteraction?(view) }
            onResponderChange?()
        }
        return result
    }
}

/// Shared alignment for the sections inside a chat pane.
enum PaneSpacing {
    static let textInset: CGFloat = 16
    static let gap: CGFloat = 8
    static let composerInset: CGFloat = 16
    static let controlHeight: CGFloat = 28
}

/// Solid surfaces avoid wallpaper tinting and remain adaptive in dark mode.
@MainActor
class WorkspaceSurface: NSView {
    var fill: NSColor = FeedPalette.canvas { didSet { needsDisplay = true } }
    init(fill: NSColor = FeedPalette.canvas) {
        self.fill = fill
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// Clips the entire tab/feed/composer group into one contained pane.
@MainActor
final class PaneSurface: WorkspaceSurface {
    static let inset: CGFloat = 4
    static let radius: CGFloat = 16

    override init(fill: NSColor = FeedPalette.canvas) {
        super.init(fill: fill)
        wantsLayer = true
        applyInterfaceStyle()
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    func applyInterfaceStyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rounded = InterfaceStyle.hasRoundedPanes
        layer?.cornerRadius = rounded ? Self.radius : 0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = rounded
        layer?.borderWidth = rounded ? 0.5 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = FeedPalette.line.cgColor
        }
        CATransaction.commit()
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInterfaceStyle()
    }
}

/// Shared, adaptive chrome for the otherwise quiet empty-chat surface.
@MainActor
enum ChatChrome {
    static let tabRadius: CGFloat = 12

    static func drawSelectedTab(in bounds: NSRect, flipped: Bool) {
        let breathe = InterfaceStyle.isBreathe
        let rect = bounds.insetBy(dx: 0.5, dy: breathe ? 4 : 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = breathe ? Breathe.tabRadius : tabRadius
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        FeedPalette.text.withAlphaComponent(breathe ? 0.075 : 0.07).setFill()
        shape.fill()
        guard !breathe || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        FeedPalette.text.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.5 : 0.1).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

@MainActor
final class ChatControlBar: NSView {
    var fill = FeedPalette.chatControls { didSet { needsDisplay = true } }
    /// Hairlines define the status strip without adding visual weight.
    var drawsBorder = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        guard drawsBorder else { return }
        FeedPalette.line.setStroke()
        let border = NSBezierPath()
        for y in [bounds.minY + 0.25, bounds.maxY - 0.25] {
            border.move(to: NSPoint(x: bounds.minX, y: y))
            border.line(to: NSPoint(x: bounds.maxX, y: y))
        }
        border.lineWidth = 0.5; border.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A quiet, stationary shadow lifts the input slightly off the canvas.
/// Focus and image-drop feedback are drawn as a steady outline by ComposerCard.
@MainActor
class ComposerGlowSurface: NSView {
    var focused = false { didSet { updateGlow(); needsDisplay = true } }
    var receivingImages = false { didSet { updateGlow(); needsDisplay = true } }
    var caretVisible = true {
        didSet { if caretVisible != oldValue { updateGlow(animated: true) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
    override func layout() {
        super.layout()
        updateGlow()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlow(); needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlow()
    }
    @objc private func displayOptionsChanged() { updateGlow() }
    @objc private func systemColorsChanged() { updateGlow(); needsDisplay = true }

    private func updateGlow(animated: Bool = false) {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.shadowColor = NSColor.black.cgColor
        }
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
        layer.shadowOpacity = window == nil ? 0 : 0.04
        layer.removeAnimation(forKey: "caretGlow")
        CATransaction.commit()
    }
}
