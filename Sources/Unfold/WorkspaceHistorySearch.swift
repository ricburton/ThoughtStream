import AppKit

@MainActor
final class WorkspaceHistorySearch: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = PaddedHistorySearchField(frame: .zero)
    let view = NSView()
    private let table = HistorySearchTableView()
    private let message = NSTextField(wrappingLabelWithString: "Search your local conversations")
    private let index: LocalHistorySearch
    private var refreshTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var results: [LocalHistorySearch.Result] = []
    private var indexing = false
    private(set) var isSearching = false
    var onVisibility: ((Bool) -> Void)?
    var onOpen: ((LocalHistorySearch.Result) -> Void)?
    init(index: LocalHistorySearch = LocalHistorySearch()) {
        self.index = index
        super.init()
        field.placeholderString = "Search all chats"
        field.setAccessibilityLabel("Search local chat history")
        field.toolTip = "Search local chats and responses. Exact text first, then close matches."
        field.delegate = self; field.target = self; field.action = #selector(submitSearch)
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.font = Typography.caption; message.textColor = FeedPalette.muted
        table.addTableColumn(NSTableColumn(identifier: .init("localHistory")))
        table.headerView = nil; table.rowHeight = 58; table.style = .plain
        table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(openSelected)
        table.onCancel = { [weak self] in self?.dismiss() }
        table.setAccessibilityLabel("Local history search results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        for child in [message, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.isHidden = true
    }
    func refresh() {
        guard refreshTask == nil else { return }
        indexing = true
        refreshTask = Task { [weak self, index] in
            var errorMessage: String?
            do { try await index.refresh() } catch is CancellationError { return } catch { errorMessage = error.localizedDescription }
            guard let self, !Task.isCancelled else { return }
            self.indexing = false; self.refreshTask = nil
            if self.isSearching { self.runQuery(errorMessage: errorMessage) }
        }
    }
    func controlTextDidChange(_ obj: Notification) { queryChanged() }
    func queryChanged() {
        queryTask?.cancel()
        let active = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if active != isSearching {
            isSearching = active; view.isHidden = !active; onVisibility?(active)
        }
        results = []; table.reloadData()
        guard active else { return }
        message.stringValue = indexing ? "Indexing local history…" : "Searching local history…"
        runQuery()
    }
    private func runQuery(errorMessage: String? = nil) {
        queryTask?.cancel()
        let query = field.stringValue
        queryTask = Task { [weak self, index] in
            do {
                try await Task.sleep(nanoseconds: 90_000_000)
                repeat {
                    let matches = try await index.search(query)
                    guard let self, !Task.isCancelled, self.field.stringValue == query, self.isSearching else { return }
                    self.results = matches; self.table.reloadData()
                    let count = matches.count == 80 ? "80+" : String(matches.count)
                    self.message.stringValue = self.indexing ? "\(count) results · indexing local history…" : errorMessage.map { "Some history could not be indexed. Try your search again. \($0)" } ?? (matches.isEmpty ? "No matching chats. Try a different word or phrase." : "\(count) results · exact matches first")
                    guard self.indexing else { return }
                    try await Task.sleep(nanoseconds: 450_000_000)
                } while !Task.isCancelled
            } catch is CancellationError { } catch {
                guard let self, self.field.stringValue == query else { return }
                self.message.stringValue = "Could not search local history. Change your search to try again. \(error.localizedDescription)"
            }
        }
    }
    func dismiss() {
        field.stringValue = ""; queryChanged()
    }
    func stop() { refreshTask?.cancel(); queryTask?.cancel() }
    @objc private func submitSearch() {
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 else { return }
        openSelected()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            field.window?.makeFirstResponder(table); return true
        }
        return false
    }
    @objc private func openSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard results.indices.contains(row) else { return }
        onOpen?(results[row])
    }
    func load(_ result: LocalHistorySearch.Result) async -> LocalHistorySearch.Document? { await index.load(result) }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let title = NSTextField(labelWithString: "\(result.document.title.replacingOccurrences(of: "\n", with: " ")) · \(URL(fileURLWithPath: result.document.project).lastPathComponent) · \(Self.age(result.document.updated))")
        title.font = Typography.interfaceEmphasis
        title.lineBreakMode = .byTruncatingTail
        let snippet = NSTextField(labelWithString: "")
        snippet.font = Typography.caption; snippet.textColor = FeedPalette.muted; snippet.lineBreakMode = .byTruncatingTail
        let text = result.snippet
        let styled = NSMutableAttributedString(string: text, attributes: [.font: Typography.caption, .foregroundColor: FeedPalette.muted])
        let range = (text as NSString).range(of: result.needle, options: [.caseInsensitive, .diacriticInsensitive])
        if range.location != NSNotFound { styled.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor], range: range) }
        snippet.attributedStringValue = styled
        let stack = NSStackView(views: [title, snippet]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        NSLayoutConstraint.activate([title.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20), snippet.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20)])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.toolTip = "\(result.document.title)\n\(result.document.project)\n\(result.approximate ? "Close match" : "Exact match") · \(text)"
        return stack
    }
    static func age(_ date: Date, now: Date = Date()) -> String {
        guard date != .distantPast else { return "Earlier" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Keep the native bezel, focus ring, search and clear buttons, with more room inside.
@MainActor
final class PaddedHistorySearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { PaddedHistorySearchFieldCell.self }
        set { }
    }
}

@MainActor
final class PaddedHistorySearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        super.searchTextRect(forBounds: rect.insetBy(dx: 6, dy: 0))
    }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        super.searchButtonRect(forBounds: rect.insetBy(dx: 6, dy: 0))
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        super.cancelButtonRect(forBounds: rect.insetBy(dx: 6, dy: 0))
    }
}

@MainActor
private final class HistorySearchTableView: NSTableView {
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { sendAction(action, to: target) }
        else if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}
