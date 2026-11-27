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
            case .closePane: return "Close chat"
            case .singlePane: return "Focus on this chat"
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

        var tint: NSColor {
            switch self {
            case .general: return FeedPalette.blue
            case .accounts: return FeedPalette.purple
            case .localModels: return FeedPalette.green
            case .chat: return FeedPalette.orange
            case .developer: return FeedPalette.muted
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Arrange your workspace."
            case .accounts: return "Connect the services you use in ThoughtStream."
            case .localModels: return "Models on your Mac and servers you connect."
            case .chat: return "Continue and manage your current conversation."
            case .developer: return "Inspect session activity and troubleshoot issues."
            }
        }
    }

    private let navigation = NSTableView()
    private let pageTitle = NSTextField(labelWithString: "General")
    private let pageSubtitle = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let pageDocument = FlippedSettingsView()
    private var pages: [Page: NSStackView] = [:]
    private var pageConstraints: [NSLayoutConstraint] = []
    private let localModels: LocalModelRegistry
    private let localRuntimeRows = NSStackView()
    private let localScanStatus = NSTextField(labelWithString: "")
    private var styleObserver: NSObjectProtocol?
    private var localObserver: NSObjectProtocol?
    private var localScan: Task<Void, Never>?
    /// Set by the workspace. Off by default, so a bare settings window never
    /// contacts a local server.
    var scansLocalModelsWhenShown = false

    init(target: AnyObject, actions: [Action: Selector], accounts: [ProviderAccountControls],
         localModels: LocalModelRegistry? = nil) {
        self.localModels = localModels ?? .shared
        let panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Settings"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 480)
        super.init(window: panel)

        func button(_ action: Action) -> NSButton {
            let control = ThemedButton(title: action.title, target: target, action: actions[action])
            control.bezelStyle = .rounded
            control.font = Typography.interface
            control.setContentHuggingPriority(.required, for: .horizontal)
            return control
        }

        let layoutSection = section("Chats", rows: [
                row("Open another chat", detail: "Keep another chat in view.",
                    controls: [button(.split), button(.stack)]),
                row("Simplify your workspace", detail: "Close this chat or focus on just one.",
                    controls: [button(.closePane), button(.singlePane)])
            ])
        pages[.general] = page([layoutSection], note: "Each chat has its own region of the screen.")

        pages[.accounts] = page(accounts.map(accountSection), note: "API keys are kept in memory until you quit.")

        pages[.localModels] = makeLocalModelsPage()

        pages[.chat] = page([
            section("Current conversation", rows: [
                row("Branch this conversation", detail: "Continue in a new chat from this point.", controls: [button(.fork)]),
                row("Pending requests", detail: "Review anything waiting for your response.", controls: [button(.requests)])
            ])
        ], note: "These actions use the focused conversation.")

        pages[.developer] = page([
            section("Diagnostics", rows: [
                row("Protocol snapshot", detail: "Inspect messages from the current session.", controls: [button(.snapshot)]),
                row("Export protocol", detail: "Save diagnostics for this session.", controls: [button(.export)])
            ])
        ], note: "Diagnostics apply to the focused conversation.")

        buildLayout(in: panel)
        navigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPage(.general)
        applyInterfaceStyle()
        styleObserver = NotificationCenter.default.addObserver(forName: InterfaceStyle.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyInterfaceStyle() }
        }
        panel.center()
        // A preferences window shouldn't take over a Space; reopen where it was left.
        panel.collectionBehavior.insert(.fullScreenNone)
        panel.setFrameAutosaveName("ThoughtStream.Settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let localObserver { NotificationCenter.default.removeObserver(localObserver) }
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    private func applyInterfaceStyle() {
        window?.appearance = InterfaceStyle.current.appearance
        if let content = window?.contentView { InterfaceTypography.apply(to: content) }
        for page in pages.values { InterfaceTypography.apply(to: page) }
    }

    // MARK: Local models

    private func makeLocalModelsPage() -> NSStackView {
        localRuntimeRows.orientation = .vertical
        localRuntimeRows.alignment = .leading
        localRuntimeRows.spacing = 0
        let runtimes = SettingsGroupView()
        localRuntimeRows.translatesAutoresizingMaskIntoConstraints = false
        runtimes.addSubview(localRuntimeRows)
        NSLayoutConstraint.activate([
            localRuntimeRows.leadingAnchor.constraint(equalTo: runtimes.leadingAnchor, constant: 18),
            localRuntimeRows.trailingAnchor.constraint(equalTo: runtimes.trailingAnchor, constant: -18),
            localRuntimeRows.topAnchor.constraint(equalTo: runtimes.topAnchor, constant: 2),
            localRuntimeRows.bottomAnchor.constraint(equalTo: runtimes.bottomAnchor, constant: -2)
        ])
        let heading = text("On this Mac")
        heading.font = Typography.interfaceEmphasis
        let rescan = ThemedButton(title: "Look Again", target: self, action: #selector(rescanLocalModels))
        rescan.bezelStyle = .rounded; rescan.font = Typography.interface
        localScanStatus.font = Typography.caption; localScanStatus.textColor = FeedPalette.muted
        localScanStatus.lineBreakMode = .byTruncatingTail
        let addServer = ThemedButton(title: "Add Server…", target: self, action: #selector(addLocalEndpoint))
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
        let context = ThemedPopUpButton()
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
                detail: "Start new chats with a model on this Mac when you’re offline.",
                controls: [fallback]),
            row("Conversation memory",
                detail: "Context size for Ollama. Larger values use more memory.",
                controls: [context])
        ])
        localObserver = NotificationCenter.default.addObserver(forName: .localModelsDidChange, object: localModels, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLocalRuntimes() }
        }
        reloadLocalRuntimes()
        return page([found, options], note: "Choose Local Model in the sidebar to start a chat. Scanning won’t load models into memory. Local models follow your chat’s file and command permissions.")
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
                let start = ThemedButton(title: "Start", target: self, action: #selector(startLocalRuntime(_:)))
                start.bezelStyle = .rounded; start.font = Typography.interface; start.tag = index
                controls = [start]
            } else if status.runtime.key.hasPrefix("custom:") {
                detail = "Not answering at \(status.runtime.baseURL.absoluteString)."
                let remove = ThemedButton(title: "Remove", target: self, action: #selector(removeLocalEndpoint(_:)))
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
            rows.append(row(localModels.lastRefresh == nil ? "Find a model on this Mac" : "No local models found",
                            detail: "Download a model in Ollama or LM Studio, or connect a local server. Then choose Look Again.",
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
        InterfaceTypography.apply(to: localRuntimeRows)
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

    private func buildLayout(in panel: NSWindow) {
        let root = WorkspaceSurface()
        root.fill = FeedPalette.canvas
        let content = NSViewController()
        content.view = root
        panel.contentViewController = content
        if let guide = panel.contentLayoutGuide as? NSLayoutGuide {
            root.widthAnchor.constraint(equalTo: guide.widthAnchor).isActive = true
        }
        let sidebar = WorkspaceSurface()
        sidebar.fill = FeedPalette.sidebar
        let sidebarTitle = NSTextField(labelWithString: "Settings")
        sidebarTitle.font = Typography.pageTitle
        sidebarTitle.textColor = FeedPalette.text

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        navigation.addTableColumn(column)
        navigation.headerView = nil
        navigation.rowHeight = 44
        navigation.intercellSpacing = NSSize(width: 0, height: 4)
        navigation.style = .plain
        navigation.backgroundColor = .clear
        navigation.focusRingType = .default
        navigation.allowsEmptySelection = false
        navigation.dataSource = self
        navigation.delegate = self
        navigation.setAccessibilityLabel("Settings categories")
        let navigationScroll = NSScrollView()
        navigationScroll.drawsBackground = false
        navigationScroll.documentView = navigation
        navigationScroll.hasVerticalScroller = true
        navigationScroll.autohidesScrollers = true

        let appName = NSTextField(labelWithString: "ThoughtStream")
        appName.font = Typography.interfaceEmphasis
        appName.textColor = FeedPalette.text
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: version.isEmpty ? "" : "Version \(version)")
        versionLabel.font = Typography.caption
        versionLabel.textColor = FeedPalette.muted
        let footer = NSStackView(views: [appName, versionLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 4

        pageTitle.font = Typography.welcomeTitle
        pageTitle.textColor = FeedPalette.text
        pageTitle.setAccessibilityRole(.staticText)
        pageSubtitle.font = Typography.interface
        pageSubtitle.textColor = FeedPalette.muted
        pageSubtitle.isSelectable = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = pageDocument
        pageDocument.translatesAutoresizingMaskIntoConstraints = false

        for view in [sidebar, pageTitle, pageSubtitle, scrollView] {
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
            sidebar.widthAnchor.constraint(equalToConstant: 204),
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 28),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            navigationScroll.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 24),
            navigationScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigationScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navigationScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24),
            pageTitle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 32),
            pageTitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            pageTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            pageSubtitle.leadingAnchor.constraint(equalTo: pageTitle.leadingAnchor),
            pageSubtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pageSubtitle.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: pageSubtitle.bottomAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Page.allCases.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsNavigationRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = Page.allCases[row]
        let cell = SettingsNavigationCell()
        let badge = SettingsCategoryIcon(symbol: page.symbol, tint: page.tint)
        let label = NSTextField(labelWithString: page.rawValue)
        label.font = Typography.interfaceEmphasis
        label.textColor = FeedPalette.text
        cell.textField = label
        for view in [badge, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        InterfaceTypography.apply(to: cell)
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
        pageSubtitle.stringValue = page.subtitle
        if page == .localModels, scansLocalModelsWhenShown { scanLocalModels() }
        pageDocument.addSubview(content)
        pageConstraints = [
            content.leadingAnchor.constraint(equalTo: pageDocument.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: pageDocument.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: pageDocument.topAnchor, constant: 0),
            content.bottomAnchor.constraint(equalTo: pageDocument.bottomAnchor, constant: -28)
        ]
        InterfaceTypography.apply(to: content)
        NSLayoutConstraint.activate(pageConstraints)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func page(_ sections: [NSView], note: String) -> NSStackView {
        let noteLabel = text(note, secondary: true)
        let stack = NSStackView(views: sections + [noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let heading = text(title)
        heading.font = Typography.interfaceEmphasis
        heading.textColor = FeedPalette.muted
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
            contents.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            contents.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
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

    private func accountSection(_ controls: ProviderAccountControls) -> NSView {
        let local = NSStackView(views: [text("Local CLI sign-in"), NSView(), controls.connectLocal])
        let entry = NSStackView(views: [controls.keyField, controls.connectKey])
        let footer = NSStackView(views: [controls.status, NSView(), controls.getKey])
        for line in [local, entry, footer] {
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
        }
        local.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        let keyRow = NSStackView(views: [entry, footer])
        keyRow.orientation = .vertical
        keyRow.spacing = 6
        keyRow.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        for line in [entry, footer] { line.widthAnchor.constraint(equalTo: keyRow.widthAnchor).isActive = true }
        return section(controls.provider.title, rows: [local, keyRow])
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
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        // Wrapping labels can grow after the stack's first fitting pass. Keep
        // the row padding tied to their actual height, not that initial estimate.
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 36),
            row.heightAnchor.constraint(greaterThanOrEqualTo: controlStack.heightAnchor, constant: 36)
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

private final class SettingsNavigationCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { textField?.textColor = FeedPalette.text }
    }
}

private final class SettingsNavigationRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        FeedPalette.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class SettingsCategoryIcon: NSView {
    private let tint: NSColor

    init(symbol: String, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.contentTintColor = tint
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsGroupView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        FeedPalette.canvas.setFill()
        shape.fill()
        FeedPalette.line.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
