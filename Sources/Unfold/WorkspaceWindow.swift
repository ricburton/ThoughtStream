import AppKit

@MainActor
final class WorkspaceWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuDelegate {
    private var sessions: [Session]
    var hasActiveWork: Bool { sessions.contains { $0.turn != nil || $0.queueWorker != nil } }
    private var selected: Int?
    let projectHistoryTable = NSTableView()
    private let conversationSidebar = NSTableView()
    private var conversationIDs: [UUID] = []
    private var sidebarConversationOrder: [UUID] = []
    private let sidebarSplit = SidebarSplitView()
    private let streamSplit = NSSplitViewController()
    private let tabSplitHost = TabSplitHostView()
    private let localSearch = WorkspaceHistorySearch()
    private let threadSummaries = ChatThreadSummaryCoordinator()
    private var searchOpenTask: Task<Void, Never>?
    private var primaryColumn = ChatColumn()
    private var columnStore: [UUID: ChatColumn] = [:]
    private var paneLayout: PaneLayout?
    private var layoutController: PaneLayoutController?
    private(set) var layoutMode: WorkspaceLayoutMode = .panes
    private var secondaryColumn: ChatColumn? { columns.dropFirst().first }
    private var drafts: [UUID: String] = [:]
    private var attachmentDrafts: [UUID: [ChatAttachment]] = [:]
    private var closedTabs: [UUID] = []
    private var streamStates: [UUID: StreamViewState] = [:]
    private let stateStore: WorkspaceStateStore
    private var pendingStateSave: DispatchWorkItem?
    private var restoringWorkspace = true
    private var projectSelection: String?
    private var projectStates: [String: ProjectViewState] = [:]
    private var projectHistory: ProjectHistory?
    private let historyEnabled: Bool
    private var historySearches: [String: Task<Void, Never>] = [:]
    private var projectHistoryEntries: [String: [ProjectHistoryEntry]] = [:]
    private var projectHistoryErrors: [String: String] = [:]
    private var projectRows: [ProjectHistoryRow] = []
    private var historyLoads: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var switchingProject = false
    private var activeColumnID: UUID? { didSet { refreshPaneFocus() } }
    private var splitResizeObserver: NSObjectProtocol?
    private var updatingPaneWindowMinimum = false
    private var styleObserver: NSObjectProtocol?
    private var offlineIndicator: OfflineWindowIndicator?
    private var prompt: ComposerTextView { primaryColumn.prompt }
    private let heading = NSTextField(labelWithString: "ThoughtStream")
    private let loginButton = NSButton(title: "Connect ChatGPT", target: nil, action: nil)
    private let claudeConnectButton = NSButton(title: "Connect Claude", target: nil, action: nil)
    private let claudeAccountStatus = NSTextField(wrappingLabelWithString: "Use your Claude Code sign-in on this Mac.")
    private var claudeSignInTask: Task<Void, Never>?
    private let activity = NSProgressIndicator()
    private var activityTimer: Timer?
    private var startedAt: Date?
    private let providerPicker = NSPopUpButton()
    private let modelCatalog: ModelCatalog
    private let automaticallyDiscoverModels: Bool
    private var modelRefreshTasks: [AgentProvider: Task<Void, Never>] = [:]
    private var modelRefreshAttempts: [AgentProvider: Date] = [:]
    private var inferenceSession: Session? {
        if let id = activeColumnID, let column = columnStore[id] { return column.session }
        return session
    }
    private var currentProvider: AgentProvider { inferenceSession?.provider ?? AgentProvider.selected }
    private var currentInferenceSettings: InferenceSettings {
        inferenceSession?.inferenceSettings ?? InferenceSettings.load(provider: currentProvider)
    }
    private let model = NSPopUpButton()
    private let effort = NSPopUpButton()
    private let speed = NSPopUpButton()
    private let access = NSButton(title: "", target: nil, action: nil)
    private var sendButton: NSButton { primaryColumn.sendButton }
    private let status = NSTextField(labelWithString: "Choose a project or open the sample feed")
    private var activePane: StreamPane?
    private var models: [[String: Any]] = []
    private var protocolWindow: NSWindow?
    private var settingsController: SettingsWindowController?
    private var sampleTimer: Timer?
    private var samplePane: StreamPane?
    private struct PendingInput {
        let session: Session
        let id: Any
        let method: String
        let params: [String: Any]
        var key: String { session.id.uuidString + ":" + String(describing: id) }
    }
    private var inputQueue: [PendingInput] = []
    private var deferredInputs = Set<String>()
    private var activeInput: (request: PendingInput, alert: NSAlert)?
    private var session: Session? { selected.flatMap { sessions.indices.contains($0) ? sessions[$0] : nil } }

    init(restoredSessions: [Session]? = nil, stateStore: WorkspaceStateStore? = nil, history: ProjectHistory? = nil, modelCatalog: ModelCatalog? = nil) {
        self.modelCatalog = modelCatalog ?? ModelCatalog(defaults: restoredSessions == nil ? .standard : nil)
        automaticallyDiscoverModels = restoredSessions == nil
        self.stateStore = stateStore ?? WorkspaceStateStore()
        projectHistory = history
        historyEnabled = restoredSessions == nil || history != nil
        let saved = restoredSessions == nil || stateStore != nil ? self.stateStore.load() : nil
        sessions = restoredSessions ?? Session.restored()
        // Preserve the existing order on migration, then only prepend new chats.
        sidebarConversationOrder = saved?.sidebarConversationOrder
            ?? sessions.filter(\.hasStartedConversation).map(\.id)
        let window = ChatWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.backgroundColor = FeedPalette.canvas
        window.appearance = InterfaceStyle.current.appearance
        window.title = "ThoughtStream"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 860, height: 600); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        layoutMode = saved?.layoutMode ?? .panes
        window.delegate = self
        window.onInteraction = { [weak self] view in
            guard let self, let column = self.columns.first(where: { view.isDescendant(of: $0.view) }),
                  self.activeColumnID != column.columnID else { return }
            self.activeColumnID = column.columnID
            self.activePane = column.stream
            self.refreshProviderControls()
            self.scheduleStateSave()
        }
        window.onResponderChange = { [weak self] in self?.refreshPaneFocus() }
        drafts = saved?.drafts ?? [:]
        attachmentDrafts = saved?.attachmentDrafts ?? [:]
        streamStates = saved?.streams ?? [:]
        closedTabs = saved?.closedTabs ?? []
        projectStates = saved?.projects ?? [:]
        // Migrate the previously saved single workspace into its project.
        if let id = saved?.primary, let s = sessions.first(where: { $0.id == id }), projectStates[s.project.path] == nil {
            projectStates[s.project.path] = ProjectViewState(primary: id, secondary: saved?.secondary)
        }
        if let fraction = saved?.sidebarChatFraction, fraction.isFinite {
            sidebarSplit.chatFraction = CGFloat(min(0.9, max(0.1, fraction)))
        }
        build()
        offlineIndicator = OfflineWindowIndicator(window: window)
        sidebarSplit.onResize = { [weak self] in self?.scheduleStateSave() }
        if let frame = saved?.windowFrame {
            let rect = NSRectFromString(frame)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { window.setFrame(rect, display: false) }
        }
        let initialProject = saved?.selectedProject ?? saved?.primary.flatMap { id in sessions.first { $0.id == id }?.project.path }
        if let path = initialProject, projects.contains(where: { $0.path == path }) { selectProject(path) }
        else if let s = sessions.first(where: { !closedTabs.contains($0.id) }) { selectProject(s.project.path) }
        else { showWelcome() }
        splitResizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: streamSplit.splitView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleStateSave() }
        }
        styleObserver = NotificationCenter.default.addObserver(forName: InterfaceStyle.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyInterfaceStyle() }
        }
        restoringWorkspace = false
        for session in sessions { configureQueue(for: session) }
        // Reattach to existing work without adding messages to the conversation.
        for session in sessions { session.reconnectAfterRestart() }
        refreshNavigation()
        for project in projects where projectStates[project.path]?.historyExpanded == true { discoverHistory(in: project.path) }
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private func build() {
        let outer = NSSplitViewController(); outer.splitView.isVertical = true; outer.splitView.dividerStyle = .thin
        let rail = NSViewController(); rail.view = WorkspaceSurface(fill: FeedPalette.sidebar)
        let new = NSButton(title: "", target: self, action: #selector(newChat(_:)))
        new.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        new.imagePosition = .imageOnly; new.isBordered = false
        new.contentTintColor = FeedPalette.muted
        new.toolTip = "New chat (⌘N)"; new.setAccessibilityLabel("New chat")
        let chatsTitle = NSTextField(labelWithString: "Chats")
        chatsTitle.font = Typography.section
        chatsTitle.textColor = FeedPalette.muted
        let sidebarHeader = NSStackView(views: [chatsTitle, NSView(), new])
        sidebarHeader.orientation = .horizontal; sidebarHeader.alignment = .centerY
        sidebarHeader.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        localSearch.field.font = Typography.interface
        localSearch.field.controlSize = .regular
        let liveScroll = NSScrollView(); liveScroll.hasVerticalScroller = true; liveScroll.drawsBackground = false
        liveScroll.autohidesScrollers = true; liveScroll.scrollerStyle = .overlay
        conversationSidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation")))
        conversationSidebar.headerView = nil; conversationSidebar.rowHeight = SidebarMetrics.rowHeight; conversationSidebar.style = .plain
        conversationSidebar.backgroundColor = .clear; conversationSidebar.intercellSpacing = .zero
        conversationSidebar.focusRingType = .default
        conversationSidebar.allowsEmptySelection = true
        conversationSidebar.delegate = self; conversationSidebar.dataSource = self
        conversationSidebar.target = self; conversationSidebar.action = #selector(conversationSelected)
        conversationSidebar.setAccessibilityLabel("Live conversations")
        liveScroll.documentView = conversationSidebar
        let tableScroll = NSScrollView(); tableScroll.hasVerticalScroller = true; tableScroll.drawsBackground = false
        tableScroll.autohidesScrollers = true; tableScroll.scrollerStyle = .overlay
        projectHistoryTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        projectHistoryTable.headerView = nil; projectHistoryTable.rowHeight = SidebarMetrics.rowHeight; projectHistoryTable.style = .plain
        projectHistoryTable.backgroundColor = .clear; projectHistoryTable.intercellSpacing = .zero
        projectHistoryTable.focusRingType = .default
        projectHistoryTable.delegate = self; projectHistoryTable.dataSource = self; projectHistoryTable.target = self; projectHistoryTable.action = #selector(sidebarSelected)
        projectHistoryTable.setAccessibilityLabel("Projects")
        tableScroll.documentView = projectHistoryTable
        let inferenceControls = makeInferenceControls()
        let open = SidebarActionButton(title: "Open project…", target: self, action: #selector(openProject(_:)))
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); open.imagePosition = .imageLeading
        let projectsTitle = NSTextField(labelWithString: "Projects")
        projectsTitle.font = Typography.section
        projectsTitle.textColor = FeedPalette.muted
        // Live chats above, projects (with their saved conversations) below.
        let sections: [(NSTextField?, NSScrollView)] = [(nil, liveScroll), (projectsTitle, tableScroll)]
        for (heading, scroll) in sections {
            let section = NSView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(scroll)
            if let heading {
                heading.translatesAutoresizingMaskIntoConstraints = false
                section.addSubview(heading)
                NSLayoutConstraint.activate([
                    heading.topAnchor.constraint(equalTo: section.topAnchor, constant: 2),
                    heading.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 8),
                    heading.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -8),
                    scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6)
                ])
            } else {
                scroll.topAnchor.constraint(equalTo: section.topAnchor).isActive = true
            }
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: section.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: section.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: section.bottomAnchor)
            ])
            sidebarSplit.addArrangedSubview(section)
        }
        let railStack = NSStackView(views: [sidebarHeader, localSearch.field, open, sidebarSplit, inferenceControls])
        railStack.orientation = .vertical; railStack.alignment = .leading; railStack.spacing = 4
        railStack.setCustomSpacing(10, after: sidebarHeader)
        railStack.setCustomSpacing(12, after: localSearch.field)
        railStack.setCustomSpacing(12, after: open)
        railStack.setCustomSpacing(12, after: sidebarSplit)
        railStack.translatesAutoresizingMaskIntoConstraints = false; rail.view.addSubview(railStack)
        NSLayoutConstraint.activate([
            sidebarSplit.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            sidebarSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            open.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            open.heightAnchor.constraint(equalToConstant: 28),
            railStack.leadingAnchor.constraint(equalTo: rail.view.leadingAnchor, constant: 12),
            railStack.trailingAnchor.constraint(equalTo: rail.view.trailingAnchor, constant: -12),
            railStack.topAnchor.constraint(equalTo: rail.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            railStack.bottomAnchor.constraint(equalTo: rail.view.bottomAnchor, constant: -10),
            sidebarHeader.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            sidebarHeader.heightAnchor.constraint(equalToConstant: 28),
            new.widthAnchor.constraint(equalToConstant: 28), new.heightAnchor.constraint(equalToConstant: 28),
            localSearch.field.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            localSearch.field.heightAnchor.constraint(equalToConstant: 36),
            inferenceControls.widthAnchor.constraint(equalTo: railStack.widthAnchor)
        ])
        // The system sidebar behavior wraps this in a floating glass surface.
        // Use a regular split item so our flat background meets the window edge.
        let sidebarItem = NSSplitViewItem(viewController: rail)
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 280
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.canCollapse = false
        outer.addSplitViewItem(sidebarItem)
        let body = NSViewController(); body.view = WorkspaceSurface()
        heading.font = .systemFont(ofSize: 17, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        loginButton.target = self; loginButton.action = #selector(signIn(_:))
        let settings = NSButton(title: "Settings", target: self, action: #selector(showSettings(_:)))
        settings.bezelStyle = .rounded
        settings.controlSize = .regular
        settings.font = .systemFont(ofSize: 13, weight: .medium)
        settings.contentTintColor = FeedPalette.text
        settings.toolTip = "Settings (⌘,)"
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.image = settings.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        settings.widthAnchor.constraint(equalToConstant: 110).isActive = true
        settings.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let header = NSStackView(views: [activity, NSView(), settings]); header.orientation = .horizontal; header.spacing = 10
        header.alignment = .centerY
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        activity.style = .spinning; activity.controlSize = .small; activity.isDisplayedWhenStopped = false
        streamSplit.splitView.isVertical = true; streamSplit.splitView.dividerStyle = .thin; body.addChild(streamSplit)
        configure(primaryColumn)
        columnStore[primaryColumn.columnID] = primaryColumn
        paneLayout = .pane(primaryColumn.columnID)
        streamSplit.view.translatesAutoresizingMaskIntoConstraints = false
        tabSplitHost.addSubview(streamSplit.view, positioned: .below, relativeTo: nil)
        localSearch.view.translatesAutoresizingMaskIntoConstraints = false
        tabSplitHost.addSubview(localSearch.view)
        localSearch.onVisibility = { [weak self] visible in
            guard let self else { return }
            self.streamSplit.view.isHidden = visible
            if visible {
                for column in self.columns { self.rememberDraft(column) }
                if self.historyEnabled { self.localSearch.refresh() }
            } else { self.searchOpenTask?.cancel() }
        }
        localSearch.onOpen = { [weak self] result in self?.openSearchResult(result) }
        if historyEnabled { localSearch.refresh() }
        NSLayoutConstraint.activate([
            localSearch.view.leadingAnchor.constraint(equalTo: tabSplitHost.leadingAnchor),
            localSearch.view.trailingAnchor.constraint(equalTo: tabSplitHost.trailingAnchor),
            localSearch.view.topAnchor.constraint(equalTo: tabSplitHost.topAnchor),
            localSearch.view.bottomAnchor.constraint(equalTo: tabSplitHost.bottomAnchor),
            streamSplit.view.leadingAnchor.constraint(equalTo: tabSplitHost.leadingAnchor),
            streamSplit.view.trailingAnchor.constraint(equalTo: tabSplitHost.trailingAnchor),
            streamSplit.view.topAnchor.constraint(equalTo: tabSplitHost.topAnchor),
            streamSplit.view.bottomAnchor.constraint(equalTo: tabSplitHost.bottomAnchor)
        ])
        for child in [header, tabSplitHost] {
            child.translatesAutoresizingMaskIntoConstraints = false; body.view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.view.safeAreaLayoutGuide.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: body.view.leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: body.view.trailingAnchor, constant: -18), header.heightAnchor.constraint(equalToConstant: 40),
            tabSplitHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2), tabSplitHost.leadingAnchor.constraint(equalTo: body.view.leadingAnchor), tabSplitHost.trailingAnchor.constraint(equalTo: body.view.trailingAnchor), tabSplitHost.bottomAnchor.constraint(equalTo: body.view.bottomAnchor)
        ])
        outer.addSplitViewItem(NSSplitViewItem(viewController: body)); window?.contentViewController = outer
    }
    private func openSearchResult(_ result: LocalHistorySearch.Result) {
        searchOpenTask?.cancel()
        let requestedQuery = localSearch.field.stringValue
        searchOpenTask = Task { [weak self] in
            guard let self, let document = await self.localSearch.load(result), !Task.isCancelled,
                  self.localSearch.isSearching, self.localSearch.field.stringValue == requestedQuery else { return }
            let provider = AgentProvider(rawValue: document.provider) ?? .codex
            var target = self.sessions.first { session in
                if let id = document.sessionID { return session.id.uuidString == id }
                return session.provider == provider && session.thread != nil && session.thread == document.thread
            }
            if target == nil {
                let added = Session(project: URL(fileURLWithPath: document.project), title: result.document.title, thread: document.thread, provider: provider)
                self.sessions.append(added); target = added
            }
            guard let target, let index = self.sessions.firstIndex(where: { $0 === target }) else { return }
            if document.sessionID == nil { target.importSearchHistory(document.records) }
            self.localSearch.dismiss()
            self.select(index, in: self.primaryColumn)
            let pane = self.columns.first { $0.session === target }?.stream ?? self.primaryColumn.stream
            let original = document.records.first { $0.text == result.text }
                ?? (document.records.indices.contains(result.record) ? document.records[result.record] : nil)
            let row = target.history.firstIndex { record in
                if let item = original?.itemID, record.itemID == item { return true }
                return original.map { record.kind == $0.kind && record.text == $0.text } ?? false
            } ?? target.history.firstIndex { $0.text.localizedCaseInsensitiveContains(result.needle) } ?? 0
            pane.revealSearchMatch(record: row, needle: result.needle)
            self.window?.makeFirstResponder(pane.view)
        }
    }

    private func makeInferenceControls() -> NSView {
        let initial = InferenceSettings.load(provider: currentProvider)
        providerPicker.addItems(withTitles: AgentProvider.allCases.map(\.label))
        providerPicker.selectItem(at: AgentProvider.allCases.firstIndex(of: currentProvider) ?? 0)
        providerPicker.target = self; providerPicker.action = #selector(providerSelected)
        providerPicker.setAccessibilityLabel("Agent provider")
        providerPicker.toolTip = "Choose Codex or Claude Code. Existing conversations keep their provider."
        model.addItem(withTitle: initial.displayName); model.lastItem?.representedObject = initial.model
        model.target = self; model.action = #selector(modelSelected)
        model.menu?.delegate = self
        model.autoenablesItems = false
        model.setAccessibilityLabel("Model")
        model.toolTip = "Choose the model for new messages"
        effort.addItem(withTitle: initial.effort); effort.target = self; effort.action = #selector(settingsChanged)
        effort.setAccessibilityLabel("Reasoning effort")
        effort.toolTip = "Reasoning effort"
        refreshSpeeds(preferred: initial.tier)
        speed.target = self; speed.action = #selector(settingsChanged)
        speed.setAccessibilityLabel("Speed")
        speed.toolTip = "Faster tiers can use more of your allowance. Availability depends on your account."
        for control in [providerPicker, model, effort, speed] {
            control.controlSize = .small
            control.font = Typography.interface
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        access.title = AccessMode.selected.label; access.target = self; access.action = #selector(changeAccess(_:)); access.bezelStyle = .inline
        access.font = Typography.caption
        access.contentTintColor = FeedPalette.muted
        access.toolTip = "Change permissions for new work. Changing access stops connected runtimes."
        access.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tuning = NSStackView(views: [effort, speed])
        tuning.orientation = .horizontal; tuning.spacing = 6; tuning.distribution = .fillEqually
        let footer = NSStackView(views: [providerPicker, model, tuning, access])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 6
        footer.setCustomSpacing(10, after: tuning)
        NSLayoutConstraint.activate([
            providerPicker.widthAnchor.constraint(equalTo: footer.widthAnchor),
            model.widthAnchor.constraint(equalTo: footer.widthAnchor),
            tuning.widthAnchor.constraint(equalTo: footer.widthAnchor),
            access.widthAnchor.constraint(lessThanOrEqualTo: footer.widthAnchor)
        ])
        return footer
    }
    @objc func newChat(_ sender: Any?) { newChat(in: focusedColumn) }
    private func newChat(in column: ChatColumn) {
        let folder = projectSelection.map { URL(fileURLWithPath: $0) } ?? Session.base.deletingLastPathComponent().appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessions.append(Session(project: folder, provider: AgentProvider.selected)); select(sessions.count - 1, in: column); window?.makeFirstResponder(focusedColumn.prompt)
    }
    private func showWelcome() {
        selected = nil; heading.stringValue = "Room to think"; status.stringValue = "Ready when you are"
        for item in streamSplit.splitViewItems { streamSplit.removeSplitViewItem(item) }
        let welcome = WelcomePane()
        welcome.onNewChat = { [weak self] in self?.newChat(nil) }
        welcome.onOpenProject = { [weak self] in self?.openProject(nil) }
        streamSplit.addSplitViewItem(NSSplitViewItem(viewController: welcome))
    }

    private func bind(_ session: Session) {
        configureQueue(for: session)
        session.onStatus = { [weak self, weak session] state in
            guard let self = self else { return }
            for column in self.columns where column.session === session {
                column.stream.status.stringValue = state; column.refresh()
            }
            if self.session === session { self.status.stringValue = state; self.refreshActivity() }
            self.refreshNavigation()
        }
        session.onRequest = { [weak self, weak session] id, method, params in
            guard let self = self, let session = session else { return }
            let request = PendingInput(session: session, id: id, method: method, params: params)
            guard !self.inputQueue.contains(where: { $0.key == request.key }) else { return }
            session.report(.tool, "\(method)\n" + Session.pretty(params))
            self.inputQueue.append(request); self.presentNextRequest()
        }
        session.onRequestResolved = { [weak self, weak session] id in
            guard let self = self, let session = session else { return }
            let key = session.id.uuidString + ":" + id
            self.inputQueue.removeAll { $0.key == key }; self.deferredInputs.remove(key)
            if let active = self.activeInput, active.request.key == key,
               let sheet = active.alert.window.sheetParent { sheet.endSheet(active.alert.window) }
        }
        session.onModels = { [weak self, weak session] list in
            guard let self, let session else { return }
            self.modelCatalog.update(list, for: session.provider)
            if self.currentProvider == session.provider { self.populateModelList(self.modelCatalog.models(for: session.provider)) }
        }
    }
    func applyModelList(_ list: [[String: Any]]) {
        modelCatalog.update(list, for: currentProvider)
        populateModelList(modelCatalog.models(for: currentProvider))
    }
    private func populateModelList(_ list: [[String: Any]]) {
        models = list
        let current = currentInferenceSettings
        self.model.removeAllItems()
        for item in list {
            let identifier = item["model"] as? String ?? item["id"] as? String ?? ""
            guard !identifier.isEmpty else { continue }
            let entry = NSMenuItem(title: item["displayName"] as? String ?? identifier, action: nil, keyEquivalent: "")
            entry.representedObject = identifier
            self.model.menu?.addItem(entry)
        }
        if let item = self.model.itemArray.first(where: { $0.representedObject as? String == current.model }) {
            self.model.select(item)
        } else {
            // Keep the explicit selection; an unavailable model must report an error, never silently fall back.
            let entry = NSMenuItem(title: current.displayName, action: nil, keyEquivalent: "")
            entry.representedObject = current.model
            self.model.menu?.addItem(entry)
            self.model.select(entry)
        }
        self.refreshEfforts(preferred: current.effort)
        self.refreshSpeeds(preferred: current.tier)
        model.menu?.addItem(.separator())
        let add = NSMenuItem(title: "Add Model…", action: #selector(addModelSelected), keyEquivalent: "")
        add.target = self; model.menu?.addItem(add)
        let refreshing = modelRefreshTasks[currentProvider] != nil
        let refresh = NSMenuItem(title: refreshing ? "Refreshing Models…" : "Refresh Models", action: #selector(refreshModelsSelected), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = !refreshing; model.menu?.addItem(refresh)
    }

    private var columns: [ChatColumn] {
        paneLayout?.ids.compactMap { columnStore[$0] } ?? [primaryColumn]
    }
    private func refreshPaneFocus() {
        for column in columns {
            column.updateFocusAppearance(active: column.columnID == activeColumnID)
        }
    }
    private func renderLayout() {
        guard let paneLayout else { return }
        for column in columns { column.view.removeFromSuperview(); column.removeFromParent() }
        for item in streamSplit.splitViewItems { streamSplit.removeSplitViewItem(item) }
        if layoutMode == .tabs {
            layoutController = nil
            streamSplit.addSplitViewItem(NSSplitViewItem(viewController: primaryColumn))
            if let window {
                let frame = window.frame
                window.minSize = NSSize(width: 860, height: 600)
                if window.frame != frame { window.setFrame(frame, display: false) }
            }
            window?.contentView?.layoutSubtreeIfNeeded()
            refreshPaneFocus()
            return
        }
        let controller = PaneLayoutController(layout: paneLayout, columns: columnStore, configureHost: { [weak self] host, column in
            host.validate = { [weak self, weak column] payload, side in
                guard let column else { return false }
                return self?.canDropTab(payload, on: side, in: column) == true
            }
            host.onDrop = { [weak self, weak column] payload, side in
                guard let column else { return false }
                return self?.dropTab(payload, on: side, in: column) == true
            }
        }, resized: { [weak self] in
            self?.updateSplitAvailability()
            self?.scheduleStateSave()
        })
        layoutController = controller
        streamSplit.addSplitViewItem(NSSplitViewItem(viewController: controller))
        window?.contentView?.layoutSubtreeIfNeeded()
        controller.restoreFractions()
        // Pane count/style determines the minimum. Recomputing it during a
        // window resize reads transient view sizes and feeds back into resizing.
        updatePaneWindowMinimum()
        refreshPaneFocus()
    }
    private var projects: [URL] {
        var activity: [String: (project: URL, working: Bool, latest: Date)] = [:]
        for session in sessions {
            let path = session.project.path
            var entry = activity[path] ?? (session.project, false, .distantPast)
            entry.working = entry.working || session.turn != nil
            entry.latest = max(entry.latest, session.lastConversationActivity ?? .distantPast)
            activity[path] = entry
        }
        for (path, history) in projectHistoryEntries {
            guard var entry = activity[path] else { continue }
            if let latest = history.compactMap(\.updatedAt).max() { entry.latest = max(entry.latest, latest) }
            activity[path] = entry
        }
        return activity.values.sorted {
            if $0.working != $1.working { return $0.working }
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.project.path.localizedStandardCompare($1.project.path) == .orderedAscending
        }.map(\.project)
    }
    private func configure(_ column: ChatColumn) {
        column.onSend = { [weak self, weak column] in
            guard let self, let column else { return }; self.send(from: column)
        }
        column.onStop = { [weak self, weak column] in
            guard let self, let s = column?.session else { return }; self.run { try await s.interrupt() }
        }
        column.onNewChat = { [weak self, weak column] in
            guard let self, let column else { return }; self.newChat(in: column)
        }
        column.onSelectChat = { [weak self, weak column] index in
            guard let self, let column else { return }; self.select(index, in: column)
        }
        column.onCloseChat = { [weak self, weak column] index in
            guard let self, let column else { return }; self.closeChat(index, in: column)
        }
        column.onTabDragEnded = { [weak self] in self?.layoutController?.clearPreviews() }
        column.onSplit = { [weak self, weak column] in
            guard let column else { return }; self?.splitPane(column, side: .right)
        }
        column.onSplitBelow = { [weak self, weak column] in
            guard let column else { return }; self?.splitPane(column, side: .bottom)
        }
        column.onClosePane = { [weak self, weak column] in
            guard let column else { return }; self?.closePane(column)
        }
        column.onDraftChange = { [weak self] in self?.scheduleStateSave() }
        column.onPrepareAttachment = { [weak self, weak column] in
            guard let self, let column, column.session == nil else { return }
            self.newChat(in: column)
        }
        column.onImportedAttachments = { [weak self] id, attachments in
            guard let self else { return }
            self.attachmentDrafts[id, default: []].append(contentsOf: attachments)
            for visible in self.columns where visible.session?.id == id {
                visible.setAttachments(visible.attachments + attachments, animated: true)
            }
            self.scheduleStateSave()
        }
        column.onFocus = { [weak self, weak column] in
            guard let self, let column else { return }
            self.activeColumnID = column.columnID
            self.activePane = column.stream
            self.refreshProviderControls()
            self.scheduleStateSave()
        }
        column.stream.onViewStateChanged = { [weak self, weak column] state in
            guard let self, let column, let id = column.session?.id else { return }
            column.streamStates[id] = state; self.scheduleStateSave()
        }
    }
    private func rememberDraft(_ column: ChatColumn) {
        if let s = column.session {
            drafts[s.id] = column.prompt.string; attachmentDrafts[s.id] = column.attachments
            column.streamStates[s.id] = column.stream.viewState
        }
    }
    private func restoreStreamState(in column: ChatColumn) {
        guard let id = column.session?.id,
              let state = column.streamStates[id] ?? streamStates[id] else { return }
        column.streamStates[id] = state
        column.stream.restoreViewState(state)
    }
    private func closeSplit() {
        for column in columns where column !== primaryColumn {
            rememberDraft(column); column.session?.detach(column.stream)
            column.view.removeFromSuperview(); column.removeFromParent()
        }
        columnStore = [primaryColumn.columnID: primaryColumn]
        paneLayout = .pane(primaryColumn.columnID)
        activeColumnID = primaryColumn.columnID
        renderLayout()
    }
    func closePane(_ column: ChatColumn) {
        guard layoutMode == .panes, columns.count > 1, columns.contains(column) else { return }
        let previousFocus = focusedColumn
        paneLayout = layoutController?.snapshot ?? paneLayout
        let balanceTarget = paneLayout?.removalBalanceTarget(for: column.columnID)
        guard let remaining = paneLayout?.removing(column.columnID) else { return }
        rememberDraft(column)
        column.session?.detach(column.stream)
        column.view.removeFromSuperview(); column.removeFromParent()
        columnStore.removeValue(forKey: column.columnID)
        paneLayout = remaining
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        let nextFocus = previousFocus !== column ? previousFocus :
            (balanceTarget.flatMap { columnStore[$0.paneID] } ?? primaryColumn)
        activeColumnID = nextFocus.columnID
        activePane = nextFocus.stream
        renderLayout()
        layoutController?.balance()
        paneLayout = layoutController?.snapshot ?? paneLayout
        refreshNavigation()
        window?.makeFirstResponder(nextFocus.prompt)
    }
    @objc func closeFocusedPane(_ sender: Any?) { closePane(focusedColumn) }
    @objc func singlePane(_ sender: Any?) {
        guard layoutMode == .panes else { return }
        closeSplit(); refreshNavigation()
    }
    @objc func chooseWorkspaceLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WorkspaceLayoutMode(rawValue: raw) else { return }
        setLayoutMode(mode)
    }
    func setLayoutMode(_ mode: WorkspaceLayoutMode) {
        guard mode != layoutMode else { return }
        rememberProject()
        layoutMode = mode
        if let path = projectSelection { restoreProject(path) }
        refreshLayoutMenu()
        settingsController?.setTabsOnly(mode == .tabs)
        saveWorkspaceState()
    }
    func refreshLayoutMenu() {
        let paneActions: [Selector] = [#selector(splitStream(_:)), #selector(stackStream(_:)),
            #selector(focusPreviousPane(_:)), #selector(focusNextPane(_:)),
            #selector(closeFocusedPane(_:)), #selector(singlePane(_:))]
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, paneActions.contains(action) {
                    let alias = item.identifier?.rawValue == "shortcutAlias"
                    item.isHidden = layoutMode == .tabs || alias
                    item.allowsKeyEquivalentWhenHidden = layoutMode == .panes && alias
                }
                if item.identifier?.rawValue == "paneCommandsSeparator" { item.isHidden = layoutMode == .tabs }
                if item.action == #selector(selectPreviousTab(_:)) {
                    item.title = layoutMode == .tabs ? "Previous Tab" : "Previous Chat or Pane"
                } else if item.action == #selector(selectNextTab(_:)) {
                    item.title = layoutMode == .tabs ? "Next Tab" : "Next Chat or Pane"
                }
                if let submenu = item.submenu { update(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }
    private func rememberProject() {
        guard !switchingProject, samplePane == nil, let path = projectSelection else { return }
        columns.forEach(rememberDraft)
        var state = projectStates[path] ?? ProjectViewState()
        if layoutMode == .tabs {
            state.tabbed = TabbedViewState(selectedChat: primaryColumn.session?.id,
                tabs: primaryColumn.tabIDs, tabOffset: primaryColumn.tabOffset,
                streams: primaryColumn.streamStates, closedTabs: primaryColumn.closedTabIDs)
            projectStates[path] = state
            return
        }
        state.layout = layoutController?.snapshot ?? paneLayout
        state.panes = columns.map { PaneViewState(id: $0.columnID, session: $0.session?.id, tabs: $0.tabIDs, tabOffset: $0.tabOffset, streams: $0.streamStates, closedTabs: $0.closedTabIDs) }
        state.focusedPane = focusedColumn.columnID
        state.primary = primaryColumn.session?.id
        state.secondary = secondaryColumn?.session?.id
        state.focusedSecondary = secondaryColumn != nil && focusedColumn === secondaryColumn
        state.tabs = projectChatIndices(path).map { sessions[$0].id }
        state.primaryTabs = primaryColumn.tabIDs
        state.secondaryTabs = secondaryColumn?.tabIDs
        state.primaryTabOffset = primaryColumn.tabOffset
        state.secondaryTabOffset = secondaryColumn?.tabOffset
        if secondaryColumn != nil {
            if case .split(_, let fraction, _, _) = state.layout { state.splitFraction = fraction }
        }
        projectStates[path] = state
    }
    private func projectChatIndices(_ path: String) -> [Int] {
        let savedOrder = projectStates[path]?.tabs ?? []
        var ranks: [UUID: Int] = [:]
        for (rank, id) in savedOrder.enumerated() where ranks[id] == nil { ranks[id] = rank }
        return sessions.indices.filter { sessions[$0].project.path == path && !closedTabs.contains(sessions[$0].id) }
            .sorted { left, right in
                let lhs = ranks[sessions[left].id] ?? savedOrder.count + left
                let rhs = ranks[sessions[right].id] ?? savedOrder.count + right
                return lhs < rhs
            }
    }
    private func chatIndices(in column: ChatColumn) -> [Int] {
        column.tabIDs.compactMap { id in sessions.firstIndex { $0.id == id && $0.project.path == projectSelection } }
    }
    private func refreshNavigation() {
        let started = sessions.filter(\.hasStartedConversation).map(\.id)
        let existing = Set(sidebarConversationOrder)
        let newChats = started.filter { !existing.contains($0) }
        let sessionIDs = Set(sessions.map(\.id))
        sidebarConversationOrder = Array(newChats.reversed()) + sidebarConversationOrder.filter { sessionIDs.contains($0) }
        let visible = Set(started).subtracting(closedTabs)
        conversationIDs = sidebarConversationOrder.filter { visible.contains($0) }
        if historyEnabled && !stopped {
            let visibleSessions = sessions.filter { visible.contains($0.id) }
            threadSummaries.schedule(visibleSessions, generate: { [weak self] session, input in
                guard let self else { throw CancellationError() }
                let executable = try session.provider == .claude ? ClaudeConnection.executable() : self.executable(allowPrompt: false)
                return try await ChatThreadSummary.generate(input: input, provider: session.provider,
                                                            model: session.inferenceSettings.model, executable: executable)
            }, updated: { [weak self] in self?.refreshNavigation() })
        }
        conversationSidebar.reloadData()
        if let currentID = focusedColumn.session?.id,
           let row = conversationIDs.firstIndex(of: currentID) {
            conversationSidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { conversationSidebar.deselectAll(nil) }
        projectRows = projects.flatMap { project -> [ProjectHistoryRow] in
            var rows: [ProjectHistoryRow] = [.project(project)]
            guard projectStates[project.path]?.historyExpanded == true else { return rows }
            let entries = historyEntries(in: project.path)
            rows += entries.map { .conversation(project.path, $0) }
            if historySearches[project.path] != nil {
                rows.append(.status(project.path, "Loading conversations…", retry: false))
            } else if projectHistoryErrors[project.path] != nil {
                rows.append(.status(project.path, "Could not load all chats · Retry", retry: true))
            } else if entries.isEmpty {
                rows.append(.status(project.path, "No conversations yet", retry: false))
            }
            return rows
        }
        projectHistoryTable.reloadData()
        let currentID = focusedColumn.session?.id
        let selectedRow = projectRows.firstIndex {
            if case .conversation(_, let entry) = $0 { return entry.sessionID != nil && entry.sessionID == currentID }
            return false
        } ?? projectRows.firstIndex {
            if case .project(let project) = $0 { return project.path == projectSelection }
            return false
        }
        if let row = selectedRow { projectHistoryTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { projectHistoryTable.deselectAll(nil) }
        for column in columns {
            let chats = chatIndices(in: column).map { ($0, sessions[$0]) }
            column.updateTabs(chats, isSplit: secondaryColumn != nil)
        }
        updateSplitAvailability()
        scheduleStateSave()
    }
    private func select(_ index: Int, in requestedColumn: ChatColumn? = nil) {
        guard sessions.indices.contains(index) else { return }
        let s = sessions[index]
        closedTabs.removeAll { $0 == s.id }
        var target = requestedColumn ?? primaryColumn
        if projectSelection != s.project.path || samplePane != nil { selectProject(s.project.path); target = primaryColumn }
        sampleTimer?.invalidate(); sampleTimer = nil; samplePane = nil
        if !target.tabIDs.contains(s.id) { target.tabIDs.append(s.id) }
        target.closedTabIDs.removeAll { $0 == s.id }
        rememberDraft(target)
        projectSelection = s.project.path
        bind(s)
        // Re-selecting the active tab must preserve its live selection and navigation.
        if target.session !== s {
            target.display(s, draft: drafts[s.id] ?? "", attachments: attachmentDrafts[s.id] ?? [])
            restoreStreamState(in: target)
        }
        if target === primaryColumn { selected = index }
        if layoutMode == .tabs ? primaryColumn.parent == nil : layoutController?.parent == nil { renderLayout() }
        activePane = target.stream
        activeColumnID = target.columnID
        window?.title = s.title
        refreshProviderControls()
        status.stringValue = s.ready ? "Connected" : "Ready to connect"
        refreshActivity(); refreshNavigation(); loadHistoryIfNeeded(s)
    }
    private func refreshActivity() {
        activityTimer?.invalidate(); activityTimer = nil
        if session?.turn != nil {
            activity.startAnimation(nil); sendButton.title = "Steer  ↵"
            if startedAt == nil { startedAt = Date() }
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let start = self.startedAt else { return }
                    self.activePane?.status.stringValue = "Working · \(Int(Date().timeIntervalSince(start)))s"
                }
            }
        } else { activity.stopAnimation(nil); sendButton.title = "Send  ↵"; startedAt = nil }
    }
    @objc func selectPreviousTab(_ sender: Any?) { selectAdjacentTab(offset: -1) }
    @objc func selectNextTab(_ sender: Any?) { selectAdjacentTab(offset: 1) }
    private func selectAdjacentTab(offset: Int) {
        guard samplePane == nil, projectSelection != nil else { return }
        let column = focusedColumn
        // Traverse tabs in layout order, including a stop for an empty pane.
        // Keep the pane identity: the same chat can be open in several panes.
        let destinations: [(column: ChatColumn, index: Int?)] = columns.flatMap { pane in
            let tabs = chatIndices(in: pane)
            return tabs.isEmpty ? [(pane, nil)] : tabs.map { (pane, Optional($0)) }
        }
        guard destinations.count > 1,
              let position = destinations.firstIndex(where: {
                  $0.column === column && $0.index.map { sessions[$0] === column.session } != false
              }) else { return }
        let target = destinations[(position + offset + destinations.count) % destinations.count]
        if let index = target.index { select(index, in: target.column) }
        activeColumnID = target.column.columnID
        activePane = target.column.stream
        window?.makeFirstResponder(target.column.prompt)
        refreshProviderControls()
        scheduleStateSave()
    }
    @objc func closeTab(_ sender: Any?) {
        // ⌘W in Settings or a preview window closes that window, not a chat.
        if let key = NSApp.keyWindow, key !== window { key.performClose(sender); return }
        let column = focusedColumn
        if column.tabIDs.isEmpty {
            if columns.count > 1 { closePane(column) }
            else { window?.performClose(sender) }
            return
        }
        guard let current = column.session, let index = sessions.firstIndex(where: { $0 === current }) else { return }
        closeChat(index, in: column)
    }
    private func closeChat(_ index: Int, in column: ChatColumn) {
        guard sessions.indices.contains(index), column.tabIDs.contains(sessions[index].id) else { return }
        let closing = sessions[index]
        let position = column.tabIDs.firstIndex(of: closing.id) ?? 0
        if column.session === closing { rememberDraft(column) }
        column.tabIDs.removeAll { $0 == closing.id }
        column.closedTabIDs.removeAll { $0 == closing.id }; column.closedTabIDs.append(closing.id)
        if !columns.contains(where: { $0.tabIDs.contains(closing.id) }) {
            closedTabs.removeAll { $0 == closing.id }; closedTabs.append(closing.id)
        }
        if column.tabIDs.isEmpty {
            if columns.count > 1 {
                closePane(column)
                saveWorkspaceState()
            } else {
                column.display(nil)
                selected = nil
                if layoutMode == .tabs {
                    window?.title = "ThoughtStream"; status.stringValue = "Ready"
                    refreshActivity(); refreshProviderControls()
                }
                refreshNavigation(); saveWorkspaceState()
                if layoutMode == .panes { window?.performClose(nil) }
            }
            return
        }
        if column.session === closing {
            let candidates = chatIndices(in: column)
            // Choose the next tab in this pane's order, then the previous one.
            let trailingIDs = Set(column.tabIDs.dropFirst(position))
            if let next = candidates.first(where: { trailingIDs.contains(sessions[$0].id) }) ?? candidates.last {
                select(next, in: column)
            } else {
                column.display(nil)
                if column === primaryColumn { selected = nil }
                activeColumnID = column.columnID
                activePane = column.stream
                status.stringValue = "Ready"; window?.title = "ThoughtStream"; refreshActivity()
            }
        }
        refreshNavigation(); saveWorkspaceState()
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        let column = focusedColumn
        while let id = column.closedTabIDs.popLast() {
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                select(index, in: column); return
            }
        }
        while let id = closedTabs.popLast() {
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                select(index, in: focusedColumn); return
            }
        }
    }
    private func executable(allowPrompt: Bool = true) throws -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("codex/bin/codex")
        let paths: [String?] = [UserDefaults.standard.string(forKey: "codexPath"), bundled?.path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        for path in paths.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        guard allowPrompt else { throw CodexConnection.error("Install Codex to find previous conversations.") }
        let panel = NSOpenPanel(); panel.title = "Select the Codex executable"; panel.message = "Choose a native codex executable. The build launcher can bundle Codex for you."; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { throw CodexConnection.error("No Codex executable selected.") }
        UserDefaults.standard.set(url.path, forKey: "codexPath"); return url
    }
    private func run(_ operation: @escaping () async throws -> Void) {
        Task { @MainActor in do { try await operation() } catch { let alert = NSAlert(error: error); alert.runModal() } }
    }
    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.title = "Choose a project"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if sessions.contains(where: { $0.project.path == url.path }) { selectProject(url.path) }
        else { sessions.append(Session(project: url, provider: AgentProvider.selected)); select(sessions.count - 1) }
    }
    @objc func newSession(_ sender: Any?) {
        guard let project = session?.project else { openProject(sender); return }; sessions.append(Session(project: project, provider: AgentProvider.selected)); select(sessions.count - 1)
    }
    @objc private func conversationSelected() {
        let row = conversationSidebar.selectedRow
        guard conversationIDs.indices.contains(row),
              let index = sessions.firstIndex(where: { $0.id == conversationIDs[row] }) else { return }
        select(index, in: focusedColumn)
        window?.makeFirstResponder(focusedColumn.prompt)
    }
    @objc private func sidebarSelected() {
        guard projectRows.indices.contains(projectHistoryTable.selectedRow) else { return }
        switch projectRows[projectHistoryTable.selectedRow] {
        case .project(let project): localSearch.dismiss(); selectProject(project.path)
        case .conversation(let path, let entry):
            localSearch.dismiss()
            let index: Int
            if let existing = sessions.firstIndex(where: {
                $0.project.path == path && ($0.id == entry.sessionID || (entry.thread != nil && $0.thread == entry.thread && $0.provider == entry.provider))
            }) { index = existing }
            else {
                sessions.append(Session(project: URL(fileURLWithPath: path), title: entry.title,
                                        thread: entry.thread, needsHistory: true, provider: entry.provider))
                index = sessions.count - 1
            }
            select(index, in: focusedColumn)
        case .status(let path, _, let retry):
            if retry { discoverHistory(in: path) }
        }
    }

    func toggleProjectHistory(_ path: String) {
        var state = projectStates[path] ?? ProjectViewState()
        state.historyExpanded = !(state.historyExpanded ?? false)
        projectStates[path] = state
        if state.historyExpanded == true { discoverHistory(in: path) }
        refreshNavigation()
    }

    private func historyEntries(in path: String) -> [ProjectHistoryEntry] {
        let local = sessions.filter { $0.project.path == path && $0.hasStartedConversation }.map {
            ProjectHistoryEntry(title: $0.sidebarTitle, provider: $0.provider, thread: $0.thread, sessionID: $0.id, updatedAt: $0.lastConversationActivity)
        }
        var seen = Set<String>()
        return (local + (projectHistoryEntries[path] ?? [])).filter { seen.insert($0.key).inserted }
    }
    func selectProject(_ path: String) {
        defer { if projectStates[path]?.historyExpanded == true { discoverHistory(in: path) } }
        guard projectSelection != path || samplePane != nil else { return }
        rememberProject()
        restoreProject(path)
    }

    private func restoreProject(_ path: String) {
        switchingProject = true
        defer { switchingProject = false; scheduleStateSave() }
        sampleTimer?.invalidate(); sampleTimer = nil; samplePane = nil
        for column in columns {
            column.session?.detach(column.stream)
            column.view.removeFromSuperview(); column.removeFromParent()
        }
        layoutController = nil
        primaryColumn = ChatColumn(tabsOnly: layoutMode == .tabs); configure(primaryColumn)
        columnStore = [primaryColumn.columnID: primaryColumn]
        paneLayout = .pane(primaryColumn.columnID)
        projectSelection = path; selected = nil
        let state = projectStates[path] ?? ProjectViewState()
        let legacyTabs = projectChatIndices(path).map { sessions[$0].id }
        if layoutMode == .tabs {
            let saved = state.tabbedState(fallbackTabs: legacyTabs)
            let validIDs = Set(sessions.filter { $0.project.path == path }.map(\.id))
            var seen = Set<UUID>()
            primaryColumn.tabIDs = saved.tabs.filter { validIDs.contains($0) && seen.insert($0).inserted }
            primaryColumn.streamStates = saved.streams
            primaryColumn.closedTabIDs = saved.closedTabs.filter { validIDs.contains($0) && !seen.contains($0) }
            let available = chatIndices(in: primaryColumn)
            let selected = available.first { sessions[$0].id == saved.selectedChat } ?? available.first
            let current = selected.map { sessions[$0] }
            if let current { bind(current) }
            primaryColumn.display(current, draft: current.flatMap { drafts[$0.id] } ?? "", attachments: current.flatMap { attachmentDrafts[$0.id] } ?? [])
        } else if let layout = state.layout, let savedPanes = state.panes,
           !layout.ids.isEmpty, Set(layout.ids).count == layout.ids.count,
           layout.ids.allSatisfy({ id in savedPanes.contains { $0.id == id } }) {
            for column in columns { column.session?.detach(column.stream) }
            columnStore = [:]
            for id in layout.ids {
                let saved = savedPanes.first { $0.id == id }!
                let column = ChatColumn(id: id); configure(column)
                column.tabIDs = saved.tabs
                column.streamStates = saved.streams ?? [:]
                column.closedTabIDs = saved.closedTabs ?? []
                columnStore[id] = column
                let current = sessions.first { $0.id == saved.session && $0.project.path == path && saved.tabs.contains($0.id) }
                if let current { bind(current) }
                column.display(current, draft: current.flatMap { drafts[$0.id] } ?? "", attachments: current.flatMap { attachmentDrafts[$0.id] } ?? [])
            }
            paneLayout = layout
            primaryColumn = columns[0]
        } else {
            primaryColumn.streamStates = [:]
            primaryColumn.closedTabIDs = []
            primaryColumn.tabIDs = state.primaryTabs ?? legacyTabs
            let available = chatIndices(in: primaryColumn)
            let primary = available.first { sessions[$0].id == state.primary } ?? available.first
            let current = primary.map { sessions[$0] }
            if let current { bind(current) }
            primaryColumn.display(current, draft: current.flatMap { drafts[$0.id] } ?? "", attachments: current.flatMap { attachmentDrafts[$0.id] } ?? [])
            if state.secondaryTabs != nil || state.secondary != nil {
                let second = ChatColumn(); configure(second)
                second.tabIDs = state.secondaryTabs ?? legacyTabs
                let current = sessions.first { $0.id == state.secondary && $0.project.path == path }
                if let current { bind(current) }
                second.display(current, draft: current.flatMap { drafts[$0.id] } ?? "", attachments: current.flatMap { attachmentDrafts[$0.id] } ?? [])
                columnStore[second.columnID] = second
                paneLayout = .split(vertical: true, fraction: state.splitFraction, first: .pane(primaryColumn.columnID), second: .pane(second.columnID))
            }
        }
        let openIDs = Set(columns.flatMap(\.tabIDs))
        closedTabs.removeAll { openIDs.contains($0) }
        renderLayout()
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        for column in columns { restoreStreamState(in: column) }
        let focused = state.focusedPane.flatMap { columnStore[$0] } ?? (state.focusedSecondary ? secondaryColumn : nil) ?? primaryColumn
        activeColumnID = focused.columnID
        activePane = focused.stream; refreshProviderControls(); window?.makeFirstResponder(focused.prompt)
        window?.title = session?.title ?? "ThoughtStream"
        status.stringValue = session.map { $0.ready ? "Connected" : "Ready to connect" } ?? "Ready"
        refreshActivity(); refreshNavigation()
        if layoutMode == .tabs {
            primaryColumn.restoreTabOffset(state.tabbed?.tabOffset ?? 0)
        } else if let panes = state.panes {
            for saved in panes { columnStore[saved.id]?.restoreTabOffset(saved.tabOffset) }
        } else {
            if let offset = state.primaryTabOffset { primaryColumn.restoreTabOffset(offset) }
            if let offset = state.secondaryTabOffset { secondaryColumn?.restoreTabOffset(offset) }
        }
        for column in columns { if let session = column.session { loadHistoryIfNeeded(session) } }
    }

    private func historyReader() throws -> ProjectHistory {
        if let projectHistory { return projectHistory }
        let reader = ProjectHistory(executable: try executable(allowPrompt: false))
        projectHistory = reader
        return reader
    }

    private func discoverHistory(in path: String) {
        guard historyEnabled, !stopped, historySearches[path] == nil else { return }
        projectHistoryErrors[path] = nil
        historySearches[path] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.historySearches[path] = nil
                if !self.stopped { self.refreshNavigation() }
            }
            let project = URL(fileURLWithPath: path)
            let claudeChats = await Task.detached { ClaudeHistory.conversations(in: project) }.value
            guard !Task.isCancelled else { return }
            let claudeEntries = claudeChats.map {
                ProjectHistoryEntry(title: $0.title, provider: .claude, thread: $0.id, sessionID: nil, updatedAt: $0.updated)
            }
            // Keep cached Codex results visible if a refresh fails; Claude's local
            // history remains usable even when Codex cannot connect.
            let cachedCodex = (self.projectHistoryEntries[path] ?? []).filter { $0.provider == .codex }
            self.projectHistoryEntries[path] = cachedCodex + claudeEntries
            do {
                let matches = try await self.historyReader().conversations(in: project)
                try Task.checkCancellation()
                self.projectHistoryEntries[path] = matches.map {
                    ProjectHistoryEntry(title: $0.title, provider: .codex, thread: $0.id, sessionID: nil, updatedAt: $0.updatedAt)
                } + claudeEntries
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.projectHistoryErrors[path] = error.localizedDescription
            }
        }
        refreshNavigation()
    }

    private func loadHistoryIfNeeded(_ session: Session) {
        guard historyEnabled, !stopped, session.thread != nil, session.turn == nil, historyLoads[session.id] == nil else { return }
        for column in columns where column.session === session { column.stream.status.stringValue = "Loading previous conversation…" }
        historyLoads[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.historyLoads[session.id] = nil }
            do {
                if session.provider == .claude { try await session.loadClaudeHistory(refresh: true) }
                else { try await session.loadHistory(using: self.historyReader(), refresh: true) }
                try Task.checkCancellation()
                for column in self.columns where column.session === session { column.stream.status.stringValue = "Previous conversation loaded" }
                self.refreshNavigation()
            } catch {
                for column in self.columns where column.session === session { column.stream.status.stringValue = session.history.isEmpty ? "Could not load history: \(error.localizedDescription)" : "Saved history available offline · Sync unavailable" }
            }
        }
    }
    @objc private func providerSelected() {
        let selectedProvider = AgentProvider.allCases[providerPicker.indexOfSelectedItem]
        selectedProvider.select()
        let column = focusedColumn
        if let existing = column.session, existing.provider != selectedProvider {
            if existing.thread == nil && existing.history.isEmpty && !existing.ready {
                existing.provider = selectedProvider; existing.save()
            } else {
                newChat(in: column)
            }
        }
        refreshProviderControls()
    }
    private func refreshProviderControls() {
        let provider = currentProvider
        providerPicker.selectItem(at: AgentProvider.allCases.firstIndex(of: provider) ?? 0)
        populateModelList(modelCatalog.models(for: provider))
        access.title = provider.accessLabel
        loginButton.title = "Connect ChatGPT"
        refreshModelsIfNeeded()
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === model.menu { refreshModelsIfNeeded() }
    }
    private func refreshModelsIfNeeded() {
        let provider = currentProvider
        guard automaticallyDiscoverModels, modelCatalog.needsRefresh(for: provider),
              Date().timeIntervalSince(modelRefreshAttempts[provider] ?? .distantPast) > 60 else { return }
        refreshModels(for: provider, showError: false)
    }
    @objc private func refreshModelsSelected() { refreshModels(for: currentProvider, showError: true) }
    private func refreshModels(for provider: AgentProvider, showError: Bool) {
        guard !stopped, modelRefreshTasks[provider] == nil else { return }
        modelRefreshAttempts[provider] = Date()
        modelRefreshTasks[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.modelRefreshTasks[provider] = nil
                if !self.stopped, self.currentProvider == provider {
                    self.populateModelList(self.modelCatalog.models(for: provider))
                }
            }
            do {
                let executable = try provider == .claude ? ClaudeConnection.executable() : self.executable(allowPrompt: false)
                let list = try await ProviderModelDiscovery.models(for: provider, executable: executable)
                try Task.checkCancellation()
                guard !self.stopped else { return }
                self.modelCatalog.update(list, for: provider)
            } catch is CancellationError {
            } catch {
                if showError, !self.stopped, let window = self.window {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t refresh models"
                    alert.informativeText = error.localizedDescription + "\nYour saved models are still available. Choose Refresh Models to try again."
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
        if currentProvider == provider { populateModelList(modelCatalog.models(for: provider)) }
    }
    @objc private func addModelSelected() {
        guard let window else { return }
        let provider = currentProvider, targetSession = inferenceSession
        populateModelList(modelCatalog.models(for: provider))
        let alert = NSAlert()
        alert.messageText = "Add a \(provider.label) model"
        alert.informativeText = "Enter the model ID supplied by your provider. It will be saved in this provider’s model list."
        alert.addButton(withTitle: "Add Model"); alert.addButton(withTitle: "Cancel")
        let id = NSTextField(), name = NSTextField()
        id.placeholderString = provider == .claude ? "claude-fable-5-2" : "Model ID"
        id.setAccessibilityLabel("Model ID"); name.setAccessibilityLabel("Display name (optional)")
        let fields = NSStackView(views: [NSTextField(labelWithString: "Model ID"), id, NSTextField(labelWithString: "Display name (optional)"), name])
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 124)
        id.widthAnchor.constraint(equalToConstant: 360).isActive = true
        name.widthAnchor.constraint(equalTo: id.widthAnchor).isActive = true
        alert.accessoryView = fields; alert.window.initialFirstResponder = id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                // If focus changed while the sheet was open, save the entry but
                // leave the newly focused conversation's inference choice alone.
                if self.currentProvider == provider, self.inferenceSession === targetSession {
                    try self.addCustomModel(id: id.stringValue, name: name.stringValue)
                } else {
                    try self.modelCatalog.add(id: id.stringValue, name: name.stringValue, for: provider)
                }
            } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
    func addCustomModel(id: String, name: String) throws {
        let provider = currentProvider
        let id = try modelCatalog.add(id: id, name: name, for: provider)
        var settings = currentInferenceSettings
        settings.model = id
        if provider == .codex { settings = settings.resolvingCodexTier(in: modelCatalog.models(for: provider)) }
        else if !InferenceSettings.supportsClaudeFastMode(id) { settings.tier = "default" }
        inferenceSession?.setInferenceSettings(settings)
        settings.save(provider: provider)
        refreshProviderControls()
    }
    @objc private func modelSelected() {
        guard model.selectedItem?.representedObject is String else { refreshProviderControls(); return }
        let tier = speed.selectedItem?.representedObject as? String ?? "default"
        refreshEfforts(preferred: currentInferenceSettings.effort)
        refreshSpeeds(preferred: tier)
        settingsChanged()
    }
    private func refreshSpeeds(preferred: String) {
        let provider = currentProvider
        let selectedModel = model.selectedItem?.representedObject as? String ?? ""
        let supportsFast = provider != .claude || InferenceSettings.supportsClaudeFastMode(selectedModel)
        speed.isHidden = false
        speed.removeAllItems()
        speed.autoenablesItems = false
        // Keep speed choices discoverable; sending checks runtime availability.
        let tiers = InferenceSettings.tiers(for: provider)
        for tier in tiers {
            speed.addItem(withTitle: tier == "default" ? "Standard" : tier.capitalized)
            speed.lastItem?.representedObject = tier
            speed.lastItem?.isEnabled = tier != "fast" || supportsFast
        }
        let requested = provider == .codex && preferred == "priority" ? "fast" : preferred
        let selected = speed.itemArray.first { $0.representedObject as? String == requested && $0.isEnabled }
        speed.select(selected ?? speed.itemArray.first)
        speed.toolTip = provider == .claude
            ? "Fast mode requires a supported Opus model and usage credits. Applies to the next turn."
            : "Faster tiers can use more of your allowance. Availability is checked when you send; unavailable speeds fall back to Fast or Standard."
    }
    private func refreshEfforts(preferred: String) {
        let selectedModel = model.selectedItem?.representedObject as? String
        let record = models.first { ($0["model"] as? String ?? $0["id"] as? String) == selectedModel }
        var values = (record?["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        if values.isEmpty { values = currentProvider == .claude ? InferenceSettings.claudeEfforts : [preferred] }
        effort.removeAllItems(); effort.addItems(withTitles: values)
        if values.contains(preferred) { effort.selectItem(withTitle: preferred) }
        else if let value = record?["defaultReasoningEffort"] as? String { effort.selectItem(withTitle: value) }
    }
    @objc private func settingsChanged() {
        let settings = chosenSettings
        inferenceSession?.setInferenceSettings(settings)
        settings.save(provider: currentProvider)
    }
    var chosenSettings: InferenceSettings {
        let saved = currentInferenceSettings
        return InferenceSettings(
            model: model.selectedItem?.representedObject as? String ?? saved.model,
            effort: effort.titleOfSelectedItem ?? saved.effort,
            tier: speed.selectedItem?.representedObject as? String ?? saved.tier)
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            claudeConnectButton.target = self
            claudeConnectButton.action = #selector(connectClaudeAccount(_:))
            settingsController = SettingsWindowController(
                target: self,
                actions: [
                    .split: #selector(splitStream(_:)), .stack: #selector(stackStream(_:)),
                    .closePane: #selector(closeFocusedPane(_:)), .singlePane: #selector(singlePane(_:)),
                    .fork: #selector(forkSession(_:)), .requests: #selector(showRequests(_:)),
                    .snapshot: #selector(showProtocol(_:)), .export: #selector(exportLog(_:))
                ],
                chatGPTButton: loginButton, claudeButton: claudeConnectButton,
                claudeStatus: claudeAccountStatus)
        }
        settingsController?.setTabsOnly(layoutMode == .tabs)
        settingsController?.showWindow(sender)
    }
    @objc func signIn(_ sender: Any?) {
        selectProvider(.codex)
        if focusedColumn.session == nil { newChat(sender) }
        guard let s = focusedColumn.session else { return }
        run { try await s.connect(self.executable()); try await s.loginIfNeeded(); self.loginButton.title = "ChatGPT connected" }
    }
    private func selectProvider(_ provider: AgentProvider) {
        providerPicker.selectItem(at: AgentProvider.allCases.firstIndex(of: provider) ?? 0)
        providerSelected()
    }
    @objc func connectClaudeAccount(_ sender: Any?) {
        guard claudeSignInTask == nil else { return }
        claudeConnectButton.isEnabled = false
        claudeAccountStatus.stringValue = "Checking Claude Code sign-in…"
        claudeSignInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.claudeSignInTask = nil; self.claudeConnectButton.isEnabled = true }
            do {
                let executable = try ClaudeConnection.executable()
                if try await ClaudeConnection.isAuthenticated() == false {
                    let script = FileManager.default.temporaryDirectory.appendingPathComponent("thoughtstream-claude-\(UUID().uuidString).command")
                    try ClaudeConnection.signInScript(executable: executable).write(to: script, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                    defer { try? FileManager.default.removeItem(at: script) }
                    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                    self.claudeAccountStatus.stringValue = "Finish signing in in Terminal and your browser. Waiting for Claude…"
                    var signedIn = false
                    for _ in 0..<150 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try Task.checkCancellation()
                        if try await ClaudeConnection.isAuthenticated() { signedIn = true; break }
                    }
                    guard signedIn else { throw CodexConnection.error("Sign-in is still pending. Finish in Terminal, then click Connect Claude again.") }
                }
                try Task.checkCancellation()
                self.selectProvider(.claude)
                if self.focusedColumn.session == nil { self.newChat(nil) }
                guard let session = self.focusedColumn.session else { return }
                try await session.connect(executable)
                self.claudeAccountStatus.stringValue = "Claude connected. Choose a model and send a message."
                self.claudeConnectButton.title = "Claude connected"
            } catch is CancellationError {
                self.claudeAccountStatus.stringValue = "Sign-in cancelled. You can connect again when ready."
            } catch {
                self.claudeAccountStatus.stringValue = error.localizedDescription
            }
        }
    }
    private var focusedColumn: ChatColumn {
        if let responder = window?.firstResponder as? NSView,
           let column = columns.first(where: { responder.isDescendant(of: $0.view) }) { activeColumnID = column.columnID }
        return activeColumnID.flatMap { columnStore[$0] } ?? primaryColumn
    }
    private func configureQueue(for session: Session) {
        session.configureMessageQueue { [weak self, weak session] in
            guard let self, let session else { throw CancellationError() }
            let executable = try session.provider == .claude ? ClaudeConnection.executable() : self.executable(allowPrompt: false)
            try await session.connect(executable)
            guard try await session.isAuthenticated() else {
                throw CodexConnection.error("Sign in to \(session.provider.label), then retry this queued message.")
            }
        }
    }
    @objc func send(_ sender: Any?) { send(from: focusedColumn) }
    private func send(from column: ChatColumn) {
        let submittedText = column.prompt.string
        let value = column.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = column.attachments
        guard !column.isImportingImages, (!value.isEmpty || !attachments.isEmpty), column.sendButton.isEnabled else { return }
        if column.session == nil {
            newChat(in: column); column.prompt.string = value; column.prompt.undoManager?.removeAllActions(withTarget: column.prompt); column.setAttachments(attachments)
        }
        guard let s = column.session else { return }
        if !AccessMode.hasChosen { chooseAccess() }
        column.stream.resumeLiveActivity(animated: true)
        column.conversation.resumeLiveActivity(animated: true)
        let settings = inferenceSession === s ? chosenSettings : s.inferenceSettings; settings.save(provider: s.provider)
        column.sendButton.isEnabled = false
        column.stream.status.stringValue = s.ready ? "Sending…" : "Connecting to \(s.provider.label)…"
        run {
            defer { column.sendButton.isEnabled = true; column.refresh(); self.refreshNavigation() }
            self.configureQueue(for: s)
            try s.enqueueChat(submittedText, attachments: attachments, settings: settings)
            if self.drafts[s.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == value { self.drafts[s.id] = "" }
            if column.session === s, column.prompt.string.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                column.prompt.string = ""; column.prompt.needsDisplay = true
                column.prompt.undoManager?.removeAllActions(withTarget: column.prompt)
            }
            let sentIDs = Set(attachments.map(\.id))
            self.attachmentDrafts[s.id]?.removeAll { sentIDs.contains($0.id) }
            if column.session === s {
                column.setAttachments(column.attachments.filter { !sentIDs.contains($0.id) }, animated: true)
            }
            self.saveWorkspaceState()
            self.stateStore.flush()
            self.refreshActivity()
        }
    }
    @objc func interrupt(_ sender: Any?) { guard let s = focusedColumn.session else { return }; run { try await s.interrupt() } }
    @objc private func changeAccess(_ sender: Any?) {
        if AccessMode.selected == .fullAccess {
            AccessMode.select(.workspace)
            sessions.forEach { $0.disconnectForAccessChange(to: .workspace) }
            access.title = currentProvider.accessLabel
        } else { chooseAccess() }
    }
    private func chooseAccess() {
        let alert = NSAlert()
        alert.messageText = "Allow full access?"
        alert.informativeText = "The selected agent can read and change files accessible to your Mac user, run commands, and use the network without asking for command or file approvals. This choice applies to all projects and is remembered until you revoke it using the access button. macOS privacy controls and service permissions still apply."
        alert.addButton(withTitle: "Use Workspace Access")
        alert.addButton(withTitle: "Enable Full Access")
        let mode: AccessMode = alert.runModal() == .alertSecondButtonReturn ? .fullAccess : .workspace
        if mode != AccessMode.selected { sessions.forEach { $0.disconnectForAccessChange(to: mode) } }
        AccessMode.select(mode); access.title = currentProvider.accessLabel
        session?.report(.system, "Access selected: \(mode.label).")
    }
    func canDropTab(_ payload: ChatTabDrag, on side: TabSplitSide, in target: ChatColumn? = nil) -> Bool {
        guard samplePane == nil,
              let source = columns.first(where: { $0.columnID == payload.columnID }),
              source.tabIDs.contains(payload.sessionID),
              sessions.contains(where: { $0.id == payload.sessionID && $0.project.path == projectSelection }) else { return false }
        return canSplit(target ?? source, on: side)
    }

    private func canSplit(_ column: ChatColumn, on side: TabSplitSide) -> Bool {
        guard layoutMode == .panes, samplePane == nil, columns.contains(column) else { return false }
        let layout = layoutController?.snapshot ?? paneLayout ?? .pane(column.columnID)
        let minimum = columns.reduce(PaneLayout.minimumPaneSize) { size, pane in
            let fitting = pane.view.fittingSize
            return NSSize(width: max(size.width, ceil(fitting.width)), height: max(size.height, ceil(fitting.height)))
        }
        return layout.permitsSplit(of: column.columnID, vertical: side.vertical,
                                   availableSize: streamSplit.view.bounds.size,
                                   paneInset: InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0,
                                   paneMinimum: minimum)
    }

    private func updatePaneWindowMinimum() {
        guard !updatingPaneWindowMinimum, let window, let layoutController else { return }
        updatingPaneWindowMinimum = true
        defer { updatingPaneWindowMinimum = false }
        let minimum = layoutController.minimumSize
        // Include the sidebar and header/titlebar around the actual pane area.
        let chrome = NSSize(width: max(0, window.frame.width - streamSplit.view.bounds.width),
                            height: max(0, window.frame.height - streamSplit.view.bounds.height))
        let required = NSSize(width: max(860, ceil(minimum.width + chrome.width)),
                              height: max(600, ceil(minimum.height + chrome.height)))
        guard window.minSize != required else { return }
        let frame = window.frame
        window.minSize = required
        // Updating content-derived limits can make AppKit refit the window.
        // Keep its existing size unless the new pane minima require more room.
        let preserved = NSRect(origin: frame.origin,
            size: NSSize(width: max(frame.width, required.width), height: max(frame.height, required.height)))
        if window.frame != preserved { window.setFrame(preserved, display: false) }
    }

    private func updateSplitAvailability() {
        for column in columns {
            column.updateSplitAvailability(split: canSplit(column, on: .right), stack: canSplit(column, on: .bottom))
        }
    }
    @discardableResult
    func dropTab(_ payload: ChatTabDrag, on side: TabSplitSide, in target: ChatColumn? = nil) -> Bool {
        guard canDropTab(payload, on: side, in: target),
              let source = columns.first(where: { $0.columnID == payload.columnID }),
              let moved = sessions.first(where: { $0.id == payload.sessionID }) else { return false }
        columns.forEach(rememberDraft)
        let destination = target ?? source
        let new = ChatColumn(); configure(new); new.tabIDs = [moved.id]
        source.tabIDs.removeAll { $0 == moved.id }
        new.streamStates[moved.id] = source.streamStates[moved.id] ?? streamStates[moved.id]
        // Moving one tab only vacates its source; other views remain attached.
        if source.session === moved {
            let replacement = source.tabIDs.compactMap { id in sessions.first { $0.id == id } }.first
            source.display(replacement, draft: replacement.flatMap { drafts[$0.id] } ?? "", attachments: replacement.flatMap { attachmentDrafts[$0.id] } ?? [])
            restoreStreamState(in: source)
        }
        new.display(moved, draft: drafts[moved.id] ?? "", attachments: attachmentDrafts[moved.id] ?? [])
        restoreStreamState(in: new)
        insertPane(new, beside: destination, side: side)
        refreshActivity(); refreshNavigation(); saveWorkspaceState()
        return true
    }
    private func insertPane(_ new: ChatColumn, beside column: ChatColumn, side: TabSplitSide) {
        paneLayout = layoutController?.snapshot ?? paneLayout
        let old = PaneLayout.pane(column.columnID), added = PaneLayout.pane(new.columnID)
        let branch = PaneLayout.split(vertical: side.vertical, fraction: 0.5,
                                      first: side.leading ? added : old, second: side.leading ? old : added)
        columnStore[new.columnID] = new
        paneLayout = paneLayout?.replacing(column.columnID, with: branch)
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        activeColumnID = new.columnID; activePane = new.stream
        renderLayout()
        layoutController?.balance()
        paneLayout = layoutController?.snapshot ?? paneLayout
        window?.makeFirstResponder(new.prompt)
    }
    func splitPane(_ column: ChatColumn, side: TabSplitSide) {
        guard canSplit(column, on: side) else { return }
        if projectSelection == nil { newChat(in: column) }
        guard let path = projectSelection else { return }
        let s = Session(project: URL(fileURLWithPath: path), provider: AgentProvider.selected); sessions.append(s); bind(s)
        let new = ChatColumn(); configure(new)
        new.tabIDs = [s.id]; new.display(s)
        insertPane(new, beside: column, side: side)
        refreshNavigation()
    }
    @objc func splitStream(_ sender: Any?) { splitPane(focusedColumn, side: .right) }
    @objc func stackStream(_ sender: Any?) { splitPane(focusedColumn, side: .bottom) }
    @objc func splitBelow(_ sender: Any?) { stackStream(sender) }
    @objc func focusNextPane(_ sender: Any?) { movePaneFocus(by: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { movePaneFocus(by: -1) }
    private func movePaneFocus(by offset: Int) {
        guard layoutMode == .panes else { return }
        let panes = columns
        guard panes.count > 1, let index = panes.firstIndex(of: focusedColumn) else { return }
        let target = panes[(index + offset + panes.count) % panes.count]
        activeColumnID = target.columnID
        activePane = target.stream
        window?.makeFirstResponder(target.prompt)
        refreshProviderControls()
        scheduleStateSave()
    }
    @objc func forkSession(_ sender: Any?) { guard let s = focusedColumn.session else { return }; run { let fork = try await s.fork(); self.sessions.append(fork); self.select(self.sessions.count - 1) } }
    @objc func exportLog(_ sender: Any?) {
        guard let s = session else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "ThoughtStream-\(s.id.uuidString).jsonl"
        if panel.runModal() == .OK, let url = panel.url { do { try s.export(url) } catch { NSAlert(error: error).runModal() } }
    }
    @objc func showProtocol(_ sender: Any?) {
        guard let s = session else { return }
        let view = StreamPane(); _ = view.view
        view.replace([StreamRecord(kind: StreamKind.tool.rawValue, text: s.protocolSnapshot().map { Session.pretty($0) }.joined(separator: "\n\n"), language: nil)])
        let window = NSWindow(contentViewController: view); window.title = "Protocol snapshot — \(s.title)"; window.setContentSize(NSSize(width: 850, height: 750)); window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil); protocolWindow = window
    }
    @objc func increaseText(_ sender: Any?) { focusedColumn.stream.changeFont(1) }
    @objc func decreaseText(_ sender: Any?) { focusedColumn.stream.changeFont(-1) }
    @objc func resetText(_ sender: Any?) { focusedColumn.stream.resetFont() }
    @objc func find(_ sender: Any?) { activePane?.find() }
    @objc func findNext(_ sender: Any?) { activePane?.findNext() }
    private func scheduleStateSave() {
        guard !restoringWorkspace else { return }
        pendingStateSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveWorkspaceState() }
        pendingStateSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func saveWorkspaceState() {
        guard !switchingProject else { return }
        rememberProject()
        let current = projectSelection.flatMap { projectStates[$0] }
        stateStore.save(WorkspaceSnapshot(primary: current?.primary, secondary: current?.secondary, drafts: drafts, streams: streamStates, windowFrame: window.map { NSStringFromRect($0.styleMask.contains(.fullScreen) ? normalFrame ?? $0.frame : $0.frame) }, closedTabs: closedTabs, selectedProject: projectSelection, projects: projectStates, attachmentDrafts: attachmentDrafts, sidebarChatFraction: Double(sidebarSplit.chatFraction), sidebarConversationOrder: sidebarConversationOrder, layoutMode: layoutMode))
    }
    /// Full screen is not a size to reopen at; remember the windowed frame.
    private var normalFrame: NSRect?
    private func rememberNormalFrame() {
        if let window, !window.styleMask.contains(.fullScreen) { normalFrame = window.frame }
    }
    func windowDidResize(_ notification: Notification) {
        layoutController?.restoreFractions()
        rememberNormalFrame(); updateSplitAvailability(); scheduleStateSave()
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshPaneFocus() }
    func windowDidResignKey(_ notification: Notification) { refreshPaneFocus() }
    func windowDidMove(_ notification: Notification) { rememberNormalFrame(); scheduleStateSave() }
    func windowWillEnterFullScreen(_ notification: Notification) { rememberNormalFrame() }
    /// Palette colors resolve at draw time, but cached fonts, layer colors and
    /// typeset rows need an explicit pass.
    private func applyInterfaceStyle() {
        guard let window else { return }
        window.appearance = InterfaceStyle.current.appearance
        window.backgroundColor = FeedPalette.canvas
        layoutController?.applyInterfaceStyle()
        for column in columns { column.applyInterfaceStyle() }
        window.contentView?.layoutSubtreeIfNeeded()
        layoutController?.restoreFractions()
        updatePaneWindowMinimum()
        updateSplitAvailability()
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        if let content = window.contentView { redraw(content) }
    }

    func stopAll() {
        stopped = true
        threadSummaries.stop()
        localSearch.stop(); searchOpenTask?.cancel()
        offlineIndicator?.stop(); offlineIndicator = nil
        claudeSignInTask?.cancel()
        modelRefreshTasks.values.forEach { $0.cancel() }; modelRefreshTasks.removeAll()
        historySearches.values.forEach { $0.cancel() }; historyLoads.values.forEach { $0.cancel() }
        projectHistory?.stop()
        pendingStateSave?.cancel(); saveWorkspaceState(); stateStore.flush()
        if let splitResizeObserver { NotificationCenter.default.removeObserver(splitResizeObserver); self.splitResizeObserver = nil }
        activityTimer?.invalidate(); sampleTimer?.invalidate(); sessions.forEach { $0.stop() }
    }

    @objc private func showRequests(_ sender: Any?) {
        deferredInputs.removeAll(); presentNextRequest()
        if inputQueue.isEmpty { status.stringValue = "No pending input requests" }
    }
    private func presentNextRequest() {
        guard activeInput == nil, let window = window, window.attachedSheet == nil else { return }
        inputQueue.removeAll { !$0.session.isPending($0.id) }
        guard let request = inputQueue.first(where: { !deferredInputs.contains($0.key) }) else { return }
        let s = request.session, id = request.id, method = request.method, params = request.params
        let alert = NSAlert(); alert.messageText = "\(s.provider.label) needs your response"; alert.informativeText = "\(s.project.lastPathComponent) — \(s.title)\n\(method)\n\(params["reason"] as? String ?? "")"
        let standard = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "claude/tool/requestApproval"].contains(method)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 210)); field.font = .monospacedSystemFont(ofSize: 11, weight: .regular); field.string = Session.pretty(params); field.isEditable = !standard
        let scroll = NSScrollView(frame: field.frame); scroll.documentView = field; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
        if standard { alert.addButton(withTitle: "Deny"); alert.addButton(withTitle: "Approve this request") }
        else { field.string = "{}"; alert.informativeText += "\nThe full request is in the feed. Enter the documented response object below, or choose Later and reopen it with Requests."; alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Send JSON response") }
        var questionInputs: [(String, NSPopUpButton, NSTextField)] = []
        if method == "claude/tool/requestApproval", params["tool_name"] as? String == "AskUserQuestion",
           let input = params["input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]] {
            let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
            for question in questions {
                guard let text = question["question"] as? String else { continue }
                let label = NSTextField(wrappingLabelWithString: text)
                label.preferredMaxLayoutWidth = 520
                let picker = NSPopUpButton()
                picker.addItems(withTitles: (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String })
                let answer = NSTextField(); answer.placeholderString = question["multiSelect"] as? Bool == true ? "Or enter answers separated by commas" : "Or type your own answer"
                answer.widthAnchor.constraint(equalToConstant: 520).isActive = true
                for view in [label, picker, answer] { form.addArrangedSubview(view) }
                questionInputs.append((text, picker, answer))
            }
            alert.accessoryView = form
            alert.buttons.last?.title = "Send answer"
        }
        activeInput = (request, alert)
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                self.activeInput = nil
                defer { DispatchQueue.main.async { [weak self] in self?.presentNextRequest() } }
                guard s.isPending(id) else { return }
                do {
                    if !questionInputs.isEmpty, response == .alertSecondButtonReturn {
                        var answers: [String: String] = [:]
                        for (question, picker, field) in questionInputs {
                            answers[question] = field.stringValue.isEmpty ? picker.titleOfSelectedItem ?? "" : field.stringValue
                        }
                        var input = params["input"] as? [String: Any] ?? [:]; input["answers"] = answers
                        try s.respond(id, ["decision": "accept", "updatedInput": input])
                    } else if standard { try s.respond(id, ["decision": response == .alertSecondButtonReturn ? "accept" : "decline"]) }
                    else if response == .alertSecondButtonReturn {
                        guard let value = try JSONSerialization.jsonObject(with: Data(field.string.utf8)) as? [String: Any] else { throw CodexConnection.error("Expected a JSON object.") }; try s.respond(id, value)
                    } else { self.deferredInputs.insert(request.key); s.report(.system, "Input deferred. Use Requests to respond, or Stop to interrupt the turn.") }
                } catch { self.deferredInputs.insert(request.key); NSAlert(error: error).runModal() }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === conversationSidebar ? max(1, conversationIDs.count) : projectRows.count
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === conversationSidebar { return conversationIDs.indices.contains(row) }
        guard projectRows.indices.contains(row) else { return false }
        if case .status(_, _, let retry) = projectRows[row] { return retry }
        return true
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarProjectRow() }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SidebarMetrics.rowHeight
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === conversationSidebar {
            guard conversationIDs.indices.contains(row),
                  let conversation = sessions.first(where: { $0.id == conversationIDs[row] }) else {
                return SidebarConversationCell(title: "No open conversations", project: "Start a new chat above", isRunning: false, isEmpty: true)
            }
            let cell = SidebarConversationCell(title: conversation.sidebarTitle, project: conversation.provider.label + " · " + conversation.project.lastPathComponent, isRunning: conversation.turn != nil)
            cell.toolTip = conversation.title + "\n" + conversation.provider.label + " · " + conversation.project.lastPathComponent
            return cell
        }
        guard projectRows.indices.contains(row) else { return nil }
        switch projectRows[row] {
        case .project(let project):
            let running = sessions.filter { $0.project.path == project.path && $0.turn != nil }.count
            return SidebarProjectCell(name: project.lastPathComponent, chatCount: historyEntries(in: project.path).count,
                                      runningCount: running, path: project.path,
                                      expanded: projectStates[project.path]?.historyExpanded == true) { [weak self] in
                self?.toggleProjectHistory(project.path)
            }
        case .conversation(_, let entry):
            return ProjectHistoryCell(title: entry.title, detail: entry.provider.label)
        case .status(let path, let title, _):
            let cell = ProjectHistoryCell(title: title, status: true)
            cell.toolTip = projectHistoryErrors[path] ?? title
            return cell
        }
    }
    @objc func showSample(_ sender: Any?) {
        rememberProject(); closeSplit()
        sampleTimer?.invalidate(); activityTimer?.invalidate(); activity.stopAnimation(nil); selected = nil; heading.stringValue = "Sample · how ThoughtStream works"
        for item in streamSplit.splitViewItems { streamSplit.removeSplitViewItem(item) }
        primaryColumn.display(nil)
        let pane = primaryColumn.stream; activePane = pane; samplePane = pane; streamSplit.addSplitViewItem(NSSplitViewItem(viewController: primaryColumn))
        status.stringValue = "SIMULATED SAMPLE — no model request or command execution"; primaryColumn.updateTabs([], isSplit: false)
        let records = Sample.richRecords
        var index = 0
        pane.append(records[0]); index = 1
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak pane, weak self] timer in
            Task { @MainActor in
                guard index < records.count else { timer.invalidate(); self?.sampleTimer = nil; return }
                pane?.append(records[index]); index += 1
            }
        }
    }
}

extension WorkspaceWindow: NSMenuItemValidation {
    /// Dim commands that have nothing to act on, as Mac menus do.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseWorkspaceLayout(_:)):
            item.state = item.representedObject as? String == layoutMode.rawValue ? .on : .off
            return true
        case #selector(forkSession(_:)), #selector(interrupt(_:)), #selector(send(_:)):
            return focusedColumn.session != nil
        case #selector(exportLog(_:)): return session != nil
        case #selector(closeFocusedPane(_:)), #selector(singlePane(_:)),
             #selector(focusPreviousPane(_:)), #selector(focusNextPane(_:)):
            return layoutMode == .panes && columns.count > 1
        case #selector(splitStream(_:)): return canSplit(focusedColumn, on: .right)
        case #selector(stackStream(_:)), #selector(splitBelow(_:)): return canSplit(focusedColumn, on: .bottom)
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty || !focusedColumn.closedTabIDs.isEmpty
        default: return true
        }
    }
}
