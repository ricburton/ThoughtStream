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
    private let edges: [PaneCanvasEdge: PaneOverflowButton] = Dictionary(uniqueKeysWithValues:
        PaneCanvasEdge.allCases.map { ($0, PaneOverflowButton(edge: $0)) })
    private var scrollMonitor: Any?
    private var boundsObserver: NSObjectProtocol?
    private var gestureIsHorizontal = false
    private var fitting = false
    private var fittedViewport = NSSize.zero
    private var fittedMinimum = NSSize.zero

    /// The area panes are laid out for; the canvas itself may be larger.
    var viewport: NSSize { isViewLoaded ? view.bounds.size : .zero }
    var canvasSize: NSSize { document.frame.size }
    var visibleRect: NSRect { scroll.documentVisibleRect }
    var overflows: (horizontal: Bool, vertical: Bool) {
        (document.frame.width > viewport.width + 0.5, document.frame.height > viewport.height + 0.5)
    }

    override func loadView() {
        let root = PaneCanvasView()
        root.onLayout = { [weak self] in self?.fit() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .automatic
        scroll.usesPredominantAxisScrolling = true
        scroll.documentView = document
        scroll.frame = root.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.setAccessibilityLabel("Panes")
        root.addSubview(scroll)
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
            MainActor.assumeIsolated { self?.refreshOverflow() }
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
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
    }

    /// Swap the pane tree while keeping the scroll position. A topology change
    /// crossfades, so panes never appear to jump.
    func setLayout(_ controller: PaneLayoutController?, animated: Bool = false) {
        loadViewIfNeeded()
        let origin = scroll.contentView.bounds.origin
        if let layout {
            layout.view.removeFromSuperview(); layout.removeFromParent()
        }
        layout = controller
        fittedViewport = .zero
        guard let controller else { return }
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
        guard isViewLoaded, view.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        document.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        document.layer?.add(fade, forKey: "paneTopology")
    }

    /// Size the canvas for the current pane area and tell the tree how small
    /// its panes may go there.
    func fit() {
        guard let layout, !fitting else { return }
        let viewport = viewport
        guard viewport.width > 0, viewport.height > 0 else { return }
        fitting = true
        defer { fitting = false }
        let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
        let minimum = PaneLayout.adaptiveMinimum(viewport: viewport, paneInset: inset)
        layout.paneMinimum = minimum
        let needed = layout.minimumSize
        let size = NSSize(width: max(viewport.width, ceil(needed.width)), height: max(viewport.height, ceil(needed.height)))
        let changed = document.frame.size != size || layout.view.frame.size != size || minimum != fittedMinimum
        if document.frame.size != size { document.setFrameSize(size) }
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
        if animated, view.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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

    /// Bring a pane fully into view with the smallest possible movement.
    func reveal(_ target: NSView, animated: Bool = true) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        fit()
        guard target.isDescendant(of: document) else { return }
        scrollTo(Self.origin(revealing: document.convert(target.bounds, from: target),
                             visible: scroll.documentVisibleRect), animated: animated)
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
        guard let layout else { edges.values.forEach { $0.isHidden = true }; return }
        let visible = scroll.documentVisibleRect
        let centers = layout.paneViews.map { document.convert($0.bounds, from: $0) }.map { NSPoint(x: $0.midX, y: $0.midY) }
        let counts: [PaneCanvasEdge: Int] = [
            .left: centers.filter { $0.x < visible.minX }.count,
            .right: centers.filter { $0.x > visible.maxX }.count,
            .top: centers.filter { $0.y < visible.minY }.count,
            .bottom: centers.filter { $0.y > visible.maxY }.count
        ]
        let bounds = view.bounds
        for (edge, button) in edges {
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
            case .bottom: origin = NSPoint(x: bounds.midX - size.width / 2, y: view.isFlipped ? bounds.maxY - size.height - 8 : 8)
            }
            button.frame = NSRect(origin: origin, size: size)
        }
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
        scrollTo(origin, animated: true)
    }

    // MARK: Sideways scrolling

    /// Feeds and composers scroll vertically and would swallow a sideways
    /// swipe. Give horizontal gestures to the canvas unless the pointer is over
    /// something that scrolls sideways itself (tab strips, attachment strips).
    private func consumes(_ event: NSEvent) -> Bool {
        guard isViewLoaded, let window = view.window, event.window === window, overflows.horizontal,
              let content = window.contentView,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
        let horizontal: Bool
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            // The direction a swipe starts in holds through its momentum.
            gestureIsHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            horizontal = gestureIsHorizontal
        } else if event.phase == [] && event.momentumPhase == [] {
            // A wheel mouse reports each notch on its own; Shift turns it sideways.
            horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        } else {
            horizontal = gestureIsHorizontal
        }
        guard horizontal else { return false }
        var node = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        while let current = node, current !== scroll {
            if let inner = current as? NSScrollView, let inside = inner.documentView,
               inside.frame.width > inner.contentSize.width + 1 { return false }
            node = current.superview
        }
        guard node === scroll else { return false }
        let distance = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 12)
        var origin = scroll.contentView.bounds.origin
        origin.x -= distance
        scrollTo(origin, animated: false)
        return true
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
            toolTip = "\(count) more pane\(count == 1 ? "" : "s") \(side). Click or swipe to scroll."
            setAccessibilityLabel("\(count) more pane\(count == 1 ? "" : "s") \(side)")
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
        let text = (title as NSString).size(withAttributes: [.font: Typography.badge])
        return NSSize(width: ceil(text.width) + 16, height: 22)
    }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        FeedPalette.surface.withAlphaComponent(0.96).setFill(); shape.fill()
        FeedPalette.line.setStroke(); shape.lineWidth = 1; shape.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: Typography.badge,
            .foregroundColor: isHighlighted ? FeedPalette.text : FeedPalette.muted])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
