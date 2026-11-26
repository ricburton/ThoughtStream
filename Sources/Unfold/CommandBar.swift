import AppKit

/// A command owns its presentation and action so the palette and workspace use
/// the same validation and behavior, without synthesizing keyboard events.
@MainActor
struct CommandBarItem {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var shortcut = ""
    var keywords = ""
    let run: () -> Void

    func matches(_ query: String) -> Bool {
        let text = "\(title) \(detail) \(keywords)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@MainActor
final class CommandBar: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    let field = NSTextField()
    let table = CommandBarTable()
    private let summary = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No matching commands, chats, or projects")
    private var items: [CommandBarItem] = []
    private(set) var results: [CommandBarItem] = []
    private var searchHistory: ((String) -> Void)?
    private weak var owner: NSWindow?
    private weak var previousResponder: NSResponder?
    private var clickMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var isDismissing = false
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.title = "Command Bar"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.delegate = self
        panel.setAccessibilityLabel("Command Bar")
        let surface = CommandBarSurface()
        panel.contentView = surface
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = "Search chats, projects, and actions…"
        field.setAccessibilityLabel("Search chats, projects, and actions")
        field.delegate = self
        let escape = NSButton(title: "esc", target: self, action: #selector(cancel))
        escape.bezelStyle = .inline
        escape.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        escape.setAccessibilityLabel("Close Command Bar")
        let divider = NSBox(); divider.boxType = .separator
        summary.font = .systemFont(ofSize: 10, weight: .semibold)
        summary.textColor = .secondaryLabelColor
        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil; table.rowHeight = 49; table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .plain; table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(activateClicked)
        table.setAccessibilityLabel("Commands, chats, and projects")
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.onCancel = { [weak self] in self?.dismiss() }
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        let footerLine = NSBox(); footerLine.boxType = .separator
        let footer = NSTextField(labelWithString: "↑ ↓  Navigate     ↵  Open or run     esc  Close")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        for view in [icon, field, escape, divider, summary, scroll, empty, footerLine, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: surface.topAnchor, constant: 25),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: escape.leadingAnchor, constant: -12),
            escape.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            escape.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            escape.widthAnchor.constraint(equalToConstant: 30),
            divider.topAnchor.constraint(equalTo: surface.topAnchor, constant: 70),
            divider.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            summary.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 9),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footerLine.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            footerLine.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -39),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            footer.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20)
        ])
    }

    func show(in window: NSWindow, toggleButton: NSView? = nil, items: [CommandBarItem], searchHistory: @escaping (String) -> Void) {
        guard !isVisible, window.attachedSheet == nil else { return }
        owner = window; previousResponder = window.firstResponder
        self.items = items; self.searchHistory = searchHistory
        field.stringValue = ""; updateResults()
        let width = min(620, window.frame.width - 48)
        let height = min(450, window.frame.height - 100)
        panel.setFrame(NSRect(x: window.frame.midX - width / 2, y: window.frame.maxY - height - 90,
                              width: width, height: height), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return false }
                // Consume a click on the opener so its action does not reopen
                // the palette immediately after outside-click dismissal.
                let clickedToggle = toggleButton.map { button in
                    event.window === button.window && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
                } ?? false
                self.dismiss(restoreFocus: clickedToggle)
                return clickedToggle
            }
            return consume ? nil : event
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
        let window = owner
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus {
            window?.makeKey()
            if let previousResponder { window?.makeFirstResponder(previousResponder) }
        }
        items = []; results = []; searchHistory = nil
        owner = nil; previousResponder = nil
    }

    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
    @objc private func cancel() { dismiss() }
    func controlTextDidChange(_ obj: Notification) { updateResults() }

    func updateResults() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        results = items.filter { $0.matches(query) }
        if !query.isEmpty, let searchHistory {
            results.append(CommandBarItem(id: "history", title: "Search all chat history for “\(query)”",
                                          detail: "Search messages and responses · local history", symbol: "text.magnifyingglass",
                                          run: { searchHistory(query) }))
        }
        summary.stringValue = query.isEmpty ? "SUGGESTED ACTIONS · CHATS · PROJECTS" : "\(results.count) RESULTS"
        empty.isHidden = !results.isEmpty
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let row = (max(0, table.selectedRow) + offset + results.count) % results.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    func activateSelection() {
        guard results.indices.contains(table.selectedRow) else { return }
        let run = results[table.selectedRow].run
        dismiss()
        run()
    }
    @objc private func activateClicked() {
        guard table.clickedRow >= 0 else { return }
        activateSelection()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CommandBarRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let shortcut = NSTextField(labelWithString: item.shortcut)
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .medium); shortcut.textColor = .secondaryLabelColor
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.textField = title; cell.imageView = icon
        for view in [icon, title, detail, shortcut] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel("\(item.title), \(item.detail), \(item.shortcut)")
        return cell
    }
}

@MainActor
final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandBarTable: NSTableView {
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onActivate?() }
        else if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class CommandBarSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1).setFill(); shape.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

@MainActor
private final class CommandBarRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 8, yRadius: 8).fill()
    }
}
