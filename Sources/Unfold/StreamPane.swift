import AppKit
import WebKit

/// Virtualized native AppKit feed. WebKit is created only for authored HTML.
@MainActor
final class StreamPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let status = NSTextField(labelWithString: "Ready")
    private let follow = NSButton(checkboxWithTitle: "Follow live", target: nil, action: nil)
    private let search = NSSearchField()
    private let searchRow = NSStackView()
    private let table = NSTableView()
    private let scroll = NativeFeedScrollView()
    private lazy var scrollMotion = FeedScrollMotion(scroll)
    private let highlights = FeedHighlightsView(frame: .zero)
    private let navigatorSplit = FeedNavigatorSplitView()
    private let rain = MatrixRainView(frame: .zero)
    private let highlightQueue = DispatchQueue(label: "app.unfold.highlights", qos: .userInitiated)
    private var highlightEntries: [Int: [FeedHighlight]] = [:]
    private var highlightGeneration = 0
    private var highlightScheduled = false
    private var pendingHighlightStart: Int?
    private var feed = FeedBuffer()
    private var batch: [(StreamRecord, Bool)] = []
    private var scheduled = false
    private var rendered: [Int: [NativeFeedBlock]] = [:]
    private var textReveals: [Int: StreamTextReveal] = [:]
    private var heights: [Int: CGFloat] = [:]
    private var pendingHeightRows = IndexSet()
    private var heightUpdateScheduled = false
    private var lastViewportSize = NSSize.zero
    private var resizing = false
    private var resizeAnchor: (text: FeedTextScrollAnchor?, row: Int, offset: CGFloat)?
    private var resizeAnchorExpiry: DispatchWorkItem?
    private var analyses: [String: PythonAnalysis] = [:]
    private var pendingPython = Set<String>()
    private var pythonRows: [String: Set<Int>] = [:]
    private var deferredAnalysis: [Int: DispatchWorkItem] = [:]
    private var images: [String: NSImage] = [:]
    private var pendingImages = Set<String>()
    private var imageFailures = Set<String>()
    private var imageRows: [String: Set<Int>] = [:]
    private var positionObserver: NSObjectProtocol?
    private var restoringPosition = false
    private var pendingViewState: StreamViewState?
    private var viewStateGeneration = 0
    private var followingLatest = false
    private var updatingRows = false
    private var liveFocus: FeedHighlight?
    private var liveFocusTimer: DispatchWorkItem?
    private var liveFocusKey: String?
    private var liveSequence = FeedLiveFocusSequence()
    var liveFocusDuration: ((FeedHighlight) -> TimeInterval)?
    var focusedLiveObject: FeedHighlight? { liveFocus }
    private var liveHighlightRows = Set<Int>()
    var onViewStateChanged: ((StreamViewState) -> Void)?
    private var size: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "unfold.stream.fontSize")
        return saved == 0 ? 16 : min(28, max(8, saved))
    }()
    private let smallerText = NSButton(title: "−", target: nil, action: nil)
    private let largerText = NSButton(title: "+", target: nil, action: nil)
    private let sizeButton = NSButton(title: "16", target: nil, action: nil)
    private var previews: [NSWindowController] = []
    var onSelection: ((String) -> Void)?
    var onConversationAppend: ((StreamRecord, Bool) -> Void)?
    var onConversationReplace: (([StreamRecord]) -> Void)?
    var onConversationQueueUpdate: (([StreamRecord]) -> Void)?
    var onConversationFinalize: ((StreamRecord) -> Void)?
    var projectDirectory: URL?
    var records: [StreamRecord] { feed.records }
    func setCanvasColor(_ color: NSColor) {
        loadViewIfNeeded()
        // Matrix leaves the feed transparent over its rain.
        table.backgroundColor = InterfaceStyle.isMatrix ? .clear : color
        (view.subviews.first { $0 is ChatControlBar } as? ChatControlBar)?.fill = color
    }
    override func loadView() {
        let container = FeedResizeContainer()
        container.onWillResize = { [weak self] in self?.captureResizeAnchor() }
        view = container
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feed")))
        table.headerView = nil; table.style = .plain; table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero; table.backgroundColor = FeedPalette.canvas
        table.delegate = self; table.dataSource = self; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Native conversation and live activity")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.onWillResize = { [weak self] in self?.captureResizeAnchor() }
        scroll.onUserScroll = { [weak self] in self?.resetResizeAnchor() }
        scroll.onScrollUp = { [weak self] in self?.resetResizeAnchor(); self?.clearLiveFocus(); self?.scrollMotion.cancel(); self?.follow.state = .off; self?.publishViewState() }
        scroll.contentView.postsBoundsChangedNotifications = true
        highlights.onJump = { [weak self] in self?.jump(to: $0) }
        highlights.onLatest = { [weak self] in
            self?.resumeLiveActivity()
        }
        positionObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self, !self.resizing, self.resizeAnchorExpiry == nil, self.follow.state == .off {
                    self.resizeAnchor = nil
                    self.captureResizeAnchor()
                }
                self?.publishViewState()
            }
        }
        follow.state = .on; follow.target = self; follow.action = #selector(followChanged)
        follow.font = Typography.caption
        status.font = Typography.caption; status.textColor = FeedPalette.muted
        status.lineBreakMode = .byTruncatingTail
        status.allowsExpansionToolTips = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.placeholderString = "Find in activity"; search.delegate = self
        search.font = Typography.interface
        search.setAccessibilityLabel("Find in activity")
        search.target = self; search.action = #selector(findNext)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let closeSearch = NSButton(title: "Done", target: self, action: #selector(dismissSearch))
        closeSearch.bezelStyle = .rounded; closeSearch.font = Typography.caption
        closeSearch.setAccessibilityLabel("Close find bar")
        searchRow.orientation = .horizontal; searchRow.alignment = .centerY; searchRow.spacing = 8
        searchRow.addArrangedSubview(search); searchRow.addArrangedSubview(closeSearch)
        searchRow.isHidden = true
        let selection = NSButton(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Ask about selection")!, target: self, action: #selector(askSelection))
        selection.toolTip = "Ask about selected text"
        smallerText.target = self; smallerText.action = #selector(decreaseFont)
        smallerText.toolTip = "Smaller text (⌘−)"; smallerText.setAccessibilityLabel("Smaller text")
        largerText.target = self; largerText.action = #selector(increaseFont)
        largerText.toolTip = "Larger text (⌘+)"; largerText.setAccessibilityLabel("Larger text")
        sizeButton.target = self; sizeButton.action = #selector(resetFont)
        sizeButton.toolTip = "Reset text size to 16"; sizeButton.setAccessibilityLabel("Reset text size")
        for button in [smallerText, sizeButton, largerText, selection] {
            button.bezelStyle = .texturedRounded; button.controlSize = .small
            button.font = Typography.caption
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        sizeButton.font = Typography.counter
        selection.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let sizes = NSStackView(views: [smallerText, sizeButton, largerText]); sizes.spacing = 4
        smallerText.widthAnchor.constraint(equalToConstant: 24).isActive = true
        largerText.widthAnchor.constraint(equalToConstant: 24).isActive = true
        sizeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let bar = NSStackView(views: [status, NSView(), selection, sizes, follow])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 8
        let rows = NSStackView(views: [bar, searchRow])
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        let controlBar = ChatControlBar()
        controlBar.setAccessibilityElement(true)
        controlBar.setAccessibilityRole(.group)
        controlBar.setAccessibilityLabel("Chat control bar")
        rows.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(rows)
        refreshFontControls()
        navigatorSplit.addArrangedSubview(highlights)
        navigatorSplit.addArrangedSubview(scroll)
        navigatorSplit.onResize = { [weak self] in
            guard let self else { return }
            self.view.needsLayout = true
            self.view.layoutSubtreeIfNeeded()
            self.publishViewState()
        }
        rain.alphaValue = 0.5
        for child in [controlBar, rain, navigatorSplit] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        rain.isRaining = InterfaceStyle.isMatrix
        NSLayoutConstraint.activate([
            rain.topAnchor.constraint(equalTo: navigatorSplit.topAnchor), rain.bottomAnchor.constraint(equalTo: navigatorSplit.bottomAnchor), rain.leadingAnchor.constraint(equalTo: navigatorSplit.leadingAnchor), rain.trailingAnchor.constraint(equalTo: navigatorSplit.trailingAnchor),
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor), controlBar.topAnchor.constraint(equalTo: view.topAnchor),
            rows.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: PaneSpacing.textInset), rows.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -PaneSpacing.textInset), rows.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: 4), rows.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: -4),
            bar.widthAnchor.constraint(equalTo: rows.widthAnchor), bar.heightAnchor.constraint(equalToConstant: PaneSpacing.controlHeight),
            searchRow.widthAnchor.constraint(equalTo: rows.widthAnchor), searchRow.heightAnchor.constraint(equalToConstant: PaneSpacing.controlHeight),
            navigatorSplit.topAnchor.constraint(equalTo: controlBar.bottomAnchor), navigatorSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor), navigatorSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor), navigatorSplit.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let viewportSize = scroll.contentSize
        guard viewportSize != lastViewportSize, !resizing else { return }
        captureResizeAnchor()
        let widthChanged = abs(viewportSize.width - lastViewportSize.width) > 0.5
        lastViewportSize = viewportSize
        resizing = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        defer { NSAnimationContext.endGrouping(); resizing = false }
        scrollMotion.cancel()
        if widthChanged {
            table.sizeLastColumnToFit()
            var changed = IndexSet()
            // Offscreen heights remain estimates until those rows appear.
            // Reflow only instantiated views; never reload the table on resize.
            table.enumerateAvailableRowViews { rowView, row in
                guard let content = rowView.view(atColumn: 0) as? NativeFeedRow else { return }
                let height = content.reflow(width: self.contentWidth, images: self.images)
                if self.heights[row] != height { self.heights[row] = height; changed.insert(row) }
            }
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        }
        table.layoutSubtreeIfNeeded()
        if follow.state == .on, liveFocus == nil, !hasSelection {
            followLatest(animated: false)
            resizeAnchor = nil
        } else if let anchor = resizeAnchor, records.indices.contains(anchor.row) {
            let y = anchor.text?.position(in: table) ?? (table.rect(ofRow: anchor.row).minY + anchor.offset)
            scrollTo(y: y)
        }
        // Keep one character anchor through AppKit's intermediate geometry
        // changes, then resume tracking deliberate scrolling once it settles.
        resizeAnchorExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.resizeAnchorExpiry = nil }
        resizeAnchorExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: expiry)
    }
    private func captureResizeAnchor() {
        guard !resizing, !records.isEmpty else { return }
        let viewport = scroll.documentVisibleRect
        if resizeAnchor?.text?.isAttached(to: table) == false { resizeAnchor = nil }
        guard resizeAnchor == nil else { return }
        let row = table.row(at: NSPoint(x: 1, y: viewport.minY))
        guard records.indices.contains(row) else { return }
        resizeAnchor = (FeedTextScrollAnchor(document: table, viewport: viewport), row,
                        viewport.minY - table.rect(ofRow: row).minY)
    }
    private func resetResizeAnchor() {
        resizeAnchor = nil; resizeAnchorExpiry?.cancel(); resizeAnchorExpiry = nil
    }
    private var contentWidth: CGFloat { max(120, scroll.contentSize.width) }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let height = heights[row] { return height }
        // AppKit asks for every row's height during scrolling. Never parse or
        // typeset offscreen history from this callback.
        let count = records[row].text.utf8.count
        let columns = max(24, Int(contentWidth / max(5, size * 0.6)))
        return max(70, min(30_000, CGFloat(count / columns + 2) * size * 1.4 + 40))
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let content = blocks(row)
        // The row measures its blocks while building; don't typeset them twice.
        let view = NativeFeedRow(blocks: content, width: contentWidth, images: images, reveal: textReveals[row],
                                 accent: rowAccent(row),
                                 openHTML: { [weak self] in self?.showHTML($0) }, openImage: { [weak self] in self?.showImage($0) })
        if heights[row] != view.contentHeight {
            heights[row] = view.contentHeight
            scheduleHeightUpdate(row)
        }
        return view
    }
    private func scheduleHeightUpdate(_ row: Int) {
        guard !updatingRows else { return }
        pendingHeightRows.insert(row)
        guard !heightUpdateScheduled else { return }
        heightUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightUpdateScheduled = false
            let changed = IndexSet(self.pendingHeightRows.filter {
                self.records.indices.contains($0) &&
                abs(self.table.rect(ofRow: $0).height - (self.heights[$0] ?? self.table.rect(ofRow: $0).height)) > 0.5
            })
            self.pendingHeightRows.removeAll()
            guard !changed.isEmpty else { return }
            let keepPosition = self.follow.state == .off || self.hasSelection || self.liveFocus != nil
            let anchor = keepPosition ? FeedTextScrollAnchor(document: self.table, viewport: self.scroll.documentVisibleRect) : nil
            let oldY = self.scroll.documentVisibleRect.minY
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; context.allowsImplicitAnimation = false
                self.table.noteHeightOfRows(withIndexesChanged: changed)
                self.table.layoutSubtreeIfNeeded()
                if keepPosition {
                    let resizeY = self.resizeAnchorExpiry != nil ? self.resizeAnchor?.text?.position(in: self.table) : nil
                    self.scrollTo(y: resizeY ?? anchor?.position(in: self.table) ?? oldY)
                } else { self.followLatest(animated: self.resizeAnchorExpiry == nil) }
            }
        }
    }
    private func blocks(_ row: Int) -> [NativeFeedBlock] {
        if let value = rendered[row] { return value }
        guard records.indices.contains(row) else { return [] }
        var renderer = NativeFeedRenderer(size: size, analyses: analyses)
        var value = renderer.render(records[row])
        let requests = renderer.requestedCode
        deferredAnalysis.removeValue(forKey: row)?.cancel()
        if textReveals[row] != nil, !requests.isEmpty {
            // A streaming code block changes on every flush. Lint the source
            // once it settles instead of launching a linter for each version.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.deferredAnalysis[row] = nil
                requests.forEach { self.analyze($0, row: row) }
            }
            deferredAnalysis[row] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        } else {
            requests.forEach { analyze($0, row: row) }
        }
        for (index, block) in value.enumerated() {
            guard case .image(let reference) = block else { continue }
            let key = reference.source
            imageRows[key, default: []].insert(row)
            if imageFailures.contains(key) {
                value[index] = .text(NSAttributedString(string: "Image unavailable", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])); continue
            }
            guard images[key] == nil, pendingImages.insert(key).inserted else { continue }
            let project = projectDirectory
            Task { [weak self] in
                let data = try? await NativeImageStore.shared.data(for: reference, project: project)
                guard let self else { return }
                if let data, let image = NSImage(data: data) { self.images[key] = image }
                else { self.imageFailures.insert(key) }
                self.pendingImages.remove(key); self.refreshRows(self.imageRows[key] ?? [])
            }
        }
        rendered[row] = value
        return value
    }
    private func analyze(_ request: CodeAnalysisRequest, row: Int) {
        let key = request.key
        pythonRows[key, default: []].insert(row)
        guard analyses[key] == nil, pendingPython.insert(key).inserted else { return }
        Task { [weak self] in
            let result = await CodeAnalysisService.shared.analyze(request)
            guard let self else { return }
            self.analyses[key] = result; self.pendingPython.remove(key)
            self.refreshRows(self.pythonRows[key] ?? [])
        }
    }
    private func rowAccent(_ row: Int) -> NSColor? {
        records[row].kind == StreamKind.reasoning.rawValue ? FeedPalette.purple :
            liveFocus?.record == row || records[row].kind == StreamKind.change.rawValue ? FeedPalette.green :
            records[row].isFinalResponse == true ? FeedPalette.blue : nil
    }
    private func refreshRows(_ rows: Set<Int>) {
        updateRows(IndexSet(rows.filter { records.indices.contains($0) }))
    }
    /// Measure once, update existing views, then publish one geometry change.
    /// AppKit must never see an estimated height between two versions of a row.
    private func updateRows(_ rows: IndexSet, insertingFrom oldCount: Int? = nil) {
        guard !rows.isEmpty else { return }
        let viewport = scroll.documentVisibleRect
        let keepPosition = follow.state == .off || hasSelection || liveFocus != nil
        let anchor = keepPosition ? FeedTextScrollAnchor(document: table, viewport: viewport) : nil
        let firstRow = table.row(at: NSPoint(x: 1, y: viewport.minY))
        let offset = firstRow >= 0 ? viewport.minY - table.rect(ofRow: firstRow).minY : 0
        updatingRows = true
        defer { updatingRows = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            for row in rows {
                rendered.removeValue(forKey: row)
                let content = blocks(row)
                if oldCount == nil || row < oldCount! {
                    if let existing = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeFeedRow {
                        heights[row] = existing.update(blocks: content, width: contentWidth, images: images,
                                                       reveal: textReveals[row], accent: rowAccent(row))
                        continue
                    }
                }
                heights[row] = rowHeight(content)
            }
            if let oldCount, records.count > oldCount {
                table.beginUpdates()
                table.insertRows(at: IndexSet(integersIn: oldCount..<records.count), withAnimation: [])
                table.endUpdates()
            }
            table.noteHeightOfRows(withIndexesChanged: rows)
            table.layoutSubtreeIfNeeded()
            if keepPosition {
                let fallback = firstRow >= 0 && firstRow < table.numberOfRows ? table.rect(ofRow: firstRow).minY + offset : viewport.minY
                scrollTo(y: anchor?.position(in: table) ?? fallback)
            } else { followLatest() }
        }
    }
    func append(_ record: StreamRecord, item: String? = nil, delta: Bool = false) {
        loadViewIfNeeded(); var value = record; value.itemID = item ?? value.itemID
        batch.append((value, delta))
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in self?.flush() }
    }
    private func flush() {
        scheduled = false; let values = batch; batch.removeAll(keepingCapacity: true)
        guard !values.isEmpty else { return }
        let oldCount = records.count
        let now = ProcessInfo.processInfo.systemUptime
        textReveals = textReveals.filter { now - $0.value.lastArrival < 1 }
        // Capture the existing tail before merging, so history stays fully inked.
        let tailBaseline = oldCount > 0 ? blocks(oldCount - 1) : []
        var start = oldCount
        // The conversation view re-renders its whole tail per append. Hand it
        // one merged fragment per run of deltas rather than one per token.
        var conversation: [(StreamRecord, Bool)] = []
        for (record, delta) in values {
            if delta, let item = record.itemID, let last = conversation.last?.0,
               last.itemID == item, last.kind == record.kind, last.language == record.language {
                conversation[conversation.count - 1].0.text += record.text
            } else { conversation.append((record, delta)) }
            let row = feed.append(record, merging: delta)
            liveHighlightRows.insert(row)
            start = min(start, row)
            if record.kind != StreamKind.user.rawValue && record.kind != StreamKind.system.rawValue {
                rain.feed(record.text)
                let reveal = textReveals[row] ?? StreamTextReveal(baseline: row < oldCount ? tailBaseline : [])
                reveal.lastArrival = now
                textReveals[row] = reveal
            }
        }
        for (record, delta) in conversation { onConversationAppend?(record, delta) }
        updateRows(IndexSet(integersIn: start..<records.count), insertingFrom: oldCount)
        scheduleHighlights(from: start)
    }
    private func rowHeight(_ content: [NativeFeedBlock]) -> CGFloat {
        20 + content.reduce(CGFloat(0)) { $0 + NativeFeedLayout.height($1, width: contentWidth - 28, images: images) } + CGFloat(max(0, content.count - 1)) * 8
    }
    private func followLatest(animated: Bool = true) {
        highlights.setFollowingLatest(follow.state == .on && liveFocus == nil)
        guard follow.state == .on, !records.isEmpty, !hasSelection, !followingLatest else { return }
        followingLatest = true
        defer { followingLatest = false }
        if let liveFocus {
            // A held block keeps its viewport as content grows. Repositioning
            // and re-running its text search on every packet causes two jumps.
            highlights.markFocused(liveFocus)
            return
        }
        // The index will choose the next object. Do not briefly jump to the
        // data tail while its background classification is still pending.
        guard liveHighlightRows.isEmpty else { return }
        // Measure only the tail that will fill the viewport before jumping. Using
        // estimated heights here otherwise makes a long feed settle in steps.
        var remaining = max(1, scroll.contentSize.height)
        var changed = IndexSet()
        for row in records.indices.reversed() {
            let height = heights[row] ?? rowHeight(blocks(row))
            if heights[row] != height { heights[row] = height; changed.insert(row) }
            remaining -= height
            if remaining <= 0 { break }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
            table.layoutSubtreeIfNeeded()
        }
        let bottom = max(0, table.rect(ofRow: records.count - 1).maxY - scroll.contentSize.height)
        scrollMotion.move(to: bottom, animated: animated)
    }
    func resumeLiveActivity(animated: Bool = false) {
        resetResizeAnchor()
        loadViewIfNeeded()
        // A new submission supersedes an older tab-position restoration and
        // any activity-reading pause, including pending highlight work.
        viewStateGeneration += 1
        pendingViewState = nil; restoringPosition = false
        clearLiveFocus()
        liveHighlightRows.removeAll()
        scrollMotion.cancel()
        follow.state = .on
        if let text = view.window?.firstResponder as? NativeFeedTextView, text.isDescendant(of: view) {
            text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0))
        }
        followLatest(animated: animated); publishViewState()
    }
    private var hasSelection: Bool {
        guard let text = view.window?.firstResponder as? NativeFeedTextView,
              text.isDescendant(of: view) else { return false }
        return text.selectedRange().length > 0
    }
    @objc private func followChanged() {
        if follow.state == .on { resumeLiveActivity() }
        else { clearLiveFocus(); scrollMotion.cancel(); publishViewState() }
    }
    @objc private func askSelection() {
        guard let text = view.window?.firstResponder as? NativeFeedTextView, text.isDescendant(of: view) else { return }
        let range = text.selectedRange(); guard range.length > 0 else { return }
        onSelection?((text.string as NSString).substring(with: range))
    }
    func updateQueuePresentation(_ outbox: MessageOutbox, records: [StreamRecord]? = nil) {
        if !batch.isEmpty { flush() }
        let previous = feed.records
        let updated = outbox.decorate(records ?? previous)
        guard previous != updated else { return }
        let unchanged = zip(previous, updated).prefix { $0 == $1 }.count
        let anchor = follow.state == .off ? FeedTextScrollAnchor(document: table, viewport: scroll.documentVisibleRect) : nil
        feed = FeedBuffer(updated)
        for row in unchanged..<max(previous.count, updated.count) {
            rendered.removeValue(forKey: row); heights.removeValue(forKey: row)
        }
        // Queue receipts affect the tail. Keep older row views and their exact
        // heights alive, so status changes cannot move the whole feed.
        for row in unchanged..<updated.count { heights[row] = rowHeight(blocks(row)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            if previous.count == updated.count {
                let changed = IndexSet(integersIn: unchanged..<updated.count)
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: changed)
            } else {
                table.beginUpdates()
                table.removeRows(at: IndexSet(integersIn: unchanged..<previous.count), withAnimation: [])
                table.insertRows(at: IndexSet(integersIn: unchanged..<updated.count), withAnimation: [])
                table.endUpdates()
            }
            table.layoutSubtreeIfNeeded()
        }
        onConversationQueueUpdate?(feed.records)
        if let y = anchor?.position(in: table) { scrollTo(y: y) }
        else { followLatest() }
    }
    func replace(_ values: [StreamRecord]) {
        resetResizeAnchor()
        clearLiveFocus(); liveHighlightRows.removeAll()
        loadViewIfNeeded(); scrollMotion.cancel(); batch.removeAll(); feed = FeedBuffer(values)
        onConversationReplace?(values)
        viewStateGeneration += 1; pendingViewState = nil; restoringPosition = false
        search.stringValue = ""; searchRow.isHidden = true
        follow.state = .on
        textReveals.removeAll()
        rendered.removeAll(); heights.removeAll(); pythonRows.removeAll(); imageRows.removeAll()
        deferredAnalysis.values.forEach { $0.cancel() }; deferredAnalysis.removeAll()
        highlightGeneration += 1; highlightEntries.removeAll(); highlights.reset()
        scheduleHighlights(from: 0)
        table.reloadData(); followLatest(animated: false)
    }
    func finalizeResponse(_ response: StreamRecord) {
        resetResizeAnchor()
        if !batch.isEmpty { flush() }
        let previous = viewState
        let focusedRecord = liveFocus.flatMap { records.indices.contains($0.record) ? records[$0.record] : nil }
        let unindexed = liveHighlightRows.compactMap { records.indices.contains($0) ? records[$0] : nil }
        let queuedRecords = liveSequence.pending.compactMap { object -> (String, FeedHighlight, StreamRecord)? in
            let entry = object.highlight
            return records.indices.contains(entry.record) ? (object.key, entry, records[entry.record]) : nil
        }
        let start = feed.finalizeResponse(response)
        func remap(_ entry: FeedHighlight, _ record: StreamRecord) -> FeedHighlight? {
            guard let row = records.firstIndex(where: { $0.kind == record.kind && ($0.text == record.text || (record.itemID != nil && $0.itemID == record.itemID)) }) else { return nil }
            var mapped = entry; mapped.record = row; return mapped
        }
        if let focusedRecord, let entry = liveFocus { liveFocus = remap(entry, focusedRecord) }
        var sequence = liveSequence
        sequence.remap { entry in
            guard let saved = queuedRecords.first(where: { $0.1.id == entry.id }) else { return nil }
            return remap(entry, saved.2)
        }
        liveSequence = sequence
        onConversationFinalize?(response)
        for row in start..<records.count { rendered.removeValue(forKey: row); heights.removeValue(forKey: row) }
        textReveals.removeAll()
        highlightGeneration += 1
        highlightEntries = highlightEntries.filter { $0.key < start }
        liveHighlightRows = Set(unindexed.compactMap { record in
            records.firstIndex { $0.kind == record.kind && $0.time == record.time }
        })
        liveHighlightRows.insert(records.count - 1)
        scheduleHighlights(from: start)
        table.reloadData()
        if previous.follows {
            if let liveFocus { position(on: liveFocus) }
            else { followLatest() }
        } else { restoreViewState(previous) }
    }
    func recordsSnapshot() -> [StreamRecord] { if !batch.isEmpty { flush() }; return records }
    func updateCommand(_ activity: CommandActivity, itemID: String) {
        if !batch.isEmpty { flush() }
        if let row = feed.updateCommand(activity, itemID: itemID) { scheduleHighlights(from: row) }
    }
    func changeFont(_ delta: CGFloat) {
        resetResizeAnchor()
        loadViewIfNeeded(); size = min(28, max(8, size + delta))
        UserDefaults.standard.set(Double(size), forKey: "unfold.stream.fontSize")
        refreshFontControls(); rendered.removeAll(); heights.removeAll(); table.reloadData(); followLatest()
        publishViewState()
    }
    /// Fonts and wrapping differ between styles, so every row is typeset again.
    func applyInterfaceStyle() {
        loadViewIfNeeded()
        rain.isRaining = InterfaceStyle.isMatrix
        rain.surge()
        rendered.removeAll(); heights.removeAll(); textReveals.removeAll(); table.reloadData(); followLatest(animated: false)
    }
    private func refreshFontControls() {
        sizeButton.title = String(Int(size)); smallerText.isEnabled = size > 8; largerText.isEnabled = size < 28
    }
    @objc private func decreaseFont() { changeFont(-1) }
    @objc private func increaseFont() { changeFont(1) }
    @objc func resetFont() { changeFont(16 - size) }
    var viewState: StreamViewState {
        if let pendingViewState { return pendingViewState }
        let top = scroll.documentVisibleRect.minY
        let row = table.row(at: NSPoint(x: 1, y: top))
        let index = max(0, min(max(0, records.count - 1), row))
        let offset = records.isEmpty ? 0 : top - table.rect(ofRow: index).minY
        return StreamViewState(firstRecord: index, offset: Double(offset), follows: follow.state == .on, fontSize: Double(size), searchQuery: search.stringValue, searchVisible: !searchRow.isHidden, navigatorWidth: navigatorSplit.preferredWidth.map(Double.init))
    }
    private func publishViewState() {
        highlights.setFollowingLatest(follow.state == .on && liveFocus == nil)
        if !restoringPosition {
            let state = viewState
            if let liveFocus { highlights.markFocused(liveFocus) }
            else { highlights.markCurrent(record: state.firstRecord, visibleRecords: table.rows(in: scroll.documentVisibleRect)) }
            onViewStateChanged?(state)
        }
    }
    private func scheduleHighlights(from start: Int) {
        pendingHighlightStart = min(pendingHighlightStart ?? start, start)
        guard !highlightScheduled else { return }; highlightScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.highlightScheduled = false
            let start = min(self.pendingHighlightStart ?? 0, self.records.count)
            self.pendingHighlightStart = nil
            let generation = self.highlightGeneration
            let values = self.records.enumerated().dropFirst(start).map { ($0.offset, $0.element) }
            self.highlightQueue.async { [weak self] in
                let results = values.map { (row, record) in (row, record.text, record.command, FeedHighlightIndex.entries(for: record, at: row)) }
                DispatchQueue.main.async {
                    guard let self, self.highlightGeneration == generation else { return }
                    var fresh: [FeedHighlight] = []
                    for (row, source, command, entries) in results where self.records.indices.contains(row) && self.records[row].text == source && self.records[row].command == command {
                        self.highlightEntries[row] = entries
                        if self.liveHighlightRows.remove(row) != nil { fresh.append(contentsOf: FeedLiveFocusSequence.objects(entries)) }
                    }
                    if self.liveFocus != nil || !fresh.isEmpty { self.highlights.setFollowingLatest(false) }
                    self.highlights.update(self.highlightEntries.keys.sorted().flatMap { self.highlightEntries[$0] ?? [] })
                    self.offerLiveFocus(fresh)
                    self.publishViewState()
                }
            }
        }
    }
    private func jump(to entry: FeedHighlight) {
        resetResizeAnchor()
        guard records.indices.contains(entry.record) else { return }
        clearLiveFocus(); scrollMotion.cancel(); follow.state = .off
        position(on: entry)
        publishViewState()
    }
    /// Follow distinct objects, rather than every fragment of the data tail.
    private func offerLiveFocus(_ entries: [FeedHighlight]) {
        guard follow.state == .on, !hasSelection else { return }
        for entry in entries where records.indices.contains(entry.record) {
            let record = records[entry.record]
            let key = FeedLiveFocusSequence.key(entry, record: record)
            if key == liveFocusKey {
                // Update the live object without restarting its reading pause.
                // Interleaved fragments must not pull the viewport backwards.
                if liveFocus?.record == entry.record { liveFocus = entry }
            }
            liveSequence.offer(entry, record: record)
        }
        if liveFocus == nil { showNextLiveFocus() }
    }
    private func showNextLiveFocus() {
        liveFocusTimer?.cancel(); liveFocusTimer = nil
        liveFocus = nil; liveFocusKey = nil
        guard follow.state == .on, !hasSelection else { return }
        guard let object = liveSequence.next() else { followLatest(); return }
        let entry = object.highlight
        liveFocusKey = object.key
        liveFocus = entry
        highlights.setFollowingLatest(false)
        refreshRows([entry.record])
        scrollMotion.cancel()
        position(on: entry)
        highlights.markFocused(entry)
        scheduleLiveFocusEnd()
    }
    private func scheduleLiveFocusEnd() {
        liveFocusTimer?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.showNextLiveFocus() }
        liveFocusTimer = task
        guard let entry = liveFocus else { return }
        let duration = liveFocusDuration?(entry) ?? (entry.freshCode ? 9 : entry.readingPause != nil ? 6 : 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
    private func clearLiveFocus() {
        liveFocusTimer?.cancel(); liveFocusTimer = nil
        liveFocus = nil; liveFocusKey = nil
        liveSequence = FeedLiveFocusSequence()
    }
    private func position(on entry: FeedHighlight) {
        guard records.indices.contains(entry.record) else { return }
        let content = blocks(entry.record)
        let width = contentWidth - 28
        heights[entry.record] = 20 + content.reduce(CGFloat(0)) { $0 + NativeFeedLayout.height($1, width: width, images: images) } + CGFloat(max(0, content.count - 1)) * 8
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: entry.record))
        table.layoutSubtreeIfNeeded()
        var offset: CGFloat = 10
        var occurrence = 0
        var foundBlock = false
        for block in content {
            let match: Bool
            switch block {
            case .html: match = entry.kind == "HTML" && !entry.freshCode
            case .image: match = entry.kind == "Image"
            case .code(_, _, let label):
                match = entry.kind == "JSON" ? label == "JSON" : entry.kind == "HTML" ? label.uppercased() == "HTML" : entry.kind == "Python" ? label.hasPrefix("Python") : entry.kind == "UI tree" ? label == "UI tree" : entry.kind == "Code" && label != "JSON" && !label.hasPrefix("Python")
            case .prose(_, let tone): match = entry.kind == "Reasoning" && tone == .reasoning
            default: match = false
            }
            if match {
                if occurrence == entry.occurrence { foundBlock = true; break }
                occurrence += 1
            }
            offset += NativeFeedLayout.height(block, width: width, images: images) + 8
        }
        if !foundBlock { offset = 0 }
        scrollTo(y: table.rect(ofRow: entry.record).minY + offset)
        if let needle = entry.needle { reveal(needle, in: entry.record) }
    }
    private func scrollTo(y: CGFloat) {
        let limit = max(0, table.bounds.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, y))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func reveal(_ needle: String, in row: Int, selecting: Bool = false) {
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
        func find(_ node: NSView) -> Bool {
            if let text = node as? NativeFeedTextView, let layout = text.layoutManager, let container = text.textContainer {
                let range = (text.string as NSString).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                if range.location != NSNotFound {
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    scrollTo(y: text.convert(box, to: table).minY - 8)
                    if selecting { text.setSelectedRange(range); text.window?.makeFirstResponder(text) }
                    return true
                }
            }
            return node.subviews.contains { find($0) }
        }
        _ = find(view)
    }
    func restoreViewState(_ state: StreamViewState) {
        resetResizeAnchor()
        clearLiveFocus()
        loadViewIfNeeded(); restoringPosition = true
        viewStateGeneration += 1
        let generation = viewStateGeneration
        pendingViewState = state
        navigatorSplit.restoreWidth(state.navigatorWidth)
        search.stringValue = state.searchQuery ?? ""; searchRow.isHidden = !(state.searchVisible ?? false)
        size = min(28, max(8, state.fontSize)); follow.state = state.follows ? .on : .off
        refreshFontControls(); rendered.removeAll(); heights.removeAll(); table.reloadData()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewStateGeneration == generation else { return }
            self.view.layoutSubtreeIfNeeded()
            if state.follows { self.followLatest() }
            else if !self.records.isEmpty {
                let row = min(self.records.count - 1, max(0, state.firstRecord))
                self.table.scrollRowToVisible(row)
                let y = max(0, self.table.rect(ofRow: row).minY + state.offset)
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
            self.pendingViewState = nil; self.restoringPosition = false
        }
    }
    func revealSearchMatch(record: Int, needle: String) {
        loadViewIfNeeded()
        guard records.indices.contains(record) else { return }
        var state = viewState
        state.firstRecord = record; state.offset = 0; state.follows = false
        restoreViewState(state)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reveal(needle, in: record, selecting: true)
            self.publishViewState()
        }
    }
    func find() { searchRow.isHidden = false; view.window?.makeFirstResponder(search); publishViewState() }
    @objc private func dismissSearch() {
        searchRow.isHidden = true
        view.window?.makeFirstResponder(table)
        publishViewState()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismissSearch(); return true
    }
    @objc func findNext() {
        let query = search.stringValue; guard !query.isEmpty, !records.isEmpty else { return }
        let visible = table.rows(in: scroll.documentVisibleRect)
        let start = visible.location == NSNotFound ? 0 : min(records.count - 1, max(0, visible.location))
        let order = Array(start..<records.count) + Array(0..<min(start, records.count))
        guard let row = order.first(where: { records[$0].text.localizedCaseInsensitiveContains(query) }) else { return }
        follow.state = .off; table.scrollRowToVisible(row)
        guard let rowView = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
        func select(in view: NSView) -> Bool {
            if let text = view as? NativeFeedTextView {
                let range = (text.string as NSString).range(of: query, options: .caseInsensitive)
                if range.location != NSNotFound { text.setSelectedRange(range); text.scrollRangeToVisible(range); return true }
            }
            return view.subviews.contains { select(in: $0) }
        }
        _ = select(in: rowView)
    }
    func controlTextDidChange(_ obj: Notification) { findNext(); publishViewState() }
    private func showHTML(_ html: String) {
        let preview = HTMLPreviewWindow(html: html); previews.append(preview); preview.showWindow(nil)
    }
    private func showImage(_ image: NSImage) {
        let imageView = NSImageView(); imageView.image = image; imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.animates = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Image"; window.contentView = imageView; window.isReleasedWhenClosed = false; window.center()
        let preview = NSWindowController(window: window); previews.append(preview); preview.showWindow(nil)
    }
}

@MainActor
final class HTMLPreviewWindow: NSWindowController, WKNavigationDelegate {
    let web: WKWebView
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
    static func document(_ html: String) -> String {
        let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' https:; img-src data: https: http:; font-src data: https:; frame-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'"
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" + html
    }
    init(html: String) {
        web = Self.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HTML preview"; window.contentView = web; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); web.navigationDelegate = self
        web.loadHTMLString(Self.document(html), baseURL: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
