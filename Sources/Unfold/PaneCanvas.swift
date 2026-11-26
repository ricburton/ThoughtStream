import AppKit
import QuartzCore

/// The pane area. Panes share the visible space until they reach the adaptive
/// minimum; after that the canvas grows and scrolls instead of refusing a split
/// or forcing the window larger. A bigger window gives every pane more room.
@MainActor
final class PaneCanvasController: NSViewController {
    private(set) var layout: PaneLayoutController?
    private let scroll = NSScrollView()
    private let document = PaneCanvasDocument()
    let horizontalNavigation = PaneHorizontalNavigation()
    private let edges: [PaneCanvasEdge: PaneOverflowButton] = Dictionary(uniqueKeysWithValues:
        PaneCanvasEdge.allCases.map { ($0, PaneOverflowButton(edge: $0)) })
    private var scrollMonitor: Any?
    private var boundsObserver: NSObjectProtocol?
    private var scrollGesture = PaneScrollGesture()
    private var fitting = false
    private var fitScheduled = false
    private var fittedViewport = NSSize.zero
    private var fittedMinimum = NSSize.zero
    private var closeTransition: PaneCloseTransition?
    var onHorizontalScroll: ((CGFloat) -> Void)?
    /// Extra space requested by dragging, retained separately from automatic fit.
    var minimumCanvasSize = NSSize.zero
    var hasCustomSizing = false
    /// Allow rebalanced columns to occupy less than the viewport.
    var usesCompactColumnSizing = false

    /// The area panes are laid out for; the canvas itself may be larger.
    var viewport: NSSize { isViewLoaded ? scroll.contentSize : .zero }
    var canvasSize: NSSize { document.frame.size }
    var visibleRect: NSRect { scroll.documentVisibleRect }
    var overflows: (horizontal: Bool, vertical: Bool) {
        (document.frame.width > viewport.width + 0.5, document.frame.height > viewport.height + 0.5)
    }

    override func loadView() {
        let root = PaneCanvasView()
        // Fitting changes the pane tree's frames. Defer it until AppKit has
        // finished the current canvas layout pass so those changes cannot
        // recursively start another subtree layout from inside `layout()`.
        root.onLayout = { [weak self] in self?.scheduleFit() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .automatic
        scroll.usesPredominantAxisScrolling = true
        scroll.documentView = document
        scroll.frame = root.bounds
        scroll.setAccessibilityLabel("Chats on screen")
        root.addSubview(scroll)
        horizontalNavigation.isHidden = true
        horizontalNavigation.scroller.target = self
        horizontalNavigation.scroller.action = #selector(scrollHorizontally(_:))
        root.addSubview(horizontalNavigation)
        for (edge, button) in edges {
            button.isHidden = true
            button.target = self; button.action = #selector(page(_:))
            button.tag = edge.rawValue
            root.addSubview(button)
        }
        view = root
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelCloseTransition()
                self?.refreshOverflow()
            }
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        cancelCloseTransition()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        scrollGesture = PaneScrollGesture()
    }

    /// Swap the pane tree while keeping the scroll position. A topology change
    /// crossfades, so panes never appear to jump.
    func setLayout(_ controller: PaneLayoutController?, animated: Bool = false) {
        cancelCloseTransition()
        loadViewIfNeeded()
        let origin = scroll.contentView.bounds.origin
        if let layout {
            layout.requestCanvasExtent = nil
            layout.beginManualResize = nil
            layout.view.removeFromSuperview(); layout.removeFromParent()
        }
        layout = controller
        fittedViewport = .zero
        guard let controller else {
            minimumCanvasSize = .zero
            hasCustomSizing = false
            usesCompactColumnSizing = false
            document.setFrameSize(view.bounds.size)
            scroll.frame = view.bounds
            horizontalNavigation.isHidden = true
            refreshOverflow()
            return
        }
        controller.beginManualResize = { [weak self, weak controller] in
            self?.hasCustomSizing = true
            controller?.paneMinimum = PaneLayout.compactPaneSize
        }
        controller.requestCanvasExtent = { [weak self] vertical, extent in
            guard let self, extent.isFinite, extent > 0 else { return }
            if vertical { self.minimumCanvasSize.width = max(self.minimumCanvasSize.width, extent) }
            else { self.minimumCanvasSize.height = max(self.minimumCanvasSize.height, extent) }
            self.fit()
        }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        document.addSubview(controller.view)
        if animated { softenTopologyChange() }
        // Out of a window the first layout pass fits it instead.
        if view.window != nil { fit() }
        scrollTo(origin, animated: false)
    }

    /// Crossfade the pane area across a change to the tree, so the panes that
    /// stay settle into their new sizes instead of jumping. Call before the change.
    func softenTopologyChange(duration: TimeInterval = 0.16) {
        cancelCloseTransition()
        guard isViewLoaded, view.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        document.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        document.layer?.add(fade, forKey: "paneTopology")
    }

    func captureClosingPanes(_ columns: [ChatColumn]) -> PaneCloseTransition? {
        let captured = PaneCloseTransition.capture(columns.map { ($0.columnID, $0.view) },
                                                   in: view, continuing: closeTransition)
        cancelCloseTransition()
        document.layer?.removeAnimation(forKey: "paneTopology")
        return captured
    }

    func animateClosingPane(_ id: UUID, captured: PaneCloseTransition?, remaining: [ChatColumn]) {
        guard let captured else { return }
        document.layer?.removeAnimation(forKey: "paneTopology")
        let destinations = Dictionary(uniqueKeysWithValues: remaining.map {
            ($0.columnID, view.convert($0.view.bounds, from: $0.view))
        })
        closeTransition = captured
        view.addSubview(captured)
        let livePanes = Dictionary(uniqueKeysWithValues: remaining.map { ($0.columnID, $0.view) })
        captured.animate(closing: id, to: destinations, livePanes: livePanes) { [weak self, weak captured] in
            if self?.closeTransition === captured { self?.closeTransition = nil }
        }
    }

    func cancelCloseTransition() {
        closeTransition?.cancel()
        closeTransition = nil
    }

    /// A small set of columns fills the window again after adding, closing or
    /// arranging panes, even if an earlier divider drag enlarged the canvas.
    func balanceToFit() {
        guard let layout else { return }
        usesCompactColumnSizing = false
        if layout.columnCount <= PaneLayout.visibleColumnsBeforeScrolling {
            minimumCanvasSize.width = 0
            hasCustomSizing = minimumCanvasSize.height > 0
        }
        fit()
        layout.balance()
    }

    func shrinkColumnsToMinimum() {
        guard let layout else { return }
        cancelCloseTransition()
        usesCompactColumnSizing = true
        hasCustomSizing = true
        minimumCanvasSize.width = 0
        let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
        let width = PaneLayout.rebalancedColumnWidth(viewport: viewport, paneInset: inset) + 2 * inset
        _ = layout.preserveWidths(Dictionary(uniqueKeysWithValues: layout.snapshot.ids.map { ($0, width) }))
        fit()
        layout.restoreFractions()
    }

    /// Size the canvas for the current pane area and tell the tree how small
    /// its panes may go there.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fit()
        }
    }

    func fit() {
        guard let layout, !fitting else { return }
        let available = view.bounds.size
        guard available.width > 0, available.height > 0 else { return }
        if let closeTransition, closeTransition.frame.size != available { cancelCloseTransition() }
        fitting = true
        defer { fitting = false }
        let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
        let columnCount = layout.columnCount
        func minimumSizeForViewport(_ viewport: NSSize) -> NSSize {
            var minimum = PaneLayout.adaptiveMinimum(viewport: viewport, paneInset: inset)
            if usesCompactColumnSizing {
                minimum.width = PaneLayout.rebalancedColumnWidth(viewport: viewport, paneInset: inset)
                return minimum
            }
            if columnCount < PaneLayout.visibleColumnsBeforeScrolling {
                let share = (viewport.width - CGFloat(columnCount - 1)) / CGFloat(columnCount) - 2 * inset
                minimum.width = min(minimum.width, max(1, share))
            }
            return minimum
        }
        let preferred = minimumSizeForViewport(available)
        let needsNavigation = max(minimumCanvasSize.width, layout.minimumSize(paneMinimum: preferred).width) > available.width + 0.5
        let footerHeight: CGFloat = needsNavigation ? min(PaneHorizontalNavigation.height, available.height) : 0
        horizontalNavigation.isHidden = !needsNavigation
        let navigationFrame = NSRect(x: 0, y: 0, width: available.width, height: footerHeight)
        if horizontalNavigation.frame != navigationFrame { horizontalNavigation.frame = navigationFrame }
        let scrollFrame = NSRect(x: 0, y: footerHeight, width: available.width,
                                 height: available.height - footerHeight)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        let viewport = viewport
        let minimum = minimumSizeForViewport(viewport)
        // Five-across is the automatic sizing preference, not a divider lock.
        layout.paneMinimum = hasCustomSizing ? PaneLayout.compactPaneSize : minimum
        if usesCompactColumnSizing {
            // The manual compact floor must not prevent five columns from fitting.
            layout.paneMinimum?.width = min(PaneLayout.compactPaneSize.width, minimum.width)
        }
        let needed = layout.minimumSize(paneMinimum: minimum)
        let size = NSSize(width: max(usesCompactColumnSizing ? 0 : viewport.width, ceil(needed.width), minimumCanvasSize.width),
                          height: max(viewport.height, ceil(needed.height), minimumCanvasSize.height))
        let documentSize = NSSize(width: max(viewport.width, size.width), height: size.height)
        let changed = document.frame.size != documentSize || layout.view.frame.size != size || minimum != fittedMinimum
        if document.frame.size != documentSize { document.setFrameSize(documentSize) }
        let frame = NSRect(origin: .zero, size: size)
        if layout.view.frame != frame { layout.view.frame = frame }
        fittedViewport = viewport; fittedMinimum = minimum
        if changed || !layout.isArranged { layout.restoreFractions() }
        scrollTo(scroll.contentView.bounds.origin, animated: false)
        refreshOverflow()
    }

    private func clamp(_ origin: NSPoint) -> NSPoint {
        NSPoint(x: min(max(0, document.frame.width - viewport.width), max(0, origin.x)),
                y: min(max(0, document.frame.height - viewport.height), max(0, origin.y)))
    }

    private func scrollTo(_ requested: NSPoint, animated: Bool) {
        let origin = clamp(requested)
        guard origin != scroll.contentView.bounds.origin else { return }
        if animated, view.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                scroll.contentView.animator().setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Bring a pane into view. List selections can center it horizontally;
    /// ordinary pane navigation uses the smallest possible movement.
    func reveal(_ target: NSView, animated: Bool = true, centerHorizontally: Bool = false) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        fit()
        guard target.isDescendant(of: document) else { return }
        let rect = document.convert(target.bounds, from: target)
        let visible = scroll.documentVisibleRect
        var origin = Self.origin(revealing: rect, visible: visible)
        if centerHorizontally, rect.width < visible.width {
            origin.x = rect.midX - visible.width / 2
        }
        scrollTo(origin, animated: animated)
    }

    /// A pane larger than the pane area aligns to its leading/top edge.
    nonisolated static func origin(revealing rect: NSRect, visible: NSRect) -> NSPoint {
        func axis(_ low: CGFloat, _ high: CGFloat, _ start: CGFloat, _ length: CGFloat) -> CGFloat {
            if high - low >= length || low < start { return low }
            if high > start + length { return high - length }
            return start
        }
        return NSPoint(x: axis(rect.minX, rect.maxX, visible.minX, visible.width),
                       y: axis(rect.minY, rect.maxY, visible.minY, visible.height))
    }

    // MARK: Overflow affordances

    private func refreshOverflow() {
        onHorizontalScroll?(layout == nil ? 0 : max(0, scroll.documentVisibleRect.minX))
        guard let layout else { edges.values.forEach { $0.isHidden = true }; return }
        let visible = scroll.documentVisibleRect
        horizontalNavigation.update(visible: visible, contentWidth: document.frame.width)
        let centers = layout.paneViews.map { document.convert($0.bounds, from: $0) }.map { NSPoint(x: $0.midX, y: $0.midY) }
        let counts: [PaneCanvasEdge: Int] = [
            .left: centers.filter { $0.x < visible.minX }.count,
            .right: centers.filter { $0.x > visible.maxX }.count,
            .top: centers.filter { $0.y < visible.minY }.count,
            .bottom: centers.filter { $0.y > visible.maxY }.count
        ]
        let bounds = scroll.frame
        for (edge, button) in edges {
            if edge == .left || edge == .right {
                button.isHidden = true
                continue
            }
            let count = counts[edge] ?? 0
            button.isHidden = count == 0
            guard count > 0 else { continue }
            button.count = count
            let size = button.fittingSize
            let origin: NSPoint
            switch edge {
            case .left: origin = NSPoint(x: 8, y: bounds.midY - size.height / 2)
            case .right: origin = NSPoint(x: bounds.maxX - size.width - 8, y: bounds.midY - size.height / 2)
            case .top: origin = NSPoint(x: bounds.midX - size.width / 2, y: view.isFlipped ? 8 : bounds.maxY - size.height - 8)
            case .bottom: origin = NSPoint(x: bounds.midX - size.width / 2, y: view.isFlipped ? bounds.maxY - size.height - 8 : bounds.minY + 8)
            }
            button.frame = NSRect(origin: origin, size: size)
        }
    }

    @objc private func scrollHorizontally(_ sender: NSScroller) {
        var origin = scroll.documentVisibleRect.origin
        let page = viewport.width * 0.8
        switch sender.hitPart {
        case .decrementLine: origin.x -= 40
        case .incrementLine: origin.x += 40
        case .decrementPage: origin.x -= page
        case .incrementPage: origin.x += page
        default: origin.x = CGFloat(sender.doubleValue) * max(0, document.frame.width - viewport.width)
        }
        scrollTo(origin, animated: false)
    }

    @objc private func page(_ sender: NSButton) {
        guard let edge = PaneCanvasEdge(rawValue: sender.tag), let layout else { return }
        let visible = scroll.documentVisibleRect
        let frames = layout.paneViews.map { document.convert($0.bounds, from: $0) }
        // Step to the nearest pane that is not fully visible on that side.
        let target: NSRect?
        switch edge {
        case .left: target = frames.filter { $0.minX < visible.minX - 0.5 }.max { $0.minX < $1.minX }
        case .right: target = frames.filter { $0.maxX > visible.maxX + 0.5 }.min { $0.maxX < $1.maxX }
        case .top: target = frames.filter { $0.minY < visible.minY - 0.5 }.max { $0.minY < $1.minY }
        case .bottom: target = frames.filter { $0.maxY > visible.maxY + 0.5 }.min { $0.maxY < $1.maxY }
        }
        guard let target else { return }
        var origin = Self.origin(revealing: target, visible: visible)
        if edge == .left || edge == .right { origin.y = visible.minY } else { origin.x = visible.minX }
        // An oversized pane must still advance in the requested direction.
        if edge == .right && origin.x <= visible.minX { origin.x = visible.minX + visible.width * 0.8 }
        if edge == .left && origin.x >= visible.minX { origin.x = visible.minX - visible.width * 0.8 }
        scrollTo(origin, animated: true)
    }

    // MARK: Sideways scrolling

    /// Feeds and composers scroll vertically and would swallow a sideways
    /// swipe. Give horizontal gestures to the canvas unless the pointer is over
    /// something that can still scroll sideways itself (tabs, attachments).
    private func consumes(_ event: NSEvent) -> Bool {
        guard isViewLoaded, let window = view.window, event.window === window, overflows.horizontal,
              let content = window.contentView,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
        guard let distance = scrollGesture.distance(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            phase: event.phase, momentum: event.momentumPhase, shift: event.modifierFlags.contains(.shift),
            precise: event.hasPreciseScrollingDeltas) else { return false }
        let node = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        return scrollSideways(by: distance, over: node)
    }

    /// Route a sideways movement from any pane surface, preserving the local
    /// vertical reading position. Nested horizontal content gets first use.
    @discardableResult
    func scrollSideways(by distance: CGFloat, over target: NSView?) -> Bool {
        guard overflows.horizontal, distance != 0 else { return false }
        var node = target
        if target?.isDescendant(of: horizontalNavigation) == true { node = scroll }
        while let current = node, current !== scroll {
            if let inner = current as? NSScrollView, let inside = inner.documentView {
                let visible = inner.documentVisibleRect
                if distance > 0 && visible.minX > inside.bounds.minX + 0.5 { return false }
                if distance < 0 && visible.maxX < inside.bounds.maxX - 0.5 { return false }
            }
            node = current.superview
        }
        guard node === scroll else { return false }
        var origin = scroll.contentView.bounds.origin
        origin.x -= distance
        scrollTo(origin, animated: false)
        return true
    }
}

/// Trackpads may begin with zero movement. Wait for the first nonzero delta
/// before locking the axis, and retain it for the gesture's momentum.
struct PaneScrollGesture {
    private var horizontal: Bool?

    mutating func distance(x: CGFloat, y: CGFloat, phase: NSEvent.Phase,
                           momentum: NSEvent.Phase, shift: Bool, precise: Bool) -> CGFloat? {
        let wheel = phase.isEmpty && momentum.isEmpty
        if wheel || phase.contains(.began) || phase.contains(.mayBegin) { horizontal = nil }
        let sideways = shift && x == 0 ? y : x
        if horizontal == nil, x != 0 || y != 0 {
            horizontal = shift || abs(x) > abs(y)
        }
        let result = horizontal == true && sideways != 0 ? sideways * (precise ? 1 : 12) : nil
        if phase.contains(.cancelled) || momentum.contains(.ended) { horizontal = nil }
        return result
    }
}

enum PaneCanvasEdge: Int, CaseIterable { case left, right, top, bottom }

@MainActor
private final class PaneCanvasView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

@MainActor
private final class PaneCanvasDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A quiet count of the panes waiting off one edge; click to bring the next into view.
@MainActor
final class PaneOverflowButton: NSButton {
    let edge: PaneCanvasEdge
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            let label = "\(count)"
            switch edge {
            case .left: title = "‹ " + label
            case .right: title = label + " ›"
            case .top: title = "⌃ " + label
            case .bottom: title = "⌄ " + label
            }
            let side: String
            switch edge { case .left: side = "to the left"; case .right: side = "to the right"; case .top: side = "above"; case .bottom: side = "below" }
            toolTip = "\(count) more chat\(count == 1 ? "" : "s") \(side). Click or swipe to scroll."
            setAccessibilityLabel("\(count) more chat\(count == 1 ? "" : "s") \(side)")
            invalidateIntrinsicContentSize(); needsDisplay = true
        }
    }

    init(edge: PaneCanvasEdge) {
        self.edge = edge
        super.init(frame: .zero)
        isBordered = false
        font = Typography.badge
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: InterfaceTypography.font(Typography.badge)])
        return NSSize(width: ceil(text.width) + 16, height: 22)
    }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        FeedPalette.surface.withAlphaComponent(0.96).setFill(); shape.fill()
        FeedPalette.line.setStroke(); shape.lineWidth = 1; shape.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: InterfaceTypography.font(Typography.badge),
            .foregroundColor: isHighlighted ? FeedPalette.text : FeedPalette.muted])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
