import AppKit

struct FeedHighlight: Sendable {
    var record: Int
    let kind: String
    var title: String
    var summary: String
    var occurrence = 0
    var needle: String?
    var command: CommandActivity? = nil
    var commandText: String? = nil
    var freshCode = false
    var createdOutput = false
    // A reasoning object gets a bounded pause from its first appearance.
    var readingPause: TimeInterval? = nil
    var id: String { "\(record):\(kind):\(occurrence):\(kind == "Heading" ? needle ?? "" : "")" }
}

enum FeedHighlightIndex {
    /// Read only enough text for labels. Never format or lay out the full feed here.
    static func entries(for record: StreamRecord, at index: Int) -> [FeedHighlight] {
        if isProtocolChatter(record) { return [] }
        let prefix = String(record.text.prefix(2048))
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let authored = record.kind == "Agent" || record.kind == "Code"
        // This index runs off the main thread. Decode only likely transport envelopes;
        // use the same parts as the renderer so labels describe the visible content.
        if (prefix.contains("\"content\"") || prefix.contains("\"text\"") || prefix.contains("\"result\"")),
           let json = NativeJSON.parse(record.text), let parts = ToolPayload.unwrap(json) {
            var entries: [FeedHighlight] = []
            var occurrences: [String: Int] = [:]
            for part in parts {
                let additions: [FeedHighlight]
                switch part {
                case .text(let text):
                    if ToolPayload.isUITree(text) {
                        additions = [FeedHighlight(record: index, kind: "UI tree", title: "Inspect app", summary: summary(text, kind: "UI tree"))]
                    } else {
                        var decoded = record; decoded.text = text; decoded.language = nil
                        additions = Self.entries(for: decoded, at: index)
                    }
                case .image:
                    additions = [FeedHighlight(record: index, kind: "Image", title: "Image", summary: "Tool image")]
                case .caption:
                    additions = []
                case .json(let value):
                    additions = [FeedHighlight(record: index, kind: "JSON", title: "Structured data", summary: FeedSummary.objectDetail(value))]
                }
                for var entry in additions {
                    entry.occurrence = occurrences[entry.kind, default: 0]
                    occurrences[entry.kind, default: 0] += 1
                    entries.append(entry)
                }
            }
            return entries
        }
        let language = record.language?.lowercased() ?? ""
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let eventJSON = lines.count == 2 && lines[0].range(of: #"^[\w./ :—-]+$"#, options: .regularExpression) != nil && lines[1].trimmingCharacters(in: .whitespaces).hasPrefix("{")
        var kind: String
        switch record.kind {
        case "Reasoning summary": kind = "Reasoning"
        case "You": kind = "You"
        case "Command": kind = "Command"
        case "Output": kind = "Output"
        case "File change": kind = "Changes"
        case "Code": kind = "Code"
        case "Error": kind = "Error"
        case "Tool": kind = "Tool"
        case "Session", "Context compaction": kind = "Session"
        default: kind = "Reply"
        }
        if language == "python" || language == "py" || (record.kind == "Command" && !PythonSnippetExtractor.extract(from: record.text).isEmpty) { kind = "Python" }
        else if language == "json" || trimmed.hasPrefix("{") || trimmed.hasPrefix("[{") || trimmed.hasPrefix("[\"") || trimmed.hasPrefix("[[") || eventJSON { kind = "JSON" }
        else if ["html", "htm", "svg"].contains(language) || trimmed.range(of: #"^(?:<!doctype|<(?:html|main|div|svg|article|section|style)[\s>])"#, options: [.regularExpression, .caseInsensitive]) != nil { kind = "HTML" }
        else if trimmed.hasPrefix("data:image/") || trimmed.hasPrefix("/9j/") || trimmed.hasPrefix("iVBORw0") { kind = "Image" }
        let label = FeedSummary.describe(record.text, kind: kind, fallback: summary(prefix, kind: kind))
        let commandText: String?
        if record.kind == "Command" {
            if let marker = record.text.range(of: "\n$ ") { commandText = String(record.text[marker.upperBound...]) }
            else { commandText = record.text }
        } else { commandText = nil }
        let added = record.text.components(separatedBy: .newlines).first { $0.hasPrefix("+") && !$0.hasPrefix("+++") && !$0.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty }
        var result = [FeedHighlight(record: index, kind: kind, title: record.isFinalResponse == true ? "Final answer" : label.title, summary: label.detail, needle: kind == "Changes" ? added : nil, command: record.command, commandText: commandText, freshCode: (record.kind == "Code" && kind != "JSON" && !trimmed.isEmpty) || (kind == "Changes" && added != nil), createdOutput: authored && ["JSON", "HTML", "Image"].contains(kind) && !trimmed.isEmpty)]
        if record.kind == StreamKind.reasoning.rawValue, !trimmed.isEmpty {
            let words = record.text.split(whereSeparator: { $0.isWhitespace }).count
            result[0].readingPause = min(18, max(6, Double(words) / 3.5))
        }
        // Markdown has multiple navigable blocks within a single streamed reply.
        if ["Command", "Output", "File change"].contains(record.kind) { return result }
        var fence: String?
        var occurrences: [String: Int] = [:]
        let sourceLines = record.text.components(separatedBy: .newlines)
        for (lineIndex, sourceLine) in sourceLines.enumerated() {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if fence != nil { fence = nil; continue }
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                fence = language
                let type = language == "json" ? "JSON" : ["html", "htm", "svg"].contains(language) ? "HTML" : ["py", "python"].contains(language) ? "Python" : "Code"
                let count = occurrences[type, default: 0]; occurrences[type] = count + 1
                let body = sourceLines.dropFirst(lineIndex + 1).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(String(line.prefix(3))) }.joined(separator: "\n")
                let description = FeedSummary.codeDescription(body, language: language)
                let hasContent = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                result.append(FeedHighlight(record: index, kind: type, title: type == "JSON" ? "Structured data" : description.title, summary: description.detail, occurrence: count, freshCode: authored && type != "JSON" && hasContent, createdOutput: authored && hasContent))
            } else if fence == nil, line.hasPrefix("#"), let space = line.firstIndex(of: " ") {
                let title = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { result.append(FeedHighlight(record: index, kind: "Heading", title: title, summary: "Section", needle: title)) }
            } else if fence == nil, line.contains("!["), line.contains("](") {
                let count = occurrences["Image", default: 0]; occurrences["Image"] = count + 1
                result.append(FeedHighlight(record: index, kind: "Image", title: "Image", summary: "Inline image", occurrence: count, createdOutput: authored))
            }
        }
        // Image/HTML content in a JSON tool response is useful even without a fence.
        if kind == "JSON" {
            if prefix.contains("data:image/") || prefix.contains("\"mimeType\" : \"image/") || prefix.contains("\"type\":\"image\"") {
                result.append(FeedHighlight(record: index, kind: "Image", title: "Image", summary: "Tool image"))
            }
            if prefix.contains("<!doctype") || prefix.contains("<html") {
                result.append(FeedHighlight(record: index, kind: "HTML", title: "HTML", summary: "Embedded preview"))
            }
        }
        return result
    }
    private static func isProtocolChatter(_ record: StreamRecord) -> Bool {
        guard record.kind == "Session" else { return false }
        let prefix = String(record.text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.hasPrefix("Command status:") || prefix.hasPrefix("Turn completed.") || prefix.hasPrefix("deprecationNotice") { return true }
        let method = prefix.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if ["remoteControl/", "account/", "mcpServer/", "thread/settings/", "thread/tokenUsage/", "thread/status/", "turn/moderationMetadata", "hook/", "serverRequest/"].contains(where: { method.hasPrefix($0) }) { return true }
        if prefix.hasPrefix("{"), prefix.contains("\"timestamp\""), prefix.contains("\"level\""), prefix.contains("\"target\"") { return true }
        if prefix.contains("rmcp::transport") { return true }
        return false
    }
    private static func summary(_ text: String, kind: String) -> String {
        if kind == "Image" { return "Image preview" }
        if kind == "HTML" { return "Rendered preview" }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var first = lines.first(where: { !$0.isEmpty && !["{", "[", "}", "]"].contains($0) }) ?? kind
        if first.count > 180 && (first.contains("\"data\"") || first.contains("base64")) { return "Structured content" }
        if first.hasPrefix("$") { first = String(first.dropFirst()).trimmingCharacters(in: .whitespaces) }
        first = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return String(first.prefix(110))
    }
}

@MainActor
final class FeedHighlightsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var scrollMotion = FeedScrollMotion(scroll)
    private var entries: [FeedHighlight] = []
    private var selectedID: String?
    private var followsLatest = true
    private var clockTimer: Timer?
    var onJump: ((FeedHighlight) -> Void)?
    var onLatest: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Overview")
        title.font = Typography.section; title.textColor = FeedPalette.muted
        let latest = NSButton(title: "", target: self, action: #selector(jumpLatest))
        latest.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        latest.imagePosition = .imageOnly
        latest.isBordered = false
        latest.contentTintColor = FeedPalette.muted
        latest.setAccessibilityLabel("Go to bottom")
        latest.toolTip = "Go to the latest item"
        let header = NSStackView(views: [title, NSView()]); header.orientation = .horizontal; header.spacing = 4
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("highlight")))
        table.headerView = nil; table.rowHeight = 66; table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 3); table.backgroundColor = .clear
        table.focusRingType = .default; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(jumpSelected)
        table.setAccessibilityLabel("Overview: reasoning, created code and output highlighted, followed chronologically with supporting activity")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        for child in [header, scroll, latest] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaneSpacing.textInset + 8), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaneSpacing.textInset), header.topAnchor.constraint(equalTo: topAnchor, constant: 8), header.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: PaneSpacing.gap), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaneSpacing.textInset), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaneSpacing.textInset), scroll.bottomAnchor.constraint(equalTo: latest.topAnchor, constant: -PaneSpacing.gap),
            latest.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaneSpacing.textInset), latest.widthAnchor.constraint(equalToConstant: 30), latest.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PaneSpacing.textInset), latest.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    func reset() {
        scrollMotion.cancel()
        clockTimer?.invalidate(); clockTimer = nil
        entries.removeAll(); selectedID = nil; followsLatest = true
        table.deselectAll(nil); table.reloadData()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func update(_ entries: [FeedHighlight]) {
        let previous = self.entries
        let viewport = scroll.contentView.bounds.origin
        let oldTop = table.row(at: NSPoint(x: 1, y: viewport.y))
        let topID = previous.indices.contains(oldTop) ? previous[oldTop].id : nil
        let topOffset = oldTop >= 0 ? viewport.y - table.rect(ofRow: oldTop).minY : 0
        let changes = entries.map(\.id).difference(from: previous.map(\.id))
        let oldHeights = previous.reduce(into: [String: CGFloat]()) { $0[$1.id] = $1.overviewHeight }
        self.entries = entries
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            var removed = IndexSet(), inserted = IndexSet()
            for change in changes {
                switch change {
                case .remove(let index, _, _): removed.insert(index)
                case .insert(let index, _, _): inserted.insert(index)
                }
            }
            table.beginUpdates()
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
            var restyled = IndexSet()
            for (index, entry) in entries.enumerated() where !inserted.contains(index) {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? FeedOverviewCell,
                   !cell.update(entry) { restyled.insert(index) }
                else if let oldHeight = oldHeights[entry.id], oldHeight != entry.overviewHeight {
                    restyled.insert(index)
                }
            }
            if !restyled.isEmpty {
                table.reloadData(forRowIndexes: restyled, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: restyled)
            }
            table.layoutSubtreeIfNeeded()
            if !followsLatest, let topID, let row = entries.firstIndex(where: { $0.id == topID }) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: row).minY + topOffset)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if entries.contains(where: { $0.command?.state == .running }) {
            if clockTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self else { timer.invalidate(); return }
                        self.tick()
                    }
                }
                RunLoop.main.add(timer, forMode: .common); clockTimer = timer
            }
        } else { clockTimer?.invalidate(); clockTimer = nil }
        if let index = entries.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if followsLatest { scrollToLatest() }
    }
    func setFollowingLatest(_ follows: Bool) {
        followsLatest = follows
        if !follows { scrollMotion.cancel() }
        if follows { scrollToLatest() }
    }
    override func layout() {
        super.layout()
        if followsLatest { scrollToLatest() }
    }
    private func scrollToLatest() {
        guard let last = entries.indices.last else { return }
        selectedID = entries[last].id
        if table.selectedRow != last { table.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false) }
        table.layoutSubtreeIfNeeded()
        scrollMotion.move(to: max(0, table.rect(ofRow: last).maxY - scroll.contentSize.height))
    }
    func markCurrent(record: Int, visibleRecords: NSRange) {
        guard !followsLatest else { return }
        // A jump near the end cannot always put its record at the top. Keep
        // the chosen item selected while it is visible instead of replacing it
        // with whichever earlier record happens to start the viewport.
        if let current = entries.first(where: { $0.id == selectedID }),
           current.record == record || (visibleRecords.location != NSNotFound && NSLocationInRange(current.record, visibleRecords)) { return }
        guard let index = entries.firstIndex(where: { $0.record == record }) ?? entries.lastIndex(where: { $0.record < record }) else { return }
        if selectedID != entries[index].id { selectedID = entries[index].id; table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { entries[row].overviewHeight }
    func markFocused(_ entry: FeedHighlight) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard selectedID != entry.id || table.selectedRow != index else { return }
        selectedID = entry.id
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FeedOverviewRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        FeedOverviewCell(entry: entries[row])
    }
    private func tick() {
        let rows = table.rows(in: table.visibleRect)
        guard rows.location != NSNotFound else { return }
        for row in rows.location..<min(entries.count, NSMaxRange(rows)) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FeedOverviewCell)?.updateClock()
        }
    }
    @objc private func jumpSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        followsLatest = false
        let entry = entries[table.selectedRow]; selectedID = entry.id; onJump?(entry)
    }
    @objc private func jumpLatest() { onLatest?() }
}

@MainActor
final class FeedTypeBadge: NSView {
    private let ink: NSColor
    init(kind: String, prominent: Bool = true) {
        ink = !prominent ? FeedPalette.muted : ["New code", "Created code", "Created output", "File changes"].contains(kind) ? FeedPalette.green : kind == "Reasoning" ? FeedPalette.purple : kind == "Error" ? FeedPalette.red : ["JSON", "HTML", "Code", "Python"].contains(kind) ? FeedPalette.blue : FeedPalette.muted
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: kind == "You" ? "Prompt" : kind == "Command" ? "Shell" : kind)
        title.font = Typography.badge; title.textColor = ink
        title.translatesAutoresizingMaskIntoConstraints = false; addSubview(title)
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5), title.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityLabel(kind)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        ink.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}
