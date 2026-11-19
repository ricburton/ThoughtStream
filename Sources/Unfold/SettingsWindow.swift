import AppKit

/// A small, navigable settings surface. Account controls remain owned by the
/// workspace so their asynchronous connection state survives page changes.
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Action: CaseIterable {
        case split, stack, closePane, singlePane, fork, requests, snapshot, export

        var title: String {
            switch self {
            case .split: return "Side by side"
            case .stack: return "Stacked"
            case .closePane: return "Close pane"
            case .singlePane: return "Single pane"
            case .fork: return "Fork chat"
            case .requests: return "View requests"
            case .snapshot: return "View snapshot"
            case .export: return "Export…"
            }
        }
    }

    private enum Page: String, CaseIterable {
        case general = "General", accounts = "Accounts", localModels = "Local Models", chat = "Chat", developer = "Developer"

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .accounts: return "person.crop.circle"
            case .localModels: return "desktopcomputer"
            case .chat: return "bubble.left"
            case .developer: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    private let navigation = NSTableView()
    private let pageTitle = NSTextField(labelWithString: "General")
    private let scrollView = NSScrollView()
    private let pageDocument = FlippedSettingsView()
    private var pages: [Page: NSStackView] = [:]
    private var pageConstraints: [NSLayoutConstraint] = []
    private var paneLayoutSection: NSView?
    private var tabsOnlyNote: NSTextField?
    private let localModels: LocalModelRegistry
    private let localRuntimeRows = NSStackView()
    private let localScanStatus = NSTextField(labelWithString: "")
    private var localObserver: NSObjectProtocol?
    private var localScan: Task<Void, Never>?
    /// Set by the workspace. Off by default, so a bare settings window never
    /// contacts a local server.
    var scansLocalModelsWhenShown = false

    init(target: AnyObject, actions: [Action: Selector], chatGPTButton: NSButton,
         claudeButton: NSButton, claudeStatus: NSTextField, localModels: LocalModelRegistry? = nil) {
        self.localModels = localModels ?? .shared
        let panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Settings"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 480)
        super.init(window: panel)

        func button(_ action: Action) -> NSButton {
            let control = NSButton(title: action.title, target: target, action: actions[action])
            control.bezelStyle = .rounded
            control.font = Typography.interface
            control.setContentHuggingPriority(.required, for: .horizontal)
            return control
        }

        let layoutSection = section("Workspace layout", rows: [
                row("Add a pane", detail: "Open another view beside or below the current pane.",
                    controls: [button(.split), button(.stack)]),
                row("Simplify your workspace", detail: "Close the focused pane or return to a single pane.",
                    controls: [button(.closePane), button(.singlePane)])
            ])
        paneLayoutSection = layoutSection
        let tabsNote = text("Tabs Only is on. Open chats with + and close them with ×. Change layouts in View → Layout.", secondary: true)
        tabsNote.isHidden = true
        tabsOnlyNote = tabsNote
        pages[.general] = page([layoutSection, tabsNote], note: "Layout changes apply to the current workspace.")

        chatGPTButton.bezelStyle = .rounded
        chatGPTButton.font = Typography.interface
        claudeButton.bezelStyle = .rounded
        claudeButton.font = Typography.interface
        claudeStatus.font = Typography.caption
        claudeStatus.textColor = FeedPalette.muted
        claudeStatus.isSelectable = true
        claudeStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pages[.accounts] = page([
            section("Connected services", rows: [
                row("ChatGPT", detail: "Use your ChatGPT account with Codex.", controls: [chatGPTButton]),
                row("Claude", detailView: claudeStatus, controls: [claudeButton])
            ])
        ], note: "Choose a service in the main sidebar. Existing chats keep the service they started with.")

        pages[.localModels] = makeLocalModelsPage()

        pages[.chat] = page([
            section("Current conversation", rows: [
                row("Start a branch", detail: "Continue from this conversation in a new chat.", controls: [button(.fork)]),
                row("Pending requests", detail: "Review requests waiting for your response.", controls: [button(.requests)])
            ])
        ], note: "These actions use the focused conversation.")

        pages[.developer] = page([
            section("Diagnostics", rows: [
                row("Protocol snapshot", detail: "Inspect the current session’s protocol messages.", controls: [button(.snapshot)]),
                row("Export protocol", detail: "Save session diagnostics to a file.", controls: [button(.export)])
            ])
        ], note: "Diagnostics apply to the focused conversation.")

        buildLayout(in: panel)
        navigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPage(.general)
        panel.center()
        // A preferences window shouldn't take over a Space; reopen where it was left.
        panel.collectionBehavior.insert(.fullScreenNone)
        panel.setFrameAutosaveName("ThoughtStream.Settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let localObserver { NotificationCenter.default.removeObserver(localObserver) } }

    // MARK: Local models

    private func makeLocalModelsPage() -> NSStackView {
        localRuntimeRows.orientation = .vertical
        localRuntimeRows.alignment = .leading
        localRuntimeRows.spacing = 0
        let runtimes = SettingsGroupView()
        localRuntimeRows.translatesAutoresizingMaskIntoConstraints = false
        runtimes.addSubview(localRuntimeRows)
        NSLayoutConstraint.activate([
            localRuntimeRows.leadingAnchor.constraint(equalTo: runtimes.leadingAnchor, constant: 14),
            localRuntimeRows.trailingAnchor.constraint(equalTo: runtimes.trailingAnchor, constant: -14),
            localRuntimeRows.topAnchor.constraint(equalTo: runtimes.topAnchor, constant: 2),
            localRuntimeRows.bottomAnchor.constraint(equalTo: runtimes.bottomAnchor, constant: -2)
        ])
        let heading = text("On this Mac")
        heading.font = Typography.interfaceEmphasis
        let rescan = NSButton(title: "Look Again", target: self, action: #selector(rescanLocalModels))
        rescan.bezelStyle = .rounded; rescan.font = Typography.interface
        localScanStatus.font = Typography.caption; localScanStatus.textColor = FeedPalette.muted
        localScanStatus.lineBreakMode = .byTruncatingTail
        let addServer = NSButton(title: "Add Server…", target: self, action: #selector(addLocalEndpoint))
        addServer.bezelStyle = .rounded; addServer.font = Typography.interface
        addServer.toolTip = "Add any OpenAI-compatible server by address, such as MLX or llama.cpp on this Mac or your network."
        localScanStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, NSView(), localScanStatus, addServer, rescan])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 10
        let found = NSStackView(views: [header, runtimes])
        found.orientation = .vertical; found.alignment = .leading; found.spacing = 10
        header.widthAnchor.constraint(equalTo: found.widthAnchor).isActive = true
        runtimes.widthAnchor.constraint(equalTo: found.widthAnchor).isActive = true

        let fallback = NSSwitch()
        fallback.state = localModels.usesLocalModelsOffline ? .on : .off
        fallback.target = self; fallback.action = #selector(offlineFallbackChanged(_:))
        fallback.setAccessibilityLabel("Use local models when offline")
        let context = NSPopUpButton()
        for length in LocalModelRegistry.contextLengths {
            context.addItem(withTitle: "\(length / 1024)K tokens")
            context.lastItem?.representedObject = length
        }
        context.selectItem(at: LocalModelRegistry.contextLengths.firstIndex(of: localModels.contextLength) ?? 2)
        context.target = self; context.action = #selector(localContextChanged(_:))
        context.font = Typography.interface
        context.setAccessibilityLabel("Conversation memory for Ollama models")
        let options = section("Behavior", rows: [
            row("Use local models when offline",
                detail: "With no Internet, a new chat is answered by a model on this Mac, and a waiting message can be moved to one.",
                controls: [fallback]),
            row("Conversation memory",
                detail: "How much of a chat an Ollama model keeps in view. Larger uses more memory and is capped by each model.",
                controls: [context])
        ])
        localObserver = NotificationCenter.default.addObserver(forName: .localModelsDidChange, object: localModels, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLocalRuntimes() }
        }
        reloadLocalRuntimes()
        return page([found, options], note: "Choose Local Model in the main sidebar to chat with one. Downloaded Ollama and LM Studio models load when needed; scanning does not load them into memory. Local models can run commands, edit files, open apps and run AppleScript on this Mac, asking first unless full access is on. Any number of panes can use them at once.")
    }

    private func reloadLocalRuntimes() {
        for view in localRuntimeRows.arrangedSubviews { localRuntimeRows.removeArrangedSubview(view); view.removeFromSuperview() }
        var rows: [NSView] = []
        for (index, status) in localModels.statuses.enumerated() where status.isRunning || status.isInstalled || !status.models.isEmpty || status.runtime.key.hasPrefix("custom:") {
            let detail: String
            var controls: [NSView] = []
            if status.isRunning {
                let names = status.models.map(\.name)
                detail = names.isEmpty ? "Running, but no chat models are downloaded yet."
                    : "\(names.count) model\(names.count == 1 ? "" : "s"): " + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? "…" : "")
            } else if localModels.canStart(status.runtime) {
                let names = status.models.map(\.name)
                detail = names.isEmpty ? "Installed, not running. Starts automatically when needed."
                    : "Downloaded · loads when needed: " + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? "…" : "")
                let start = NSButton(title: "Start", target: self, action: #selector(startLocalRuntime(_:)))
                start.bezelStyle = .rounded; start.font = Typography.interface; start.tag = index
                controls = [start]
            } else if status.runtime.key.hasPrefix("custom:") {
                detail = "Not answering at \(status.runtime.baseURL.absoluteString)."
                let remove = NSButton(title: "Remove", target: self, action: #selector(removeLocalEndpoint(_:)))
                remove.bezelStyle = .rounded; remove.font = Typography.interface; remove.tag = index
                controls = [remove]
            } else {
                detail = status.isInstalled
                    ? "Open \(status.runtime.name) and turn on its local server to use its models here."
                    : "\(status.models.count) downloaded model(s) found. Install \(status.runtime.name) to use them."
            }
            rows.append(row(status.runtime.name, detail: detail, controls: controls))
        }
        if rows.isEmpty {
            rows.append(row(localModels.lastRefresh == nil ? "Looking for local models…" : "No local model runtime found",
                            detail: "ThoughtStream scans Ollama and LM Studio model folders and checks local servers including Jan and llama.cpp. Download a model in a supported runtime, then choose Look Again.",
                            controls: []))
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox(); line.boxType = .separator
                localRuntimeRows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: localRuntimeRows.widthAnchor).isActive = true
            }
            localRuntimeRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: localRuntimeRows.widthAnchor).isActive = true
        }
        let count = localModels.models.count
        localScanStatus.stringValue = localModels.lastRefresh == nil ? "" : count == 0 ? "No models available" : "\(count) model\(count == 1 ? "" : "s") available"
    }

    private func scanLocalModels() {
        guard localScan == nil else { return }
        localScanStatus.stringValue = "Looking…"
        localScan = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.localModels.refresh()
            self.localScan = nil
            self.reloadLocalRuntimes()
        }
    }
    @objc private func rescanLocalModels() { scanLocalModels() }
    @objc private func offlineFallbackChanged(_ sender: NSSwitch) { localModels.usesLocalModelsOffline = sender.state == .on }
    @objc private func localContextChanged(_ sender: NSPopUpButton) {
        if let length = sender.selectedItem?.representedObject as? Int { localModels.contextLength = length }
    }
    @objc private func startLocalRuntime(_ sender: NSButton) {
        guard localModels.statuses.indices.contains(sender.tag) else { return }
        let runtime = localModels.statuses[sender.tag].runtime
        sender.isEnabled = false; sender.title = "Starting…"
        localScanStatus.stringValue = "Starting \(runtime.name)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.localModels.startRuntime(runtime)
            self.reloadLocalRuntimes()
            if !started { self.localScanStatus.stringValue = "\(runtime.name) did not start. Open it yourself, then Look Again." }
        }
    }
    @objc private func addLocalEndpoint() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add a model server"
        alert.informativeText = "Enter the address of an OpenAI-compatible server, such as MLX or llama.cpp on this Mac or your network. Ollama, LM Studio and Jan on this Mac are found automatically."
        alert.addButton(withTitle: "Add Server"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "192.168.1.20:8080"
        field.setAccessibilityLabel("Server address")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let runtime = LocalRuntime.custom(field.stringValue) else {
                self.localScanStatus.stringValue = "That is not an address such as 192.168.1.20:8080"
                return
            }
            var saved = UserDefaults.standard.stringArray(forKey: LocalRuntime.customEndpointsKey) ?? []
            let address = runtime.baseURL.absoluteString
            if !saved.contains(address) { saved.append(address) }
            UserDefaults.standard.set(saved, forKey: LocalRuntime.customEndpointsKey)
            self.scanLocalModels()
        }
    }
    @objc private func removeLocalEndpoint(_ sender: NSButton) {
        guard localModels.statuses.indices.contains(sender.tag) else { return }
        let address = localModels.statuses[sender.tag].runtime.baseURL.absoluteString
        let saved = (UserDefaults.standard.stringArray(forKey: LocalRuntime.customEndpointsKey) ?? []).filter {
            LocalRuntime.custom($0)?.baseURL.absoluteString != address
        }
        UserDefaults.standard.set(saved, forKey: LocalRuntime.customEndpointsKey)
        scanLocalModels()
    }

    func setTabsOnly(_ enabled: Bool) {
        paneLayoutSection?.isHidden = enabled
        tabsOnlyNote?.isHidden = !enabled
    }

    private func buildLayout(in panel: NSWindow) {
        let root = WorkspaceSurface()
        let content = NSViewController()
        content.view = root
        panel.contentViewController = content
        // Page fitting sizes must not shrink the root when categories change.
        if let guide = panel.contentLayoutGuide as? NSLayoutGuide {
            root.widthAnchor.constraint(equalTo: guide.widthAnchor).isActive = true
        }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        let sidebarTitle = NSTextField(labelWithString: "Settings")
        sidebarTitle.font = Typography.section
        sidebarTitle.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        navigation.addTableColumn(column)
        navigation.headerView = nil
        navigation.rowHeight = 36
        navigation.intercellSpacing = NSSize(width: 0, height: 4)
        navigation.style = .sourceList
        navigation.backgroundColor = .clear
        navigation.focusRingType = .default
        navigation.allowsEmptySelection = false
        navigation.dataSource = self
        navigation.delegate = self
        navigation.setAccessibilityLabel("Settings categories")
        let navigationScroll = NSScrollView()
        navigationScroll.drawsBackground = false
        navigationScroll.documentView = navigation

        let appName = NSTextField(labelWithString: "ThoughtStream")
        appName.font = Typography.section
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: version.isEmpty ? "" : "Version \(version)")
        versionLabel.font = Typography.metadata
        versionLabel.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [appName, versionLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 3

        pageTitle.font = Typography.pageTitle
        pageTitle.textColor = FeedPalette.text
        pageTitle.setAccessibilityRole(.staticText)
        let headerLine = NSBox()
        headerLine.boxType = .separator
        let sidebarLine = NSBox()
        sidebarLine.boxType = .separator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = pageDocument
        pageDocument.translatesAutoresizingMaskIntoConstraints = false

        for view in [sidebar, sidebarLine, pageTitle, headerLine, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [sidebarTitle, navigationScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 184),
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 23),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            navigationScroll.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 14),
            navigationScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            navigationScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            navigationScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            sidebarLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarLine.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarLine.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarLine.widthAnchor.constraint(equalToConstant: 1),
            pageTitle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            pageTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            headerLine.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 18),
            headerLine.heightAnchor.constraint(equalToConstant: 1),
            headerLine.leadingAnchor.constraint(equalTo: sidebarLine.trailingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebarLine.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Page.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = Page.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let label = NSTextField(labelWithString: page.rawValue)
        label.font = Typography.interface
        cell.imageView = icon
        cell.textField = label
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard Page.allCases.indices.contains(navigation.selectedRow) else { return }
        showPage(Page.allCases[navigation.selectedRow])
    }

    private func showPage(_ page: Page) {
        guard let content = pages[page] else { return }
        NSLayoutConstraint.deactivate(pageConstraints)
        pageDocument.subviews.forEach { $0.removeFromSuperview() }
        pageTitle.stringValue = page.rawValue
        if page == .localModels, scansLocalModelsWhenShown { scanLocalModels() }
        pageDocument.addSubview(content)
        pageConstraints = [
            content.leadingAnchor.constraint(equalTo: pageDocument.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: pageDocument.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: pageDocument.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: pageDocument.bottomAnchor, constant: -28)
        ]
        NSLayoutConstraint.activate(pageConstraints)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func page(_ sections: [NSView], note: String) -> NSStackView {
        let noteLabel = text(note, secondary: true)
        let stack = NSStackView(views: sections + [noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let heading = text(title)
        heading.font = Typography.interfaceEmphasis
        heading.setAccessibilityRole(.staticText)
        let card = SettingsGroupView()
        let contents = NSStackView()
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 0
        contents.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                contents.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
            }
            contents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        let host = card
        host.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            contents.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            contents.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
            contents.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -2)
        ])
        let stack = NSStackView(views: [heading, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func row(_ title: String, detail: String, controls: [NSView]) -> NSView {
        row(title, detailView: text(detail, secondary: true), controls: controls)
    }

    private func row(_ title: String, detailView: NSTextField, controls: [NSView]) -> NSView {
        let labels = NSStackView(views: [text(title), detailView])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in labels.arrangedSubviews { label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true }
        for control in controls { control.setContentHuggingPriority(.required, for: .horizontal) }
        let controlStack = NSStackView(views: controls)
        controlStack.orientation = .horizontal
        controlStack.distribution = .fill
        controlStack.spacing = 8
        controlStack.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [labels, controlStack])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        // Wrapping labels can grow after the stack's first fitting pass. Keep
        // the row padding tied to their actual height, not that initial estimate.
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 28),
            row.heightAnchor.constraint(greaterThanOrEqualTo: controlStack.heightAnchor, constant: 28)
        ])
        return row
    }

    private func text(_ string: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.attributedStringValue = Typography.wrappingText(string, font: secondary ? Typography.caption : Typography.interface, color: secondary ? FeedPalette.muted : FeedPalette.text)
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

private final class FlippedSettingsView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsGroupView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        FeedPalette.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
