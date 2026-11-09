import AppKit

/// The pane dividers keep their native appearance and accessibility, but a drag
/// is tracked in the whole row/column's coordinates, not a moving nested pair.
@MainActor
private final class PaneSplitView: NSSplitView {
    var positionRequested: ((CGFloat) -> Void)?
    var beginDrag: ((NSPoint) -> ((NSPoint) -> Void)?)?
    private var arranging = false

    override var dividerColor: NSColor {
        InterfaceStyle.hasRoundedPanes ? FeedPalette.sidebar : super.dividerColor
    }
    private var dividerHitRect: NSRect {
        // AppKit may append a private divider/accessibility view after the two
        // arranged panes. It must not disable our mouse tracking.
        guard let first = subviews.first, subviews.count >= 2 else { return .zero }
        if isVertical {
            return NSRect(x: first.frame.maxX - 3, y: 0, width: dividerThickness + 6, height: bounds.height)
        }
        let y = isFlipped ? first.frame.maxY : first.frame.minY - dividerThickness
        return NSRect(x: 0, y: y - 3, width: bounds.width, height: dividerThickness + 6)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHidden, dividerHitRect.contains(local) { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(dividerHitRect, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
    }
    override func mouseDown(with event: NSEvent) {
        guard dividerHitRect.contains(convert(event.locationInWindow, from: nil)),
              let window, let update = beginDrag?(event.locationInWindow) else {
            super.mouseDown(with: event); return
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            update(next.locationInWindow)
            if next.type == .leftMouseUp { break }
        }
    }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        if !arranging, dividerIndex == 0, let positionRequested {
            positionRequested(position)
        } else {
            super.setPosition(position, ofDividerAt: dividerIndex)
        }
    }
    func placeDivider(_ position: CGFloat) {
        arranging = true
        defer { arranging = false }
        super.setPosition(position, ofDividerAt: 0)
        window?.invalidateCursorRects(for: self)
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let wasArranging = arranging
        arranging = true
        defer { arranging = wasArranging }
        super.resizeSubviews(withOldSize: oldSize)
    }
}

@MainActor
private final class PaneLayoutFrameView: NSView {
    var didLayout: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        didLayout?()
    }
}

/// Allocate space proportionally, fixing panes at their minimum only as needed.
/// If an external frame change is smaller than all minima, degrade together
/// instead of producing negative sizes or conflicting required constraints.
enum PaneSizing {
    static func shares(total: CGFloat, weights: [CGFloat], minima: [CGFloat]) -> [CGFloat] {
        guard !weights.isEmpty, weights.count == minima.count else { return [] }
        let available = max(0, total)
        let minimum = minima.reduce(0, +)
        if available < minimum {
            return minima.map { minimum > 0 ? available * $0 / minimum : 0 }
        }
        var result = Array(repeating: CGFloat.zero, count: weights.count)
        var pending = Array(weights.indices)
        var remaining = available
        while !pending.isEmpty {
            let weight = pending.reduce(CGFloat.zero) { $0 + max(0.0001, weights[$1]) }
            let fixed = pending.filter { remaining * max(0.0001, weights[$0]) / weight < minima[$0] }
            if fixed.isEmpty {
                for index in pending { result[index] = remaining * max(0.0001, weights[index]) / weight }
                break
            }
            for index in fixed { result[index] = minima[index]; remaining -= minima[index] }
            pending.removeAll { fixed.contains($0) }
        }
        return result
    }
}

/// A binary split tree. Each leaf retains its own tab strip, feed and composer.
/// Consecutive splits on one axis behave as a single row or column of lanes.
@MainActor
final class PaneLayoutController: NSViewController {
    private let model: PaneLayout
    private var split: NSSplitViewController?
    private var branches: [PaneLayoutController] = []
    private weak var layoutParent: PaneLayoutController?
    private var fraction: Double = 0.5
    private var laneWeights: [CGFloat]?
    private var paneEdges: [NSLayoutConstraint] = []
    private let resized: () -> Void
    private var arranging = false
    private var lastSize = NSSize.zero

    init(layout: PaneLayout, columns: [UUID: ChatColumn], configureHost: (TabSplitHostView, ChatColumn) -> Void,
         resized: @escaping () -> Void) {
        model = layout
        self.resized = resized
        super.init(nibName: nil, bundle: nil)
        switch layout {
        case .pane(let id):
            let host = TabSplitHostView()
            view = host
            guard let column = columns[id] else { return }
            configureHost(host, column)
            column.removeFromParent()
            column.view.removeFromSuperview()
            addChild(column)
            column.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(column.view, positioned: .below, relativeTo: nil)
            paneEdges = [
                column.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                column.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                column.view.topAnchor.constraint(equalTo: host.topAnchor),
                column.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ]
            NSLayoutConstraint.activate(paneEdges)
        case .split(let vertical, let value, let first, let second):
            fraction = value.isFinite ? min(1, max(0, value)) : 0.5
            let controller = NSSplitViewController()
            let splitView = PaneSplitView()
            controller.splitView = splitView
            splitView.isVertical = vertical
            splitView.dividerStyle = .thin
            split = controller
            let frameView = PaneLayoutFrameView()
            view = frameView
            frameView.didLayout = { [weak self] in self?.resizeIfNeeded() }
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            for child in [first, second] {
                let branch = PaneLayoutController(layout: child, columns: columns, configureHost: configureHost, resized: resized)
                branch.layoutParent = self
                branches.append(branch)
                controller.addSplitViewItem(NSSplitViewItem(viewController: branch))
            }
            splitView.positionRequested = { [weak self] position in self?.moveDivider(to: position) }
            splitView.beginDrag = { [weak self] point in self?.beginDividerDrag(at: point) }
        }
        applyInterfaceStyle()
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private var root: PaneLayoutController { layoutParent?.root ?? self }
    private var axis: Bool? { split?.splitView.isVertical }
    private var extent: CGFloat {
        guard let split else { return 0 }
        return split.splitView.isVertical ? split.splitView.bounds.width : split.splitView.bounds.height
    }
    private var divider: CGFloat { split?.splitView.dividerThickness ?? 1 }
    var minimumSize: NSSize {
        if let vertical = axis {
            let a = branches[0].minimumSize, b = branches[1].minimumSize
            return vertical ? NSSize(width: a.width + b.width + divider, height: max(a.height, b.height))
                : NSSize(width: max(a.width, b.width), height: a.height + b.height + divider)
        }
        let fitting = children.first?.view.fittingSize ?? .zero
        let inset = InterfaceStyle.hasRoundedPanes ? 2 * PaneSurface.inset : 0
        return NSSize(width: max(PaneLayout.minimumPaneSize.width, ceil(fitting.width)) + inset,
                      height: max(PaneLayout.minimumPaneSize.height, ceil(fitting.height)) + inset)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        resizeIfNeeded()
    }

    private func resizeIfNeeded() {
        guard layoutParent == nil, !arranging, view.bounds.size != lastSize,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        restoreFractions()
    }

    func applyInterfaceStyle() {
        let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
        for (index, edge) in paneEdges.enumerated() {
            edge.constant = index == 0 || index == 2 ? inset : -inset
        }
        view.needsDisplay = true
        split?.splitView.needsDisplay = true
        branches.forEach { $0.applyInterfaceStyle() }
    }

    /// Reapply saved lane proportions on every frame change. AppKit's default
    /// nested resizing can otherwise enlarge only one child of each split.
    func restoreFractions() {
        let owner = root
        guard !owner.arranging else { return }
        owner.arranging = true
        // Resize observers can synchronously post another window resize. Keep
        // the guard through that callback, not just through the divider layout.
        defer { owner.arranging = false }
        owner.view.layoutSubtreeIfNeeded()
        owner.layoutTree()
        owner.lastSize = owner.view.bounds.size
        owner.resized()
    }

    private func lanes(along vertical: Bool) -> [PaneLayoutController] {
        guard axis == vertical else { return [self] }
        return branches.flatMap { $0.lanes(along: vertical) }
    }
    private var run: PaneLayoutController {
        guard let layoutParent, layoutParent.axis == axis else { return self }
        return layoutParent.run
    }
    private func boundaryIndex(of node: PaneLayoutController) -> Int? {
        if self === node { return branches[0].lanes(along: axis!).count }
        guard axis == node.axis else { return nil }
        if let index = branches[0].boundaryIndex(of: node) { return index }
        if let index = branches[1].boundaryIndex(of: node) {
            return branches[0].lanes(along: axis!).count + index
        }
        return nil
    }
    private func savedLengths(along vertical: Bool, extent: CGFloat) -> [CGFloat] {
        guard axis == vertical else { return [max(0, extent)] }
        let content = max(0, extent - divider)
        return branches[0].savedLengths(along: vertical, extent: content * fraction)
            + branches[1].savedLengths(along: vertical, extent: content * (1 - fraction))
    }
    private func layoutTree() {
        guard let vertical = axis else { return }
        view.layoutSubtreeIfNeeded()
        let items = lanes(along: vertical)
        if laneWeights == nil { laneWeights = savedLengths(along: vertical, extent: extent) }
        let minima = items.map { vertical ? $0.minimumSize.width : $0.minimumSize.height }
        let lengths = PaneSizing.shares(total: extent - CGFloat(items.count - 1) * divider,
            weights: laneWeights!, minima: minima)
        placeRun(lengths, along: vertical)
        items.forEach { $0.layoutTree() }
    }
    private func placeRun(_ lengths: [CGFloat], along vertical: Bool) {
        guard axis == vertical, let splitView = split?.splitView as? PaneSplitView else { return }
        let count = branches[0].lanes(along: vertical).count
        let first = Array(lengths.prefix(count)), second = Array(lengths.dropFirst(count))
        let position = first.reduce(0, +) + CGFloat(count - 1) * divider
        fraction = extent > divider ? Double(position / (extent - divider)) : 0.5
        splitView.placeDivider(position)
        view.layoutSubtreeIfNeeded()
        branches[0].placeRun(first, along: vertical)
        branches[1].placeRun(second, along: vertical)
    }

    private func coordinate(_ windowPoint: NSPoint) -> CGFloat {
        guard let split else { return 0 }
        let point = split.splitView.convert(windowPoint, from: nil)
        return split.splitView.isVertical ? point.x :
            (split.splitView.isFlipped ? point.y : split.splitView.bounds.height - point.y)
    }
    private func dividerCoordinate(in run: PaneLayoutController) -> CGFloat {
        guard let split, let first = split.splitView.subviews.first else { return 0 }
        let point: NSPoint
        if split.splitView.isVertical { point = NSPoint(x: first.frame.maxX, y: 0) }
        else { point = NSPoint(x: 0, y: split.splitView.isFlipped ? first.frame.maxY : first.frame.minY) }
        return run.coordinate(split.splitView.convert(point, to: nil))
    }
    private func beginDividerDrag(at point: NSPoint) -> ((NSPoint) -> Void)? {
        let run = run
        guard let index = run.boundaryIndex(of: self) else { return nil }
        let grabOffset = run.coordinate(point) - dividerCoordinate(in: run)
        return { [weak run] point in
            guard let run else { return }
            run.redistribute(at: index, coordinate: run.coordinate(point) - grabOffset)
        }
    }
    private func moveDivider(to position: CGFloat) {
        let run = run
        guard let split, let first = split.splitView.subviews.first,
              let index = run.boundaryIndex(of: self) else { return }
        let firstLength = split.splitView.isVertical ? first.frame.width : first.frame.height
        run.redistribute(at: index, coordinate: dividerCoordinate(in: run) + position - firstLength)
    }

    /// The grabbed boundary is pinned. All lanes before it share their space,
    /// and all lanes after it share theirs. Matching runs in other rows/columns
    /// use the same weights so a grid stays aligned while either axis is dragged.
    private func redistribute(at index: Int, coordinate: CGFloat) {
        let owner = root
        guard !owner.arranging, coordinate.isFinite, let vertical = axis else { return }
        let items = lanes(along: vertical)
        guard index > 0, index < items.count else { return }
        let total = max(0, extent - CGFloat(items.count - 1) * divider)
        var minima = items.map { vertical ? $0.minimumSize.width : $0.minimumSize.height }
        let minimum = minima.reduce(0, +)
        if minimum > total { minima = minima.map { $0 * total / minimum } }
        let low = minima.prefix(index).reduce(0, +)
        let high = total - minima.dropFirst(index).reduce(0, +)
        let before = min(high, max(low, coordinate - CGFloat(index - 1) * divider))
        let weights = PaneSizing.shares(total: before, weights: Array(repeating: 1, count: index), minima: Array(minima.prefix(index)))
            + PaneSizing.shares(total: total - before, weights: Array(repeating: 1, count: items.count - index), minima: Array(minima.dropFirst(index)))
        // Match the axis span, not only the lane count: independent inset groups
        // must not move just because they happen to contain the same number.
        let span = axisSpan(in: owner)
        owner.synchronizeRuns(along: vertical, span: span, weights: weights, in: owner)
        owner.restoreFractions()
    }
    private func axisSpan(in owner: PaneLayoutController) -> (CGFloat, CGFloat) {
        guard let split else { return (0, 0) }
        let rect = owner.view.convert(split.splitView.bounds, from: split.splitView)
        return split.splitView.isVertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
    }
    private func synchronizeRuns(along vertical: Bool, span: (CGFloat, CGFloat), weights: [CGFloat], in owner: PaneLayoutController) {
        if axis == vertical {
            let ownSpan = axisSpan(in: owner)
            let items = lanes(along: vertical)
            if items.count == weights.count, abs(ownSpan.0 - span.0) < 1, abs(ownSpan.1 - span.1) < 1 {
                laneWeights = weights
            }
            items.forEach { $0.synchronizeRuns(along: vertical, span: span, weights: weights, in: owner) }
        } else {
            branches.forEach { $0.synchronizeRuns(along: vertical, span: span, weights: weights, in: owner) }
        }
    }

    var snapshot: PaneLayout {
        guard let vertical = axis else { return model }
        let items = lanes(along: vertical)
        // Persist the requested proportions, not a temporary minimum-size clamp.
        // A narrow window or project switch must not erase the user's layout.
        let lengths = PaneSizing.shares(total: extent - CGFloat(items.count - 1) * divider,
            weights: laneWeights ?? savedLengths(along: vertical, extent: extent),
            minima: Array(repeating: 0, count: items.count))
        return snapshot(lengths: lengths, along: vertical)
    }

    private func snapshot(lengths: [CGFloat], along vertical: Bool) -> PaneLayout {
        guard axis == vertical else { return snapshot }
        let count = branches[0].lanes(along: vertical).count
        let first = Array(lengths.prefix(count)), second = Array(lengths.dropFirst(count))
        let content = lengths.reduce(0, +) + CGFloat(lengths.count - 2) * divider
        let position = first.reduce(0, +) + CGFloat(count - 1) * divider
        return .split(vertical: vertical, fraction: content > 0 ? Double(position / content) : fraction,
            first: branches[0].snapshot(lengths: first, along: vertical),
            second: branches[1].snapshot(lengths: second, along: vertical))
    }

    /// Topology changes rebalance both axes, including perpendicular subgroups.
    func balance() {
        func equalize(_ node: PaneLayoutController) {
            if let vertical = node.axis { node.laneWeights = Array(repeating: 1, count: node.lanes(along: vertical).count) }
            node.branches.forEach(equalize)
        }
        equalize(root)
        root.restoreFractions()
    }

    func clearPreviews() {
        (view as? TabSplitHostView)?.clearPreview()
        branches.forEach { $0.clearPreviews() }
    }
}
