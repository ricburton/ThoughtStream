import AppKit
import QuartzCore

struct ChatTabDrag: Equatable {
    let sessionID: UUID
    let columnID: UUID
}

enum TabSplitSide: Equatable {
    case left, right, top, bottom
    var vertical: Bool { self == .left || self == .right }
    var leading: Bool { self == .left || self == .top }
    var label: String {
        switch self { case .left: return "left"; case .right: return "right"; case .top: return "above"; case .bottom: return "below" }
    }

    static func target(at point: NSPoint, in bounds: NSRect) -> Self? {
        guard bounds.width > 0, bounds.contains(point) else { return nil }
        let edge = min(220, bounds.width * 0.28)
        if point.x <= bounds.minX + edge { return .left }
        if point.x >= bounds.maxX - edge { return .right }
        let edgeY = min(120, bounds.height * 0.24)
        if point.y >= bounds.maxY - edgeY { return .top }
        if point.y <= bounds.minY + edgeY { return .bottom }
        return nil
    }

    func previewFrame(in bounds: NSRect, divider: CGFloat) -> NSRect {
        if vertical {
            let width = max(0, (bounds.width - divider) / 2)
            return NSRect(x: self == .left ? bounds.minX : bounds.maxX - width,
                          y: bounds.minY, width: width, height: bounds.height).insetBy(dx: 7, dy: 7)
        }
        let height = max(0, (bounds.height - divider) / 2)
        return NSRect(x: bounds.minX, y: self == .top ? bounds.maxY - height : bounds.minY,
                      width: bounds.width, height: height).insetBy(dx: 7, dy: 7)
    }
}

/// An ancestor of the entire pane area, so tab drags work over feeds and composers
/// without interfering with their text selection or image-drop destinations.
@MainActor
final class TabSplitHostView: NSView {
    var validate: ((ChatTabDrag, TabSplitSide) -> Bool)?
    var onDrop: ((ChatTabDrag, TabSplitSide) -> Bool)?
    var hasSplit: (() -> Bool)?
    var dividerThickness: CGFloat = 1
    private let preview = TabSplitPreview()
    private(set) var previewSide: TabSplitSide?

    override init(frame: NSRect) {
        super.init(frame: frame)
        preview.alphaValue = 0
        addSubview(preview)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if InterfaceStyle.hasRoundedPanes {
            FeedPalette.sidebar.setFill(); bounds.fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    /// Choose the innermost pane under the pointer. The outer workspace host
    /// may contain multiple nested splits, each with its own drop target.
    static func previewDestination(for payload: ChatTabDrag, at point: NSPoint, in root: NSView) -> (TabSplitHostView, TabSplitSide)? {
        let hosts = dropHosts(in: root)
        let match = hosts.compactMap { host -> (TabSplitHostView, TabSplitSide)? in
            guard !host.isHiddenOrHasHiddenAncestor,
                  let side = TabSplitSide.target(at: host.convert(point, from: nil), in: host.bounds),
                  host.validate?(payload, side) == true else { return nil }
            return (host, side)
        }.first
        for host in hosts {
            if let (target, side) = match, host === target { host.showPreview(side) }
            else { host.clearPreview() }
        }
        return match
    }
    static func clearPreviews(in root: NSView) { dropHosts(in: root).forEach { $0.clearPreview() } }
    private static func dropHosts(in root: NSView) -> [TabSplitHostView] {
        root.subviews.reversed().flatMap { dropHosts(in: $0) } + ((root as? TabSplitHostView).map { [$0] } ?? [])
    }

    override func layout() {
        super.layout()
        if let side = previewSide { preview.frame = side.previewFrame(in: bounds, divider: dividerThickness) }
    }
    func showPreview(_ side: TabSplitSide) {
        guard side != previewSide else { return }
        let wasVisible = previewSide != nil
        previewSide = side
        preview.title = (side.vertical ? "Split " : "Stack ") + side.label
        preview.symbol = side.vertical ? "rectangle.split.2x1" : "rectangle.split.1x2"
        let target = side.previewFrame(in: bounds, divider: dividerThickness)
        if !wasVisible {
            preview.frame = target.insetBy(dx: 12, dy: 8)
            preview.alphaValue = 0
        }
        addSubview(preview, positioned: .above, relativeTo: nil)
        animate {
            self.preview.animator().frame = target
            self.preview.animator().alphaValue = 1
        }
    }
    func clearPreview() {
        guard previewSide != nil else { return }
        previewSide = nil
        animate { self.preview.animator().alphaValue = 0 }
    }
    private func animate(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            changes()
        }
    }
}

@MainActor
private final class TabSplitPreview: NSView {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var symbol = "rectangle.split.2x1" { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.84).setFill(); shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke(); shape.lineWidth = 2; shape.stroke()
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 18))
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon?.draw(in: NSRect(x: bounds.midX - 16, y: bounds.midY + 16, width: 32, height: 28))
    }
}
