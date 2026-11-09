import AppKit

/// A native draggable divider keeps the navigator's chosen width as the pane resizes.
@MainActor
final class FeedNavigatorSplitView: NSSplitView, NSSplitViewDelegate {
    var preferredWidth: CGFloat?
    var onResize: (() -> Void)?
    private var arranging = false

    init() {
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        setAccessibilityLabel("Object navigator and activity")
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override var dividerThickness: CGFloat { 8 }

    override func drawDivider(in rect: NSRect) {
        FeedPalette.line.setFill()
        NSRect(x: rect.midX, y: rect.minY, width: 1, height: rect.height).fill()
        FeedPalette.muted.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 1, y: rect.midY - 14,
                                       width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
    }

    private var minimumWidth: CGFloat { min(140, max(0, bounds.width - dividerThickness) / 2) }
    private var maximumWidth: CGFloat { max(minimumWidth, bounds.width - dividerThickness - 160) }

    override func setFrameSize(_ newSize: NSSize) {
        let wasArranging = arranging
        arranging = true
        defer { arranging = wasArranging }
        super.setFrameSize(newSize)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { super.resizeSubviews(withOldSize: oldSize); return }
        let wasArranging = arranging
        arranging = true
        defer { arranging = wasArranging }
        super.resizeSubviews(withOldSize: oldSize)
        let requested = preferredWidth ?? max(140, min(210, bounds.width * 0.25))
        setPosition(min(maximumWidth, max(minimumWidth, requested)), ofDividerAt: 0)
    }

    func restoreWidth(_ width: Double?) {
        preferredWidth = width.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        resizeSubviews(withOldSize: bounds.size)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimumWidth }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { maximumWidth }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, let navigator = subviews.first, bounds.width > dividerThickness else { return }
        preferredWidth = navigator.frame.width
        onResize?()
    }
}
