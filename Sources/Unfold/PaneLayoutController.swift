import AppKit

/// The pane dividers keep their native appearance and accessibility, but a drag
/// is tracked in the whole row/column's coordinates, not a moving nested pair.
@MainActor
private final class PaneSplitView: NSSplitView {
    var positionRequested: ((CGFloat) -> Void)?
    var beginDrag: ((NSPoint) -> ((NSPoint) -> Void)?)?
    private var arranging = false

    override var dividerColor: NSColor {
        InterfaceStyle.hasRoundedPanes ? FeedPalette.backdrop : super.dividerColor
    }
    /// Between cards the divider is only a gap: paint it as the backdrop in
    /// both appearances rather than as AppKit's dark hairline.
    override func drawDivider(in rect: NSRect) {
        guard InterfaceStyle.hasRoundedPanes else { super.drawDivider(in: rect); return }
        FeedPalette.backdrop.setFill(); rect.fill()
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
        guard newSize != frame.size else { return }
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
    private var firstExtent: NSLayoutConstraint?
    private let resized: () -> Void
    private var arranging = false
    private var lastSize = NSSize.zero
    /// Completed arrangements let a canvas growth request detect that its
    /// callback already laid out the tree, without repeating the same work.
    private(set) var layoutRevision: UInt64 = 0
    /// Set on the root by a scrolling pane area: the smallest size for every
    /// pane there. Without it a pane never goes below its comfortable minimum
    /// or its own fitting size.
    var paneMinimum: NSSize?
    /// Explicit divider drags may ask the scrolling canvas for more room.
    var requestCanvasExtent: ((Bool, CGFloat) -> Void)?
    /// Set on the root by a scrolling pane area. A column divider then sizes
    /// one column and the canvas takes exactly the width the columns need.
    var resizeCanvasWidth: ((CGFloat) -> Void)?
    /// The width columns must still cover; zero when they may occupy less.
    var columnFillWidth: (() -> CGFloat)?
    var beginManualResize: (() -> Void)?

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
            // The split tree owns host geometry. Keep the expensive column's
            // frame independent until that geometry has settled for this pass.
            host.autoresizesSubviews = false
            host.onLayout = { [weak self] in self?.resizeIfNeeded() }
            column.view.translatesAutoresizingMaskIntoConstraints = true
            column.view.autoresizingMask = []
            host.addSubview(column.view, positioned: .below, relativeTo: nil)
        case .split(let vertical, let value, let first, let second):
            buildSplit(vertical: vertical, fraction: value)
            for child in [first, second] {
                attach(PaneLayoutController(layout: child, columns: columns, configureHost: configureHost, resized: resized))
            }
        }
        applyInterfaceStyle()
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    /// A split around branches that already exist, for changing the tree in place.
    private init(vertical: Bool, branches existing: [PaneLayoutController], resized: @escaping () -> Void) {
        model = .split(vertical: vertical, fraction: 0.5, first: existing[0].model, second: existing[1].model)
        self.resized = resized
        super.init(nibName: nil, bundle: nil)
        buildSplit(vertical: vertical, fraction: 0.5)
        existing.forEach(attach)
        applyInterfaceStyle()
    }

    private func buildSplit(vertical: Bool, fraction value: Double) {
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
        splitView.positionRequested = { [weak self] position in self?.moveDivider(to: position) }
        splitView.beginDrag = { [weak self] point in self?.beginDividerDrag(at: point) }
    }

    private func attach(_ branch: PaneLayoutController) {
        branch.layoutParent = self
        branches.append(branch)
        split?.addSplitViewItem(NSSplitViewItem(viewController: branch))
    }

    private func leaf(_ id: UUID) -> PaneLayoutController? {
        if split == nil {
            if case .pane(let value) = model, value == id { return self }
            return nil
        }
        for branch in branches { if let found = branch.leaf(id) { return found } }
        return nil
    }

    /// Add a pane beside an existing one without rebuilding the tree. Every
    /// other pane keeps its views and its layout, so this stays quick however
    /// many panes there are. Returns false when the tree must be rebuilt
    /// instead (the target is the only pane). Follow with `balance()` or restore
    /// captured widths when the user has sized the workspace themselves.
    func insertPane(_ column: ChatColumn, beside target: UUID, vertical: Bool, leading: Bool,
                    configureHost: (TabSplitHostView, ChatColumn) -> Void) -> Bool {
        guard layoutParent == nil, let existing = leaf(target), let parent = existing.layoutParent,
              let index = parent.branches.firstIndex(where: { $0 === existing }), let container = parent.split,
              container.splitViewItems.indices.contains(index) else { return false }
        let added = PaneLayoutController(layout: .pane(column.columnID), columns: [column.columnID: column],
                                         configureHost: configureHost, resized: resized)
        container.removeSplitViewItem(container.splitViewItems[index])
        let node = PaneLayoutController(vertical: vertical, branches: leading ? [added, existing] : [existing, added], resized: resized)
        node.layoutParent = parent
        parent.branches[index] = node
        container.insertSplitViewItem(NSSplitViewItem(viewController: node), at: index)
        equalizeWeights()
        return true
    }

    /// Restore measured host widths after insertion, before fitting the canvas.
    /// Vertical stacks share a width; horizontal lanes each keep their own.
    /// Return the required space so the caller can scroll instead of squeezing.
    func preserveWidths(_ widths: [UUID: CGFloat]) -> CGFloat {
        var measured: [ObjectIdentifier: CGFloat] = [:]
        func measure(_ node: PaneLayoutController) -> CGFloat {
            let width: CGFloat
            if let vertical = node.axis {
                let first = measure(node.branches[0]), second = measure(node.branches[1])
                width = vertical ? first + node.divider + second : max(first, second)
            } else if case .pane(let id) = node.model {
                width = widths[id] ?? node.view.bounds.width
            } else { width = node.view.bounds.width }
            measured[ObjectIdentifier(node)] = width
            return width
        }
        let required = measure(self)
        func apply(_ node: PaneLayoutController) {
            if node.axis == true {
                node.laneWeights = node.lanes(along: true).map { measured[ObjectIdentifier($0)]! }
            }
            node.branches.forEach(apply)
        }
        apply(self)
        return required
    }

    /// Remove a pane in place; its sibling takes over their shared space.
    /// Returns false when the tree must be rebuilt (the pane's parent is the root).
    func removePane(_ id: UUID) -> Bool {
        guard layoutParent == nil, let closing = leaf(id), let parent = closing.layoutParent, let grand = parent.layoutParent,
              let index = parent.branches.firstIndex(where: { $0 === closing }),
              let slot = grand.branches.firstIndex(where: { $0 === parent }),
              let outer = grand.split, let inner = parent.split,
              inner.splitViewItems.count == 2, outer.splitViewItems.indices.contains(slot) else { return false }
        let survivor = parent.branches[1 - index]
        inner.removeSplitViewItem(inner.splitViewItems[1 - index])
        outer.removeSplitViewItem(outer.splitViewItems[slot])
        survivor.layoutParent = grand
        grand.branches[slot] = survivor
        outer.insertSplitViewItem(NSSplitViewItem(viewController: survivor), at: slot)
        equalizeWeights()
        return true
    }

    private var root: PaneLayoutController { layoutParent?.root ?? self }
    private var axis: Bool? { split?.splitView.isVertical }
    private var extent: CGFloat {
        guard let split else { return 0 }
        return split.splitView.isVertical ? split.splitView.bounds.width : split.splitView.bounds.height
    }
    private var divider: CGFloat { split?.splitView.dividerThickness ?? 1 }
    var minimumSize: NSSize {
        minimumSize(paneMinimum: root.paneMinimum)
    }
    func minimumSize(paneMinimum: NSSize?) -> NSSize {
        if let vertical = axis {
            let a = branches[0].minimumSize(paneMinimum: paneMinimum)
            let b = branches[1].minimumSize(paneMinimum: paneMinimum)
            return vertical ? NSSize(width: a.width + b.width + divider, height: max(a.height, b.height))
                : NSSize(width: max(a.width, b.width), height: a.height + b.height + divider)
        }
        let inset = InterfaceStyle.hasRoundedPanes ? 2 * PaneSurface.inset : 0
        if let minimum = paneMinimum {
            // Panes compact their own chrome and text to fit this floor.
            return NSSize(width: minimum.width + inset, height: minimum.height + inset)
        }
        let fitting = children.first?.view.fittingSize ?? .zero
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
        if split == nil { fitPaneContents() }
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
        // Hosts may pass through several intermediate sizes while nested
        // dividers settle. Their columns keep their previous frames throughout.
        owner.view.layoutSubtreeIfNeeded()
        owner.layoutTree()
        // The last nested divider may leave its first host waiting for a
        // frame update. Flush host geometry before applying column frames.
        owner.view.layoutSubtreeIfNeeded()
        owner.fitPaneContents()
        owner.view.layoutSubtreeIfNeeded()
        owner.lastSize = owner.view.bounds.size
        owner.layoutRevision &+= 1
        owner.resized()
    }

    private func fitPaneContents() {
        if split == nil, let column = children.first as? ChatColumn,
           view.bounds.width > 0, view.bounds.height > 0 {
            let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
            let frame = NSRect(x: inset, y: inset,
                               width: max(0, view.bounds.width - 2 * inset),
                               height: max(0, view.bounds.height - 2 * inset))
            column.setDensity(PaneDensity.resolve(size: frame.size, current: column.density))
            if column.view.frame != frame { column.view.frame = frame }
        }
        branches.forEach { $0.fitPaneContents() }
    }

    /// False until the tree has been laid out for its current size at least once.
    var isArranged: Bool { root.lastSize == root.view.bounds.size && root.lastSize != .zero }

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
        // setPosition alone is only a request: nested split views can let their
        // content constraints take the space back on the next layout pass.
        // Keep the computed share authoritative, below the required outer size.
        let firstView = branches[0].view
        if firstExtent?.firstItem as? NSView !== firstView {
            firstExtent?.isActive = false
            firstExtent = vertical ? firstView.widthAnchor.constraint(equalToConstant: position)
                : firstView.heightAnchor.constraint(equalToConstant: position)
            firstExtent?.identifier = "paneFirstExtent"
            firstExtent?.priority = .init(999)
            firstExtent?.isActive = true
        }
        firstExtent?.constant = position
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
        if run.axis == true, root.resizeCanvasWidth != nil {
            // Measure from where the drag began so it retraces exactly, and in
            // window coordinates: the canvas can scroll as its width changes.
            let widths = root.paneWidths()
            return { [weak run] current in run?.resizeColumn(at: index, by: current.x - point.x, from: widths) }
        }
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
        if run.axis == true, root.resizeCanvasWidth != nil {
            run.resizeColumn(at: index, by: position - firstLength, from: root.paneWidths())
            return
        }
        run.redistribute(at: index, coordinate: dividerCoordinate(in: run) + position - firstLength)
    }

    /// Only the two lanes at the grabbed boundary trade space; a lane at its
    /// minimum passes the remainder to the next one. Every other lane keeps its
    /// size. Matching runs in other rows/columns use the same sizes so a grid
    /// stays aligned while either axis is dragged.
    private func redistribute(at index: Int, coordinate: CGFloat) {
        let owner = root
        guard !owner.arranging, coordinate.isFinite, let vertical = axis else { return }
        let items = lanes(along: vertical)
        guard index > 0, index < items.count else { return }
        // Measure before the canvas can grow and rescale every lane.
        var lengths = items.map { vertical ? $0.view.bounds.width : $0.view.bounds.height }
        owner.beginManualResize?()
        var minima = items.map { vertical ? $0.minimumSize.width : $0.minimumSize.height }
        let requested = coordinate - CGFloat(index - 1) * divider
        let available = max(0, extent - CGFloat(items.count - 1) * divider)
        let extra = requested + minima.dropFirst(index).reduce(0, +) - available
        if extra > 0, extent > 0, let request = owner.requestCanvasExtent {
            let rootExtent = vertical ? owner.view.bounds.width : owner.view.bounds.height
            request(vertical, rootExtent + extra * rootExtent / extent)
        }
        let total = max(0, extent - CGFloat(items.count - 1) * divider)
        let minimum = minima.reduce(0, +)
        if minimum > total { minima = minima.map { $0 * total / minimum } }
        let low = minima.prefix(index).reduce(0, +)
        let high = total - minima.dropFirst(index).reduce(0, +)
        let before = min(high, max(low, requested))
        let change = before - lengths.prefix(index).reduce(0, +)
        var owed = abs(change)
        lengths[change >= 0 ? index - 1 : index] += owed
        for lane in change >= 0 ? Array(index..<items.count) : Array((0..<index).reversed()) where owed > 0 {
            let given = min(owed, max(0, lengths[lane] - minima[lane]))
            lengths[lane] -= given
            owed -= given
        }
        // Match the axis span, not only the lane count: independent inset groups
        // must not move just because they happen to contain the same number.
        let span = axisSpan(in: owner)
        owner.synchronizeRuns(along: vertical, span: span, weights: lengths, in: owner)
        owner.restoreFractions()
    }

    private func paneWidths() -> [ObjectIdentifier: CGFloat] {
        guard split != nil else { return [ObjectIdentifier(self): view.bounds.width] }
        return branches.reduce(into: [:]) { $0.merge($1.paneWidths()) { first, _ in first } }
    }

    /// A column divider sizes the column before it and nothing else: the
    /// columns after it keep their widths and move, and the canvas grows or
    /// shrinks to match. Only when the columns would stop covering the pane
    /// area does the next column take up the slack. Aligned rows of a grid
    /// follow; `delta` is measured from the widths in `start`.
    private func resizeColumn(at index: Int, by delta: CGFloat, from start: [ObjectIdentifier: CGFloat]) {
        let owner = root
        let count = lanes(along: true).count
        guard !owner.arranging, delta.isFinite, index > 0, index < count else { return }
        owner.beginManualResize?()
        let span = axisSpan(in: owner)
        var resized = Set<ObjectIdentifier>(), following = Set<ObjectIdentifier>()
        func findLanes(_ node: PaneLayoutController) {
            if node.axis == true {
                let items = node.lanes(along: true)
                let ownSpan = node.axisSpan(in: owner)
                if items.count == count, abs(ownSpan.0 - span.0) < 1, abs(ownSpan.1 - span.1) < 1 {
                    resized.insert(ObjectIdentifier(items[index - 1]))
                    following.insert(ObjectIdentifier(items[index]))
                }
                items.forEach(findLanes)
            } else {
                node.branches.forEach(findLanes)
            }
        }
        findLanes(owner)
        var widths: [ObjectIdentifier: CGFloat] = [:]
        @discardableResult
        func capture(_ node: PaneLayoutController, slack: CGFloat, extra: CGFloat = 0) -> CGFloat {
            let id = ObjectIdentifier(node)
            let addition = extra + (resized.contains(id) ? delta : 0) + (following.contains(id) ? slack : 0)
            let width: CGFloat
            if let vertical = node.axis {
                let first = capture(node.branches[0], slack: slack, extra: vertical ? 0 : addition)
                let second = capture(node.branches[1], slack: slack, extra: addition)
                width = vertical ? first + node.divider + second : max(first, second)
            } else {
                let original = start[id] ?? node.view.bounds.width
                width = addition < 0 ? max(min(original, node.minimumSize.width), original + addition)
                    : original + addition
            }
            widths[id] = width
            return width
        }
        var width = capture(owner, slack: 0)
        let fill = owner.columnFillWidth?() ?? 0
        if width < fill - 0.5 { width = capture(owner, slack: fill - width) }
        func saveWidths(_ node: PaneLayoutController) {
            if node.axis == true {
                let items = node.lanes(along: true)
                node.laneWeights = items.map { widths[ObjectIdentifier($0)]! }
                items.forEach(saveWidths)
            } else {
                node.branches.forEach(saveWidths)
            }
        }
        saveWidths(owner)
        let revision = owner.layoutRevision
        owner.resizeCanvasWidth?(width)
        if owner.layoutRevision == revision { owner.restoreFractions() }
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
        root.equalizeWeights()
        root.restoreFractions()
    }

    private func equalizeWeights() {
        if let vertical = axis { laneWeights = Array(repeating: 1, count: lanes(along: vertical).count) }
        branches.forEach { $0.equalizeWeights() }
    }

    /// Every pane's host view, in layout order.
    var paneViews: [NSView] {
        split == nil ? [view] : branches.flatMap(\.paneViews)
    }

    /// Stacked panes share a column; side-by-side branches add columns.
    var columnCount: Int {
        guard let vertical = axis else { return 1 }
        return vertical ? branches.reduce(0) { $0 + $1.columnCount }
            : branches.map(\.columnCount).max() ?? 1
    }

    func clearPreviews() {
        (view as? TabSplitHostView)?.clearPreview()
        branches.forEach { $0.clearPreviews() }
    }
}
