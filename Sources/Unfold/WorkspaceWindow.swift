import AppKit

@MainActor
final class WorkspaceWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuDelegate {
    private var sessions: [Session]
    var hasActiveWork: Bool { sessions.contains { $0.turn != nil || $0.queueWorker != nil } }
    private var selected: Int?
    let projectHistoryTable = NSTableView()
    private let projectUpButton = ThemedButton(title: "", target: nil, action: nil)
    private let projectDownButton = ThemedButton(title: "", target: nil, action: nil)
    private let conversationSidebar = NSTableView()
    private var conversationIDs: [UUID] = []
    private var sidebarConversationOrder: [UUID] = []
    private let sidebarSplit = SidebarSplitView()
    private let streamSplit = NSSplitViewController()
    private let tabSplitHost = TabSplitHostView()
    private let localSearch = WorkspaceHistorySearch()
    let commandBar = CommandBar()
    private let commandBarButton = AddPaneButton(title: "Command Bar", target: nil, action: nil)
    private let threadSummaries = ChatThreadSummaryCoordinator()
    private var searchOpenTask: Task<Void, Never>?
    private var primaryColumn = ChatColumn()
    private var columnStore: [UUID: ChatColumn] = [:]
    private var paneLayout: PaneLayout?
    private var layoutController: PaneLayoutController?
    private let paneCanvas = PaneCanvasController()
    private let sidebarShadow = SidebarEdgeShadow()
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
    private var hasDeferredTranscripts = false
    private var transcriptUpdateScheduled = false
    private var stopped = false
    private var switchingProject = false
    private var activeColumnID: UUID? { didSet { refreshPaneFocus() } }
    private var splitResizeObserver: NSObjectProtocol?
    private var styleObserver: NSObjectProtocol?
    private var offlineIndicator: OfflineWindowIndicator?
    private let localModels: LocalModelRegistry
    private var localObservers: [NSObjectProtocol] = []
    private var prompt: ComposerTextView { primaryColumn.prompt }
    private let heading = NSTextField(labelWithString: "ThoughtStream")
    private let loginButton = ThemedButton(title: "Connect ChatGPT", target: nil, action: nil)
    private let settingsButton = AddPaneButton(title: "Settings", target: nil, action: nil)
    private let rebalanceButton = AddPaneButton(title: "Rebalance", target: nil, action: nil)
    private let chatDisplayButton = AddPaneButton(title: "Just chat", target: nil, action: nil)
    private let displayPreferences: UserDefaults?
    private(set) var chatDisplayMode: ChatDisplayMode
    private let splitBelowButton = AddPaneButton(title: "Split below", target: nil, action: nil)
    private let newChatButton = AddPaneButton(title: "New Chat", target: nil, action: nil)
    private let focusLeftButton = AddPaneButton(title: "Focus Left", target: nil, action: nil)
    private let focusRightButton = AddPaneButton(title: "Focus Right", target: nil, action: nil)
    private var headerRow: WorkspaceHeaderRow?
    private let bodySurface = WorkspaceSurface()
    private let claudeConnectButton = ThemedButton(title: "Connect Claude", target: nil, action: nil)
    private let claudeAccountStatus = NSTextField(wrappingLabelWithString: "Use your Claude Code sign-in on this Mac.")
    private var claudeSignInTask: Task<Void, Never>?
    private var activityTimer: Timer?
    private var historyCacheTimer: Timer?
    private var startedAt: Date?
    private let providerPicker = ThemedPopUpButton()
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
    private let model = ThemedPopUpButton()
    private let effort = ThemedPopUpButton()
    private let speed = ThemedPopUpButton()
    private let access = ThemedButton(title: "", target: nil, action: nil)
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

    init(restoredSessions: [Session]? = nil, stateStore: WorkspaceStateStore? = nil, history: ProjectHistory? = nil, modelCatalog: ModelCatalog? = nil,
         localModels: LocalModelRegistry? = nil, displayPreferences: UserDefaults? = nil) {
        let preferences = displayPreferences ?? (restoredSessions == nil ? .standard : nil)
        self.displayPreferences = preferences
        chatDisplayMode = ChatDisplayMode(rawValue: preferences?.string(forKey: ChatDisplayMode.defaultsKey) ?? "") ?? .showLogs
        self.modelCatalog = modelCatalog ?? ModelCatalog(defaults: restoredSessions == nil ? .standard : nil)
        automaticallyDiscoverModels = restoredSessions == nil
        self.localModels = localModels ?? .shared
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
        // Freeze migration in memory before navigation can save over the old layout.
        for (path, state) in projectStates {
            let ids = sessions.filter { $0.project.path == path }.map(\.id)
            let migrated = state.chatRegionLayout(validIDs: Set(ids), fallbackIDs: ids.filter { !closedTabs.contains($0) },
                                                  preferTabbed: saved?.layoutMode == .tabs)
            var updated = state
            updated.regions = migrated.regions; updated.layout = migrated.layout; updated.focusedPane = migrated.focused
            projectStates[path] = updated
        }
        // Migrate the previously saved single workspace into its project.
        if let id = saved?.primary, let s = sessions.first(where: { $0.id == id }), projectStates[s.project.path] == nil {
            projectStates[s.project.path] = ProjectViewState(primary: id, secondary: saved?.secondary)
        }
        if let fraction = saved?.sidebarChatFraction, fraction.isFinite {
            sidebarSplit.chatFraction = CGFloat(min(0.9, max(0.1, fraction)))
        }
        build()
        if let content = window.contentView { InterfaceTypography.apply(to: content) }
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
        observeLocalModels()
        for session in sessions { configureQueue(for: session) }
        // Reattach to existing work without adding messages to the conversation.
        for session in sessions { session.reconnectAfterRestart() }
        historyCacheTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                SessionHistoryCache.trim(self.sessions)
            }
        }
        refreshNavigation()
        for project in projects where projectStates[project.path]?.historyExpanded == true { discoverHistory(in: project.path) }
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private func build() {
        let outer = NSSplitViewController()
        outer.splitView = WorkspaceSplitView()
        outer.splitView.isVertical = true; outer.splitView.dividerStyle = .thin
        let rail = NSViewController(); rail.view = WorkspaceSurface(fill: FeedPalette.backdrop)
        let sidebarSurface = SidebarSurface()
        sidebarSurface.translatesAutoresizingMaskIntoConstraints = false
        rail.view.addSubview(sidebarSurface)
        NSLayoutConstraint.activate([
            sidebarSurface.leadingAnchor.constraint(equalTo: rail.view.leadingAnchor, constant: SidebarSurface.inset),
            sidebarSurface.trailingAnchor.constraint(equalTo: rail.view.trailingAnchor, constant: -SidebarSurface.inset),
            sidebarSurface.topAnchor.constraint(equalTo: rail.view.topAnchor, constant: SidebarSurface.inset),
            sidebarSurface.bottomAnchor.constraint(equalTo: rail.view.bottomAnchor, constant: -SidebarSurface.inset)
        ])
        // Section headings carry their actions as quiet glyphs at the trailing edge.
        func headingAction(_ button: ThemedButton, _ symbol: String, _ name: String, _ shortcut: String, _ action: Selector) {
            button.target = self; button.action = action
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly; button.isBordered = false
            button.contentTintColor = FeedPalette.muted
            button.toolTip = "\(name) (\(shortcut))"; button.setAccessibilityLabel(name)
        }
        let new = ThemedButton(title: "", target: nil, action: nil)
        headingAction(new, "square.and.pencil", "New chat", "⌘N", #selector(newChat(_:)))
        let chatsTitle = NSTextField(labelWithString: "Chats")
        chatsTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
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
        conversationSidebar.setAccessibilityLabel("Chats")
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
        let open = ThemedButton(title: "", target: nil, action: nil)
        headingAction(open, "folder", "Open Project…", "⌘O", #selector(openProject(_:)))
        open.setAccessibilityHelp("Open a project folder. Keyboard shortcut: Command-O.")
        let foldersTitle = NSTextField(labelWithString: "Projects")
        foldersTitle.font = Typography.section
        foldersTitle.textColor = FeedPalette.muted
        for (button, symbol, name, shortcut, action) in [
            (projectUpButton, "arrow.up", "Project Up", "⌘⇧↑", #selector(selectPreviousProject(_:))),
            (projectDownButton, "arrow.down", "Project Down", "⌘⇧↓", #selector(selectNextProject(_:)))
        ] {
            headingAction(button, symbol, name, shortcut, action)
            button.setAccessibilityHelp("Switch projects in latest-work order, wrapping at the end. Keyboard shortcut: \(shortcut).")
        }
        // Project actions sit in the heading, like New chat above them.
        let folderHeader = NSStackView(views: [foldersTitle, NSView(), open, projectUpButton, projectDownButton])
        folderHeader.orientation = .horizontal; folderHeader.alignment = .centerY
        folderHeader.spacing = 0
        folderHeader.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        let folderSection = NSStackView(views: [folderHeader, tableScroll])
        folderSection.orientation = .vertical; folderSection.alignment = .leading; folderSection.spacing = 8
        commandBarButton.target = self; commandBarButton.action = #selector(toggleCommandBar(_:))
        commandBarButton.symbolName = "magnifyingglass"
        commandBarButton.shortcutTitle = "⌘/"
        commandBarButton.toolTip = "Command Bar (⌘/)"
        commandBarButton.setAccessibilityLabel("Command Bar")
        commandBarButton.setAccessibilityHelp("Search chats, projects, and actions. Keyboard shortcut: Command-Slash.")
        let chatsSection = NSStackView(views: [sidebarHeader, localSearch.field, liveScroll])
        chatsSection.orientation = .vertical; chatsSection.alignment = .leading; chatsSection.spacing = 8
        // Keep 80 points of chat list visible at the divider's minimum.
        sidebarSplit.minimumChatHeight = 28 + 36 + 80 + 2 * chatsSection.spacing
        let projectsSeparator = NSBox()
        projectsSeparator.boxType = .separator
        projectsSeparator.setAccessibilityElement(false)
        let projectSection = NSStackView(views: [folderSection, projectsSeparator, inferenceControls])
        projectSection.orientation = .vertical; projectSection.alignment = .leading; projectSection.spacing = 4
        projectSection.setCustomSpacing(0, after: folderSection)
        sidebarSplit.addArrangedSubview(chatsSection)
        sidebarSplit.addArrangedSubview(projectSection)
        NSLayoutConstraint.activate([
            folderHeader.widthAnchor.constraint(equalTo: folderSection.widthAnchor),
            folderHeader.heightAnchor.constraint(equalToConstant: 28),
            open.widthAnchor.constraint(equalToConstant: 28), open.heightAnchor.constraint(equalToConstant: 28),
            projectUpButton.widthAnchor.constraint(equalToConstant: 28), projectUpButton.heightAnchor.constraint(equalToConstant: 28),
            projectDownButton.widthAnchor.constraint(equalToConstant: 28), projectDownButton.heightAnchor.constraint(equalToConstant: 28),
            tableScroll.widthAnchor.constraint(equalTo: folderSection.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            projectsSeparator.widthAnchor.constraint(equalTo: projectSection.widthAnchor),
            projectsSeparator.heightAnchor.constraint(equalToConstant: 1)
        ])
        let railStack = NSStackView(views: [sidebarSplit])
        railStack.orientation = .vertical; railStack.alignment = .leading; railStack.spacing = 4
        railStack.translatesAutoresizingMaskIntoConstraints = false; sidebarSurface.addSubview(railStack)
        NSLayoutConstraint.activate([
            sidebarSplit.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            sidebarSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 216),
            railStack.leadingAnchor.constraint(equalTo: sidebarSurface.leadingAnchor, constant: 12 - SidebarSurface.inset),
            railStack.trailingAnchor.constraint(equalTo: sidebarSurface.trailingAnchor, constant: SidebarSurface.inset - 12),
            railStack.topAnchor.constraint(equalTo: sidebarSurface.safeAreaLayoutGuide.topAnchor, constant: 8),
            railStack.bottomAnchor.constraint(equalTo: sidebarSurface.bottomAnchor, constant: SidebarSurface.inset - 10),
            sidebarHeader.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            sidebarHeader.heightAnchor.constraint(equalToConstant: 28),
            new.widthAnchor.constraint(equalToConstant: 28), new.heightAnchor.constraint(equalToConstant: 28),
            localSearch.field.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            localSearch.field.heightAnchor.constraint(equalToConstant: 36),
            inferenceControls.widthAnchor.constraint(equalTo: projectSection.widthAnchor),
            folderSection.widthAnchor.constraint(equalTo: projectSection.widthAnchor),
            liveScroll.widthAnchor.constraint(equalTo: chatsSection.widthAnchor),
            liveScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        // Keep the custom raised surface and the native draggable split boundary.
        let sidebarItem = NSSplitViewItem(viewController: rail)
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 280
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.canCollapse = false
        outer.addSplitViewItem(sidebarItem)
        let body = NSViewController(); body.view = bodySurface
        heading.font = .systemFont(ofSize: 17, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        loginButton.target = self; loginButton.action = #selector(signIn(_:))
        let settings = settingsButton
        settings.target = self; settings.action = #selector(showSettings(_:))
        settings.symbolName = "gearshape"
        settings.isIconOnly = false
        settings.shortcutTitle = "⌘,"
        settings.toolTip = "Settings (⌘,)"
        settings.setAccessibilityLabel("Settings")
        settings.setAccessibilityHelp("Open settings. Keyboard shortcut: Command-Comma.")
        rebalanceButton.target = self
        rebalanceButton.action = #selector(rebalanceColumns(_:))
        rebalanceButton.symbolName = "rectangle.split.3x1"
        rebalanceButton.shortcutTitle = ""
        rebalanceButton.toolTip = "Reset all chat columns to a comfortable width"
        rebalanceButton.setAccessibilityLabel("Rebalance")
        rebalanceButton.setAccessibilityHelp("Reset all chat columns to a comfortable width, sized for this window.")
        chatDisplayButton.target = self
        chatDisplayButton.action = #selector(toggleChatDisplayMode(_:))
        chatDisplayButton.setButtonType(.momentaryPushIn)
        chatDisplayButton.shortcutTitle = "⇧⌘L"
        chatDisplayButton.sizingTitles = [ChatDisplayMode.showLogs.title, ChatDisplayMode.justChat.title]
        refreshChatDisplayButton()
        splitBelowButton.target = self
        splitBelowButton.action = #selector(splitBelow(_:))
        splitBelowButton.symbolName = "rectangle.split.1x2"
        splitBelowButton.shortcutTitle = "⇧⌘\\"
        splitBelowButton.toolTip = "Split below (⇧⌘\\)"
        splitBelowButton.setAccessibilityLabel("Split below")
        splitBelowButton.setAccessibilityHelp("Open a new chat below the current chat. Keyboard shortcut: Shift-Command-Backslash.")
        newChatButton.target = self
        newChatButton.action = #selector(newChat(_:))
        newChatButton.shortcutTitle = "⌘N"
        newChatButton.toolTip = "New Chat (⌘N)"
        newChatButton.setAccessibilityLabel("New Chat")
        newChatButton.setAccessibilityHelp("Open a new chat beside the current chat. Keyboard shortcut: Command-N.")
        // Sections by purpose, left to right: app, view, navigate, create.
        let header = WorkspaceHeaderRow(sections: [
            [[commandBarButton], [settingsButton]],
            [[rebalanceButton], [chatDisplayButton]],
            [[focusLeftButton, focusRightButton]],
            [[splitBelowButton], [newChatButton]]
        ])
        headerRow = header
        for (button, symbol, shortcut, action, direction) in [
            (focusLeftButton, "arrow.left", "⌘[", #selector(focusPreviousPane(_:)), "left"),
            (focusRightButton, "arrow.right", "⌘]", #selector(focusNextPane(_:)), "right")
        ] {
            button.target = self
            button.action = action
            button.isEnabled = false
            button.symbolName = symbol
            button.isIconOnly = false
            button.shortcutTitle = shortcut
            button.toolTip = "\(button.title) (\(shortcut))"
            button.setAccessibilityLabel(button.title)
            button.setAccessibilityHelp("Focus the chat to the \(direction), wrapping at the end. Keyboard shortcut: \(shortcut).")
        }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
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
            self.sidebarShadow.isSuppressed = visible
            self.refreshPaneFocus()
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
            header.topAnchor.constraint(equalTo: body.view.safeAreaLayoutGuide.topAnchor, constant: -2),
            header.leadingAnchor.constraint(equalTo: body.view.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: body.view.trailingAnchor, constant: -12),
            tabSplitHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6), tabSplitHost.leadingAnchor.constraint(equalTo: body.view.leadingAnchor), tabSplitHost.trailingAnchor.constraint(equalTo: body.view.trailingAnchor),
            tabSplitHost.bottomAnchor.constraint(equalTo: body.view.bottomAnchor)
        ])
        paneCanvas.onHorizontalScroll = { [weak self] offset in
            self?.sidebarShadow.scrollOffset = offset
            self?.scheduleVisibleTranscripts()
        }
        sidebarShadow.translatesAutoresizingMaskIntoConstraints = false
        body.view.addSubview(sidebarShadow, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarShadow.leadingAnchor.constraint(equalTo: body.view.leadingAnchor),
            sidebarShadow.topAnchor.constraint(equalTo: body.view.topAnchor),
            sidebarShadow.bottomAnchor.constraint(equalTo: body.view.bottomAnchor),
            sidebarShadow.widthAnchor.constraint(equalToConstant: 16)
        ])
        outer.addSplitViewItem(NSSplitViewItem(viewController: body)); window?.contentViewController = outer
        applyHeaderStyle()
    }
    /// Keep Settings, split, chat navigation and New Chat together at the top trailing edge.
    private func applyHeaderStyle() {
        settingsButton.needsDisplay = true
        rebalanceButton.needsDisplay = true
        chatDisplayButton.needsDisplay = true
        splitBelowButton.needsDisplay = true
        newChatButton.needsDisplay = true
        focusLeftButton.needsDisplay = true
        focusRightButton.needsDisplay = true
        bodySurface.fill = InterfaceStyle.isBreathe ? FeedPalette.backdrop : FeedPalette.canvas
        headerRow?.isHidden = false
        headerRow?.needsLayout = true
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
        providerPicker.toolTip = "Choose Codex, Claude Code or a model running on this Mac. Existing conversations keep their provider."
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
        let modelsTitle = NSTextField(labelWithString: "Models")
        modelsTitle.font = Typography.section
        modelsTitle.textColor = FeedPalette.muted
        let modelsHeader = NSStackView(views: [modelsTitle, NSView()])
        modelsHeader.orientation = .horizontal; modelsHeader.alignment = .centerY
        modelsHeader.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        let footer = NSStackView(views: [modelsHeader, providerPicker, model, tuning, access])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 6
        footer.setCustomSpacing(10, after: tuning)
        NSLayoutConstraint.activate([
            modelsHeader.widthAnchor.constraint(equalTo: footer.widthAnchor),
            modelsHeader.heightAnchor.constraint(equalToConstant: 28),
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
        } else if current.model.isEmpty {
            // Only a local chat can have no model yet: it takes the first one found.
            let entry = NSMenuItem(title: list.isEmpty ? "No local models found" : "First available model", action: nil, keyEquivalent: "")
            entry.representedObject = ""
            entry.isEnabled = !list.isEmpty
            self.model.menu?.insertItem(entry, at: 0)
            self.model.select(entry)
        } else {
            // Keep the explicit selection; an unavailable model must report an error, never silently fall back.
            let record = InferenceSettings.modelRecord(for: current.model, in: list)
            let title = (record?["displayName"] as? String).map { "\($0) (\(current.model))" } ?? current.displayName
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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
        rebalanceButton.isEnabled = showsPaneCanvas && !localSearch.isSearching && samplePane == nil
        splitBelowButton.isEnabled = canSplit(activeColumnID.flatMap { columnStore[$0] } ?? primaryColumn, on: .bottom)
        let canNavigate = columns.count > 1 && !localSearch.isSearching && samplePane == nil
        focusLeftButton.isEnabled = canNavigate
        focusRightButton.isEnabled = canNavigate
        for column in columns {
            column.updateFocusAppearance(active: column.columnID == activeColumnID)
        }
    }
    private func renderLayout() {
        guard let paneLayout else { return }
        for column in columns { column.view.removeFromSuperview(); column.removeFromParent() }
        // The pane canvas stays in the window across layout changes. Laying a
        // tree out while detached is far slower, and it keeps its scroll position.
        let showsCanvas = streamSplit.splitViewItems.count == 1 && streamSplit.splitViewItems[0].viewController === paneCanvas
        if !showsCanvas {
            for item in streamSplit.splitViewItems { streamSplit.removeSplitViewItem(item) }
        }
        let controller = PaneLayoutController(layout: paneLayout, columns: columnStore, configureHost: { [weak self] host, column in
            self?.configurePaneHost(host, column)
        }, resized: { [weak self] in
            self?.updateSplitAvailability()
            self?.scheduleStateSave()
        })
        // The canvas keeps its scroll position while the pane tree is swapped.
        // The window never grows to fit panes: they compact, then the area scrolls.
        let topologyChanged = layoutController != nil
        layoutController = controller
        if !showsCanvas { streamSplit.addSplitViewItem(NSSplitViewItem(viewController: paneCanvas)) }
        paneCanvas.setLayout(controller, animated: topologyChanged)
        window?.contentView?.layoutSubtreeIfNeeded()
        paneCanvas.fit()
        refreshPaneFocus()
    }
    private func configurePaneHost(_ host: TabSplitHostView, _ column: ChatColumn) {
        host.validate = { [weak self, weak column] payload, side in
            guard let column else { return false }
            return self?.canDropTab(payload, on: side, in: column) == true
        }
        host.onDrop = { [weak self, weak column] payload, side in
            guard let column else { return false }
            return self?.dropTab(payload, on: side, in: column) == true
        }
    }
    /// True while the pane tree on screen can be changed in place.
    private var showsPaneCanvas: Bool {
        layoutController != nil && paneCanvas.layout === layoutController
            && streamSplit.splitViewItems.count == 1 && streamSplit.splitViewItems[0].viewController === paneCanvas
    }
    private var projects: [URL] {
        var activity: [String: (project: URL, latest: Date)] = [:]
        for session in sessions {
            let path = session.project.path
            var entry = activity[path] ?? (session.project, .distantPast)
            entry.latest = max(entry.latest, session.lastConversationActivity ?? .distantPast)
            activity[path] = entry
        }
        for (path, history) in projectHistoryEntries {
            guard var entry = activity[path] else { continue }
            if let latest = history.compactMap(\.updatedAt).max() { entry.latest = max(entry.latest, latest) }
            activity[path] = entry
        }
        return activity.values.sorted {
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.project.path.localizedStandardCompare($1.project.path) == .orderedAscending
        }.map(\.project)
    }
    private func configure(_ column: ChatColumn) {
        column.setDisplayMode(chatDisplayMode)
        column.onSend = { [weak self, weak column] in
            guard let self, let column else { return }; self.send(from: column)
        }
        column.onStop = { [weak self, weak column] in
            guard let self, let s = column?.session else { return }; self.run { try await s.interrupt() }
        }
        column.onNewChat = { [weak self, weak column] in
            guard let self, let column else { return }; self.newChat(in: column)
        }
        column.onChatDragEnded = { [weak self] in self?.layoutController?.clearPreviews() }
        column.onSplit = { [weak self, weak column] in
            guard let column else { return }; self?.splitPane(column, side: .right)
        }
        column.onSplitBelow = { [weak self, weak column] in
            guard let column else { return }; self?.splitPane(column, side: .bottom)
        }
        column.onSplitAbove = { [weak self, weak column] in
            guard let column else { return }; self?.splitPane(column, side: .top)
        }
        column.onMoveLeft = { [weak self, weak column] in
            guard let column else { return }; self?.moveChat(column, by: -1)
        }
        column.onMoveRight = { [weak self, weak column] in
            guard let column else { return }; self?.moveChat(column, by: 1)
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
        column.onAnswerLocally = { [weak self, weak column] message in
            guard let self, let column, let source = column.session else { return }
            self.answerQueuedChatLocally(message, from: source, in: column)
        }
        column.onFocus = { [weak self, weak column] in
            guard let self, let column else { return }
            self.activeColumnID = column.columnID
            self.activePane = column.stream
            self.refreshProviderControls()
            self.scheduleStateSave()
        }
        column.stream.onViewStateChanged = { [weak self, weak column] state in
            guard let self, let column, !column.transcriptDeferred, let id = column.session?.id else { return }
            column.streamStates[id] = state; self.scheduleStateSave()
        }
    }
    private func rememberDraft(_ column: ChatColumn) {
        if let s = column.session {
            drafts[s.id] = column.prompt.string; attachmentDrafts[s.id] = column.attachments
            guard !column.transcriptDeferred else { return }
            column.streamStates[s.id] = column.stream.viewState
            streamStates[s.id] = column.stream.viewState
        }
    }
    private func restoreStreamState(in column: ChatColumn) {
        guard let id = column.session?.id,
              let state = column.streamStates[id] ?? streamStates[id] else { return }
        column.streamStates[id] = state
        column.stream.restoreViewState(state)
    }
    private func closeSplit() {
        primaryColumn = focusedColumn
        for column in columns where column !== primaryColumn {
            rememberDraft(column); column.session?.detach(column.stream)
            column.view.removeFromSuperview(); column.removeFromParent()
        }
        columnStore = [primaryColumn.columnID: primaryColumn]
        paneLayout = .pane(primaryColumn.columnID)
        activeColumnID = primaryColumn.columnID
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        activePane = primaryColumn.stream
        renderLayout()
        paneCanvas.balanceToFit()
    }
    func closePane(_ column: ChatColumn) {
        guard columns.contains(column) else { return }
        if let id = column.session?.id {
            closedTabs.removeAll { $0 == id }; closedTabs.append(id)
        }
        if columns.count == 1 {
            paneCanvas.cancelCloseTransition()
            rememberDraft(column)
            column.display(nil)
            selected = nil
            window?.title = "ThoughtStream"; status.stringValue = "Ready"
            refreshActivity(); refreshNavigation(); refreshProviderControls()
            window?.makeFirstResponder(column.prompt)
            navigateProject(by: -1)
            saveWorkspaceState()
            return
        }
        let previousFocus = focusedColumn
        paneLayout = layoutController?.snapshot ?? paneLayout
        let balanceTarget = paneLayout?.removalBalanceTarget(for: column.columnID)
        guard let remaining = paneLayout?.removing(column.columnID) else { return }
        let closingTransition = showsPaneCanvas ? paneCanvas.captureClosingPanes(columns) : nil
        rememberDraft(column)
        column.session?.detach(column.stream)
        // A removed pane must release its transcript and working indicator too.
        column.display(nil)
        column.view.removeFromSuperview(); column.removeFromParent()
        columnStore.removeValue(forKey: column.columnID)
        paneLayout = remaining
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        let nextFocus = previousFocus !== column ? previousFocus :
            (balanceTarget.flatMap { columnStore[$0.paneID] } ?? primaryColumn)
        activeColumnID = nextFocus.columnID
        activePane = nextFocus.stream
        // Take the pane out in place when possible: the others keep their layout.
        if showsPaneCanvas, layoutController?.removePane(column.columnID) == true {
            window?.contentView?.layoutSubtreeIfNeeded()
            paneCanvas.fit()
            refreshPaneFocus()
        } else { renderLayout() }
        paneCanvas.balanceToFit()
        paneLayout = layoutController?.snapshot ?? paneLayout
        refreshNavigation()
        revealPane(nextFocus, animated: false)
        window?.makeFirstResponder(nextFocus.prompt)
        paneCanvas.animateClosingPane(column.columnID, captured: closingTransition, remaining: columns)
    }
    @objc func closeFocusedPane(_ sender: Any?) { closePane(focusedColumn) }
    @objc func singlePane(_ sender: Any?) {
        closeSplit(); refreshNavigation()
    }
    private func rememberProject() {
        guard !switchingProject, samplePane == nil, let path = projectSelection else { return }
        columns.forEach(rememberDraft)
        var state = projectStates[path] ?? ProjectViewState()
        state.layout = layoutController?.snapshot ?? paneLayout
        state.paneCanvasSize = paneCanvas.hasCustomSizing ? paneCanvas.minimumCanvasSize : nil
        state.compactColumnSizing = paneCanvas.usesCompactColumnSizing ? true : nil
        state.regions = columns.map { column in
            let stream = column.transcriptDeferred
                ? column.session.flatMap { column.streamStates[$0.id] ?? streamStates[$0.id] }
                : column.stream.viewState
            return ChatRegionState(id: column.columnID, session: column.session?.id, stream: stream)
        }
        state.focusedPane = focusedColumn.columnID
        state.primary = primaryColumn.session?.id
        state.secondary = secondaryColumn?.session?.id
        state.focusedSecondary = secondaryColumn != nil && focusedColumn === secondaryColumn
        state.tabs = projectChatIndices(path).map { sessions[$0].id }
        state.panes = nil; state.primaryTabs = nil; state.secondaryTabs = nil
        state.primaryTabOffset = nil; state.secondaryTabOffset = nil; state.tabbed = nil
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
    private func refreshNavigation() {
        SessionHistoryCache.trim(sessions)
        // Open panes and unsent drafts are workspace state, not conversations.
        // Also prune old draft ranks so their first message adds them at the top.
        let started = sessions.filter(\.hasStartedConversation).map(\.id)
        let visible = Set(started)
        let existing = Set(sidebarConversationOrder)
        let newChats = started.filter { !existing.contains($0) }
        sidebarConversationOrder = Array(newChats.reversed()) + sidebarConversationOrder.filter { visible.contains($0) }
        conversationIDs = sidebarConversationOrder
        if historyEnabled && !stopped {
            let focused = focusedColumn.session?.id
            let open = Set(columns.compactMap { $0.session?.id })
            let visibleSessions = sessions.filter { visible.contains($0.id) }.sorted {
                if ($0.id == focused) != ($1.id == focused) { return $0.id == focused }
                if open.contains($0.id) != open.contains($1.id) { return open.contains($0.id) }
                return ($0.lastConversationActivity ?? .distantPast) > ($1.lastConversationActivity ?? .distantPast)
            }
            threadSummaries.schedule(visibleSessions, generate: { [weak self] session, input in
                guard let self else { throw CancellationError() }
                if session.provider == .gemini {
                    // Keep the prompt-derived title; do not launch another CLI
                    // with tools just to generate a sidebar label.
                    return session.title
                }
                if session.provider == .local {
                    return try await ChatThreadSummary.generateLocally(input: input, model: session.inferenceSettings.model, registry: self.localModels)
                }
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
        let orderedProjects = projects
        projectRows = orderedProjects.flatMap { project -> [ProjectHistoryRow] in
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
        let canNavigateProjects = orderedProjects.count > 1
        projectUpButton.isEnabled = canNavigateProjects
        projectDownButton.isEnabled = canNavigateProjects
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
        updateSplitAvailability()
        for column in columns { column.updateHeader() }
        if let current = focusedColumn.session { window?.title = current.sidebarTitle }
        scheduleStateSave()
    }
    func select(_ index: Int, in requestedColumn: ChatColumn? = nil, centerPane: Bool = false) {
        guard sessions.indices.contains(index) else { return }
        let s = sessions[index]
        closedTabs.removeAll { $0 == s.id }
        var target = requestedColumn ?? primaryColumn
        if projectSelection != s.project.path || samplePane != nil { selectProject(s.project.path); target = primaryColumn }
        sampleTimer?.invalidate(); sampleTimer = nil; samplePane = nil
        if let existing = columns.first(where: { $0.session === s }) {
            target = existing
            if target.transcriptDeferred {
                target.attachDeferredTranscript()
                restoreStreamState(in: target)
            }
        } else if target.session != nil {
            let new = ChatColumn(); configure(new)
            bind(s)
            new.display(s, draft: drafts[s.id] ?? "", attachments: attachmentDrafts[s.id] ?? [])
            restoreStreamState(in: new)
            insertPane(new, beside: target, side: .right)
            target = new
        }
        rememberDraft(target)
        projectSelection = s.project.path
        bind(s)
        // Re-selecting the active chat must preserve its live selection and navigation.
        if target.session !== s {
            target.display(s, draft: drafts[s.id] ?? "", attachments: attachmentDrafts[s.id] ?? [])
            restoreStreamState(in: target)
        }
        if target === primaryColumn { selected = index }
        if layoutController == nil || paneCanvas.parent == nil { renderLayout() }
        activePane = target.stream
        activeColumnID = target.columnID
        window?.makeFirstResponder(target.prompt)
        window?.title = s.sidebarTitle
        refreshProviderControls()
        status.stringValue = s.ready ? "Connected" : "Ready to connect"
        refreshActivity(); refreshNavigation(); loadHistoryIfNeeded(s)
        revealPane(target, centerHorizontally: centerPane)
    }
    private func refreshActivity() {
        activityTimer?.invalidate(); activityTimer = nil
        if session?.turn != nil {
            sendButton.title = "Steer  ↵"
            if startedAt == nil { startedAt = Date() }
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let start = self.startedAt else { return }
                    self.activePane?.status.stringValue = "Working · \(Int(Date().timeIntervalSince(start)))s"
                }
            }
        } else { sendButton.title = "Send  ↵"; startedAt = nil }
    }
    @objc func selectPreviousTab(_ sender: Any?) { selectAdjacentTab(offset: -1) }
    @objc func selectNextTab(_ sender: Any?) { selectAdjacentTab(offset: 1) }
    private func selectAdjacentTab(offset: Int) { movePaneFocus(by: offset) }
    @objc func closeTab(_ sender: Any?) {
        // ⌘W in Settings or a preview window closes that window, not a chat.
        if let key = NSApp.keyWindow, key !== window { key.performClose(sender); return }
        closePane(focusedColumn)
        saveWorkspaceState()
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        while let id = closedTabs.popLast() {
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                select(index, in: focusedColumn)
                window?.makeFirstResponder(focusedColumn.prompt)
                return
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
        select(index, in: focusedColumn, centerPane: true)
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
            select(index, in: focusedColumn, centerPane: true)
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
    @objc func selectPreviousProject(_ sender: Any?) { navigateProject(by: -1) }
    @objc func selectNextProject(_ sender: Any?) { navigateProject(by: 1) }

    private func navigateProject(by offset: Int) {
        // Follow the displayed project rows, ignoring expanded conversation rows.
        let ordered = projectRows.compactMap { row -> URL? in
            if case .project(let project) = row { return project }
            return nil
        }
        guard ordered.count > 1 else { return }
        let index = ordered.firstIndex { $0.path == projectSelection }
        let destination = index.map { ($0 + offset + ordered.count) % ordered.count }
            ?? (offset > 0 ? 0 : ordered.count - 1)
        localSearch.dismiss()
        selectProject(ordered[destination].path)
        if projectHistoryTable.selectedRow >= 0 {
            projectHistoryTable.scrollRowToVisible(projectHistoryTable.selectedRow)
        }
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
        paneCanvas.setLayout(nil)
        projectSelection = path; selected = nil
        let state = projectStates[path] ?? ProjectViewState()
        paneCanvas.minimumCanvasSize = state.paneCanvasSize ?? .zero
        paneCanvas.hasCustomSizing = state.paneCanvasSize != nil
        paneCanvas.usesCompactColumnSizing = state.compactColumnSizing ?? false
        let validIDs = Set(sessions.filter { $0.project.path == path }.map(\.id))
        let restored = state.chatRegionLayout(validIDs: validIDs, fallbackIDs: projectChatIndices(path).map { sessions[$0].id })
        columnStore = [:]
        hasDeferredTranscripts = restored.regions.count > PaneLayout.visibleColumnsBeforeScrolling
        for region in restored.regions {
            let column = ChatColumn(id: region.id); configure(column)
            columnStore[region.id] = column
            let current = sessions.first { $0.id == region.session && $0.project.path == path }
            if let current {
                bind(current)
                if let stream = region.stream { column.streamStates[current.id] = stream }
            }
            column.display(current, draft: current.flatMap { drafts[$0.id] } ?? "", attachments: current.flatMap { attachmentDrafts[$0.id] } ?? [],
                           deferTranscript: hasDeferredTranscripts && region.id != restored.focused)
        }
        paneLayout = restored.layout
        primaryColumn = columns[0]
        let openIDs = Set(columns.compactMap { $0.session?.id })
        closedTabs.removeAll { openIDs.contains($0) }
        renderLayout()
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        for column in columns where !column.transcriptDeferred { restoreStreamState(in: column) }
        let focused = restored.focused.flatMap { columnStore[$0] } ?? primaryColumn
        revealPane(focused, animated: false)
        activeColumnID = focused.columnID
        activePane = focused.stream; refreshProviderControls(); window?.makeFirstResponder(focused.prompt)
        window?.title = focused.session?.sidebarTitle ?? "ThoughtStream"
        status.stringValue = focused.session.map { $0.ready ? "Connected" : "Ready to connect" } ?? "Ready"
        refreshActivity(); refreshNavigation()
        for column in columns where !column.transcriptDeferred {
            if let session = column.session { loadHistoryIfNeeded(session) }
        }
        updateVisibleTranscripts()
    }

    private func scheduleVisibleTranscripts() {
        guard hasDeferredTranscripts, !switchingProject, !transcriptUpdateScheduled, !stopped else { return }
        transcriptUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.transcriptUpdateScheduled = false
            self?.updateVisibleTranscripts()
        }
    }

    private func updateVisibleTranscripts() {
        guard hasDeferredTranscripts, showsPaneCanvas, !stopped else { return }
        let pending = columnStore.values.filter { $0.transcriptDeferred }
        for column in pending where !column.view.visibleRect.isEmpty {
            column.attachDeferredTranscript()
            restoreStreamState(in: column)
            if let session = column.session { loadHistoryIfNeeded(session) }
        }
        hasDeferredTranscripts = pending.contains { $0.transcriptDeferred }
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
        // Gemini conversations already have their native saved feed. Do not
        // start a Codex history reader for a different provider's session ID.
        guard session.provider != .gemini else { return }
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
        // Local runtimes start and stop at will, and asking them is nearly free.
        let stale = provider == .local ? true : modelCatalog.needsRefresh(for: provider)
        guard automaticallyDiscoverModels, stale,
              Date().timeIntervalSince(modelRefreshAttempts[provider] ?? .distantPast) > (provider == .local ? 4 : 60) else { return }
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
                if provider == .local {
                    await self.localModels.refresh()
                    guard !self.stopped else { return }
                    self.modelCatalog.update(self.localModels.records, for: .local)
                    if showError, self.localModels.models.isEmpty {
                        throw CodexConnection.error(self.localModels.statuses.contains(where: \.isRunning)
                            ? "A local runtime is running, but it has no chat models yet. Download one in Ollama, LM Studio or Jan."
                            : "No local model runtime is answering on this Mac. Start Ollama, LM Studio or Jan (Settings → Local Models can start one for you).")
                    }
                    return
                }
                if provider == .gemini {
                    self.modelCatalog.update(ModelCatalog.geminiRecords, for: .gemini)
                    return
                }
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
        id.placeholderString = provider == .claude ? "claude-fable-5-2" : provider == .gemini ? "gemini-4-carbon" : provider == .local ? "ollama|llama3.2" : "Model ID"
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
        settings = settings.resolvingEffort(in: modelCatalog.models(for: provider))
        if provider == .codex { settings = settings.resolvingCodexTier(in: modelCatalog.models(for: provider)) }
        else if !InferenceSettings.supportsClaudeFastMode(id, in: modelCatalog.models(for: provider)) { settings.tier = "default" }
        inferenceSession?.setInferenceSettings(settings)
        settings.save(provider: provider)
        refreshProviderControls()
        refreshNavigation()
    }
    @objc private func modelSelected() {
        guard let selected = model.selectedItem?.representedObject as? String else { refreshProviderControls(); return }
        let tier = speed.selectedItem?.representedObject as? String ?? "default"
        var settings = currentInferenceSettings
        settings.model = selected
        refreshEfforts(preferred: settings.resolvingEffort(in: models).effort)
        refreshSpeeds(preferred: tier)
        settingsChanged()
    }
    private func refreshSpeeds(preferred: String) {
        let provider = currentProvider
        let selectedModel = model.selectedItem?.representedObject as? String ?? ""
        let supportsFast = provider != .claude || InferenceSettings.supportsClaudeFastMode(selectedModel, in: models)
        // A local model has one speed: this Mac's.
        speed.isHidden = [.local, .gemini].contains(provider)
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
            ? "Fast mode requires a supported Claude model and usage credits. Applies to the next turn."
            : "Faster tiers can use more of your allowance. Availability is checked when you send; unavailable speeds fall back to Fast or Standard."
    }
    private func refreshEfforts(preferred: String) {
        let selectedModel = model.selectedItem?.representedObject as? String ?? ""
        let record = InferenceSettings.modelRecord(for: selectedModel, in: models)
        var values = (record?["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        if values.isEmpty { values = currentProvider == .claude ? InferenceSettings.claudeEfforts : [preferred] }
        // Passive discovery must not change a conversation's saved effort.
        // Explicit model changes resolve against capabilities before reaching here.
        let missingSelection = !values.contains(preferred)
        if missingSelection { values.append(preferred) }
        effort.removeAllItems(); effort.addItems(withTitles: values)
        effort.selectItem(withTitle: preferred)
        effort.isHidden = [.local, .gemini].contains(currentProvider)
        effort.toolTip = missingSelection
            ? "Your saved effort is \(preferred). The latest model list doesn’t advertise it; choose another effort if the provider rejects it."
            : "Reasoning effort"
    }
    @objc private func settingsChanged() {
        let settings = chosenSettings
        inferenceSession?.setInferenceSettings(settings)
        settings.save(provider: currentProvider)
        refreshNavigation()
    }
    var chosenSettings: InferenceSettings {
        let saved = currentInferenceSettings
        return InferenceSettings(
            model: model.selectedItem?.representedObject as? String ?? saved.model,
            effort: effort.titleOfSelectedItem ?? saved.effort,
            tier: speed.selectedItem?.representedObject as? String ?? saved.tier)
    }
    @objc func toggleCommandBar(_ sender: Any?) {
        if commandBar.isVisible { commandBar.dismiss(); return }
        guard let window else { return }
        commandBar.show(in: window, toggleButton: commandBarButton, items: commandBarItems()) { [weak self] query in
            guard let self else { return }
            self.localSearch.field.stringValue = query
            self.localSearch.queryChanged()
            self.window?.makeFirstResponder(self.localSearch.field)
        }
    }

    private func commandBarItems() -> [CommandBarItem] {
        var items: [CommandBarItem] = []
        func action(_ title: String, _ symbol: String, _ shortcut: String = "", _ keywords: String = "", _ selector: Selector) {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            guard validateMenuItem(menuItem) else { return }
            items.append(CommandBarItem(id: NSStringFromSelector(selector), title: title, detail: "Action",
                                        symbol: symbol, shortcut: shortcut, keywords: keywords) { [weak self] in
                guard let self, self.validateMenuItem(menuItem) else { return }
                NSApp.sendAction(selector, to: self, from: nil)
            })
        }
        action("New Chat", "square.and.pencil", "⌘N", "create conversation", #selector(newChat(_:)))
        action("Open Project…", "folder", "⌘O", "directory workspace", #selector(openProject(_:)))
        action("Settings…", "gearshape", "⌘,", "preferences model", #selector(showSettings(_:)))
        action(chatDisplayMode == .showLogs ? "Show Just Chat" : "Show Logs", "text.bubble", "⇧⌘L", "display activity", #selector(toggleChatDisplayMode(_:)))
        action("Split Right", "rectangle.split.2x1", "⌘P", "pane", #selector(splitStream(_:)))
        action("Split Below", "rectangle.split.1x2", "⇧⌘\\", "pane", #selector(splitBelow(_:)))
        action("Focus Left", "arrow.left", "⌘[", "pane previous", #selector(focusPreviousPane(_:)))
        action("Focus Right", "arrow.right", "⌘]", "pane next", #selector(focusNextPane(_:)))
        action("Rebalance Columns", "rectangle.split.3x1", "", "resize arrange", #selector(rebalanceColumns(_:)))
        action("Reopen Closed Chat", "arrow.uturn.backward", "⇧⌘T", "restore conversation", #selector(reopenClosedTab(_:)))
        action("Find in Current Chat", "doc.text.magnifyingglass", "⌘F", "search", #selector(find(_:)))
        items.append(CommandBarItem(id: "search", title: "Search All Chat History", detail: "Search messages and responses",
                                    symbol: "text.magnifyingglass", keywords: "find archive") { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.localSearch.field)
        })
        for id in sidebarConversationOrder {
            guard let chat = sessions.first(where: { $0.id == id }) else { continue }
            items.append(CommandBarItem(id: id.uuidString, title: chat.sidebarTitle,
                                        detail: "Chat · \(chat.project.lastPathComponent) · \(chat.provider.label)",
                                        symbol: "bubble.left", keywords: chat.title) { [weak self] in
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.localSearch.dismiss()
                self.select(index, centerPane: true)
            })
        }
        for project in projects {
            items.append(CommandBarItem(id: project.path, title: project.lastPathComponent,
                                        detail: "Project · \(project.path)", symbol: "folder") { [weak self] in
                self?.localSearch.dismiss()
                self?.selectProject(project.path)
            })
        }
        return items
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
                claudeStatus: claudeAccountStatus, localModels: localModels)
            settingsController?.scansLocalModelsWhenShown = automaticallyDiscoverModels
        }
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
            // A local model needs no executable, sign-in or Internet.
            if session.provider == .local { try await session.connectLocal(); return }
            if session.provider == .gemini {
                try await session.connect(GeminiConnection.executable())
                return
            }
            let executable = try session.provider == .claude ? ClaudeConnection.executable() : self.executable(allowPrompt: false)
            try await session.connect(executable)
            guard try await session.isAuthenticated() else {
                throw CodexConnection.error("Sign in to \(session.provider.label), then retry this queued message.")
            }
        }
    }
    // MARK: Local models

    private func observeLocalModels() {
        let center = NotificationCenter.default
        localObservers.append(center.addObserver(forName: .localModelsDidChange, object: localModels, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localModelsChanged() }
        })
        localObservers.append(center.addObserver(forName: .connectivityDidChange, object: ConnectivityMonitor.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                // Find out what can answer here before the next message needs it.
                if ConnectivityMonitor.shared.isOffline, self.automaticallyDiscoverModels { Task { await self.localModels.refresh() } }
                self.refreshLocalFallbackOffer()
            }
        })
        guard automaticallyDiscoverModels else { return }
        Task { [weak self] in await self?.localModels.refresh() }
    }

    private func localModelsChanged() {
        guard !stopped else { return }
        modelCatalog.update(localModels.records, for: .local)
        if currentProvider == .local { populateModelList(modelCatalog.models(for: .local)) }
        refreshLocalFallbackOffer()
    }

    /// Waiting cloud messages offer a local answer only while it is real:
    /// the Internet is away, the setting is on, and a model is here.
    private func refreshLocalFallbackOffer() {
        let offer = localModels.usesLocalModelsOffline && ConnectivityMonitor.shared.isOffline
            ? localModels.preferredModel()?.name : nil
        guard offer != QueuedChatPresentation.localModelName else { return }
        QueuedChatPresentation.localModelName = offer
        for column in columns where column.session?.outbox.pending != nil { column.conversation.rerender() }
    }

    /// A chat with nothing said and no cloud thread can simply become local.
    private func canFallBackLocally(_ session: Session) -> Bool {
        localModels.usesLocalModelsOffline && session.provider.needsInternet && ConnectivityMonitor.shared.isOffline
            && !session.ready && !session.hasStartedConversation
    }

    /// A model that can answer now, starting an installed runtime if none is serving.
    private func availableLocalModel(status: NSTextField? = nil) async -> LocalModel? {
        if let model = localModels.preferredModel() { return model }
        await localModels.refresh()
        if let model = localModels.preferredModel() { return model }
        for runtime in localModels.startableRuntimes() {
            status?.stringValue = "Offline · starting \(runtime.name)…"
            if await localModels.startRuntime(runtime), let model = localModels.preferredModel() { return model }
        }
        return nil
    }

    /// Move a message that is waiting for the cloud into a new local chat in
    /// the same pane. The conversation so far goes with it as context; the
    /// original chat keeps its history and loses only the waiting message.
    private func answerQueuedChatLocally(_ id: UUID, from source: Session, in column: ChatColumn) {
        run {
            guard let model = await self.availableLocalModel(status: column.stream.status) else {
                throw CodexConnection.error("No local model is available. Start Ollama, LM Studio or Jan and download a model, then try again.")
            }
            let context = source.history.filter { $0.queuedMessageID == nil }
            guard let message = try source.withdrawQueuedChat(id) else { return }
            let chat = Session(project: source.project, title: source.title == "New chat" ? "New chat" : source.title + " · local", provider: .local)
            let settings = InferenceSettings(model: model.identifier, effort: "default", tier: "default")
            chat.setInferenceSettings(settings)
            chat.importSearchHistory(context)
            self.sessions.append(chat)
            self.select(self.sessions.count - 1, in: column)
            try chat.enqueueChat(message.text, attachments: message.attachments, settings: settings)
            self.refreshNavigation(); self.saveWorkspaceState()
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
        var settings = inferenceSession === s ? chosenSettings : s.inferenceSettings
        column.sendButton.isEnabled = false
        column.stream.status.stringValue = s.ready ? "Sending…" : "Connecting to \(s.provider.label)…"
        run {
            defer { column.sendButton.isEnabled = true; column.refresh(); self.refreshNavigation() }
            // No Internet and nothing said yet: let a model on this Mac answer
            // now rather than leave a new chat waiting for the cloud.
            if self.canFallBackLocally(s), let model = await self.availableLocalModel(status: column.stream.status) {
                s.provider = .local
                settings = InferenceSettings(model: model.identifier, effort: "default", tier: "default")
                self.bind(s)
                s.report(.system, "No Internet connection. \(model.name) is answering on this Mac. Turn this off in Settings → Local Models.")
                if self.inferenceSession === s { self.refreshProviderControls() }
            }
            settings.save(provider: s.provider)
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
              source.session?.id == payload.sessionID,
              sessions.contains(where: { $0.id == payload.sessionID && $0.project.path == projectSelection }) else { return false }
        return target != nil && target !== source && canSplit(target!, on: side)
    }

    /// There is always room: panes compact, then the pane area scrolls.
    private func canSplit(_ column: ChatColumn, on side: TabSplitSide) -> Bool {
        samplePane == nil && columns.contains(column)
    }

    /// Reveal list/keyboard selections and layout changes. Direct interaction
    /// inside a pane keeps the content under the pointer stationary.
    private func revealPane(_ column: ChatColumn, animated: Bool = true, centerHorizontally: Bool = false) {
        guard layoutController != nil, column.isViewLoaded else { return }
        paneCanvas.reveal(column.view, animated: animated, centerHorizontally: centerHorizontally)
    }

    @objc func arrangePanes(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let arrangement = PaneArrangement(rawValue: raw) else { return }
        arrangePanes(as: arrangement)
    }
    /// Rebuild the pane tree as a tidy grid, row or column, keeping every
    /// chat's draft and reading position.
    func arrangePanes(as arrangement: PaneArrangement) {
        guard samplePane == nil, columns.count > 1,
              let arranged = PaneLayout.arranged(columns.map(\.columnID), as: arrangement, viewport: paneCanvas.viewport) else { return }
        let focus = focusedColumn
        columns.forEach(rememberDraft)
        paneLayout = arranged
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        renderLayout()
        paneCanvas.balanceToFit()
        paneLayout = layoutController?.snapshot ?? paneLayout
        activeColumnID = focus.columnID; activePane = focus.stream
        revealPane(focus, animated: false)
        refreshNavigation(); saveWorkspaceState()
        window?.makeFirstResponder(focus.prompt)
    }
    @objc func balancePanes(_ sender: Any?) {
        guard columns.count > 1 else { return }
        paneCanvas.balanceToFit()
        paneLayout = layoutController?.snapshot ?? paneLayout
        scheduleStateSave()
    }

    private func updateSplitAvailability() {
        splitBelowButton.isEnabled = canSplit(focusedColumn, on: .bottom)
        for (index, column) in columns.enumerated() {
            column.canMoveLeft = index > 0
            column.canMoveRight = index + 1 < columns.count
            column.updateSplitAvailability(split: canSplit(column, on: .right), stack: canSplit(column, on: .bottom))
        }
    }
    private func moveChat(_ column: ChatColumn, by offset: Int) {
        guard let index = columns.firstIndex(of: column), columns.indices.contains(index + offset),
              let session = column.session else { return }
        let target = columns[index + offset]
        dropTab(ChatTabDrag(sessionID: session.id, columnID: column.columnID), on: offset < 0 ? .left : .right, in: target)
    }
    @objc func moveChatLeft(_ sender: Any?) { moveChat(focusedColumn, by: -1) }
    @objc func moveChatRight(_ sender: Any?) { moveChat(focusedColumn, by: 1) }
    @discardableResult
    func dropTab(_ payload: ChatTabDrag, on side: TabSplitSide, in target: ChatColumn? = nil) -> Bool {
        guard canDropTab(payload, on: side, in: target),
              let source = columns.first(where: { $0.columnID == payload.columnID }),
              sessions.contains(where: { $0.id == payload.sessionID }) else { return false }
        guard let destination = target else { return false }
        columns.forEach(rememberDraft)
        let current = layoutController?.snapshot ?? paneLayout
        guard let remaining = current?.removing(source.columnID) else { return false }
        let old = PaneLayout.pane(destination.columnID), movedRegion = PaneLayout.pane(source.columnID)
        let branch = PaneLayout.split(vertical: side.vertical, fraction: 0.5,
                                      first: side.leading ? movedRegion : old, second: side.leading ? old : movedRegion)
        paneLayout = remaining.replacing(destination.columnID, with: branch)
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        renderLayout()
        activeColumnID = source.columnID; activePane = source.stream
        revealPane(source)
        window?.makeFirstResponder(source.prompt)
        refreshActivity(); refreshNavigation(); saveWorkspaceState()
        return true
    }
    private func insertPane(_ new: ChatColumn, beside column: ChatColumn, side: TabSplitSide) {
        paneLayout = layoutController?.snapshot ?? paneLayout
        var preservedWidths: [UUID: CGFloat]?
        if paneCanvas.hasCustomSizing, let layoutController, let paneLayout {
            preservedWidths = Dictionary(uniqueKeysWithValues: zip(paneLayout.ids, layoutController.paneViews).map {
                ($0.0, $0.1.bounds.width)
            })
            let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
            let defaultWidth = PaneLayout.adaptiveMinimum(viewport: paneCanvas.viewport, paneInset: inset).width + 2 * inset
            let newWidth = side.vertical ? defaultWidth : preservedWidths?[column.columnID]
            preservedWidths?[new.columnID] = newWidth
        }
        let old = PaneLayout.pane(column.columnID), added = PaneLayout.pane(new.columnID)
        let branch = PaneLayout.split(vertical: side.vertical, fraction: 0.5,
                                      first: side.leading ? added : old, second: side.leading ? old : added)
        columnStore[new.columnID] = new
        paneLayout = paneLayout?.replacing(column.columnID, with: branch)
        primaryColumn = columns[0]
        selected = primaryColumn.session.flatMap { current in sessions.firstIndex { $0 === current } }
        activeColumnID = new.columnID; activePane = new.stream
        if InterfaceStyle.isBreathe, showsPaneCanvas { paneCanvas.softenTopologyChange(duration: 0.2) }
        // Add the pane in place when possible, so a workspace with many panes
        // does not rebuild and re-lay-out every one of them for each split.
        if showsPaneCanvas, layoutController?.insertPane(new, beside: column.columnID, vertical: side.vertical, leading: side.leading,
                                                          configureHost: { [weak self] in self?.configurePaneHost($0, $1) }) == true {
            window?.contentView?.layoutSubtreeIfNeeded()
            paneCanvas.fit()
            refreshPaneFocus()
        } else { renderLayout() }
        if let preservedWidths, let layoutController {
            let width = layoutController.preserveWidths(preservedWidths)
            paneCanvas.minimumCanvasSize.width = max(paneCanvas.minimumCanvasSize.width, width)
            paneCanvas.fit()
            layoutController.restoreFractions()
        } else { paneCanvas.balanceToFit() }
        paneLayout = layoutController?.snapshot ?? paneLayout
        revealPane(new)
        Breathe.popOpen(new.view)
        window?.makeFirstResponder(new.prompt)
    }
    func splitPane(_ column: ChatColumn, side: TabSplitSide) {
        guard canSplit(column, on: side) else { return }
        if column.session == nil { newChat(in: column); return }
        guard let path = projectSelection else { return }
        let s = Session(project: URL(fileURLWithPath: path), provider: AgentProvider.selected); sessions.append(s); bind(s)
        let new = ChatColumn(); configure(new)
        new.display(s)
        insertPane(new, beside: column, side: side)
        refreshNavigation()
    }
    @objc func splitStream(_ sender: Any?) { splitPane(focusedColumn, side: .right) }
    @objc func stackStream(_ sender: Any?) { splitPane(focusedColumn, side: .bottom) }
    @objc func splitAbove(_ sender: Any?) { splitPane(focusedColumn, side: .top) }
    @objc func splitBelow(_ sender: Any?) { stackStream(sender) }
    @objc func rebalanceColumns(_ sender: Any?) {
        guard showsPaneCanvas else { return }
        paneCanvas.shrinkColumnsToMinimum()
        paneLayout = layoutController?.snapshot ?? paneLayout
        revealPane(focusedColumn, animated: false)
        saveWorkspaceState()
    }
    @objc func toggleChatDisplayMode(_ sender: Any?) {
        chatDisplayMode = chatDisplayMode.next
        displayPreferences?.set(chatDisplayMode.rawValue, forKey: ChatDisplayMode.defaultsKey)
        paneCanvas.cancelCloseTransition()
        columns.forEach { $0.setDisplayMode(chatDisplayMode) }
        refreshChatDisplayButton()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func refreshChatDisplayButton() {
        // The button names what a click does, and never tints to mark a mode.
        let logsUp = chatDisplayMode == .showLogs
        chatDisplayButton.title = chatDisplayMode.next.title
        chatDisplayButton.symbolName = logsUp ? "bubble.left.and.bubble.right" : "list.bullet.rectangle"
        chatDisplayButton.state = .off
        chatDisplayButton.toolTip = logsUp ? "Hide logs and show just the chat (⇧⌘L)" : "Show logs above the chat (⇧⌘L)"
        chatDisplayButton.setAccessibilityLabel("Chat display mode")
        chatDisplayButton.setAccessibilityValue(logsUp ? "Logs and chat" : "Chat only")
        chatDisplayButton.setAccessibilityHelp("Switch between Show logs and Just chat. Keyboard shortcut: Command-Shift-L.")
        chatDisplayButton.needsDisplay = true
    }
    @objc func focusNextPane(_ sender: Any?) { movePaneFocus(by: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { movePaneFocus(by: -1) }
    private func movePaneFocus(by offset: Int) {
        let panes = columns
        guard panes.count > 1, let index = panes.firstIndex(of: focusedColumn) else { return }
        let target = panes[(index + offset + panes.count) % panes.count]
        activeColumnID = target.columnID
        activePane = target.stream
        revealPane(target)
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
    @objc func find(_ sender: Any?) {
        if chatDisplayMode == .justChat { focusedColumn.conversation.find() }
        else { activePane?.find() }
    }
    @objc func findNext(_ sender: Any?) {
        if chatDisplayMode == .justChat { focusedColumn.conversation.find(next: true) }
        else { activePane?.findNext() }
    }
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
        stateStore.save(WorkspaceSnapshot(primary: current?.primary, secondary: current?.secondary, drafts: drafts, streams: streamStates, windowFrame: window.map { NSStringFromRect($0.styleMask.contains(.fullScreen) ? normalFrame ?? $0.frame : $0.frame) }, closedTabs: closedTabs, selectedProject: projectSelection, projects: projectStates, attachmentDrafts: attachmentDrafts, sidebarChatFraction: Double(sidebarSplit.chatFraction), sidebarConversationOrder: sidebarConversationOrder))
    }
    /// Full screen is not a size to reopen at; remember the windowed frame.
    private var normalFrame: NSRect?
    private func rememberNormalFrame() {
        if let window, !window.styleMask.contains(.fullScreen) { normalFrame = window.frame }
    }
    func windowDidResize(_ notification: Notification) {
        // fit() arranges the tree when its viewport or minimum changes.
        // A second restore here reflowed all columns again for the same event.
        if layoutController != nil { paneCanvas.fit() }
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
        applyHeaderStyle()
        for table in [conversationSidebar, projectHistoryTable] {
            table.rowHeight = SidebarMetrics.rowHeight
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        layoutController?.applyInterfaceStyle()
        for column in columns { column.applyInterfaceStyle() }
        if let content = window.contentView { InterfaceTypography.apply(to: content) }
        window.contentView?.layoutSubtreeIfNeeded()
        if layoutController != nil { paneCanvas.fit() }
        layoutController?.restoreFractions()
        updateSplitAvailability()
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        if let content = window.contentView { redraw(content) }
    }

    func stopAll() {
        commandBar.dismiss(restoreFocus: false)
        paneCanvas.cancelCloseTransition()
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
        localObservers.forEach { NotificationCenter.default.removeObserver($0) }; localObservers.removeAll()
        historyCacheTimer?.invalidate(); historyCacheTimer = nil
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
        let standard = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "claude/tool/requestApproval", "local/tool/requestApproval"].contains(method)
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
                let picker = ThemedPopUpButton()
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
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
                return SidebarConversationCell(title: "No chats yet", project: "Start a new chat above", isRunning: false, isEmpty: true)
            }
            let cell = SidebarConversationCell(title: conversation.sidebarTitle, project: conversation.provider.label + " · " + conversation.project.lastPathComponent, isRunning: conversation.turn != nil)
            cell.toolTip = conversation.sidebarTitle + "\n" + conversation.provider.label + " · " + conversation.project.lastPathComponent
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
        sampleTimer?.invalidate(); activityTimer?.invalidate(); selected = nil; heading.stringValue = "Sample · how ThoughtStream works"
        for item in streamSplit.splitViewItems { streamSplit.removeSplitViewItem(item) }
        primaryColumn.display(nil)
        let pane = primaryColumn.stream; activePane = pane; samplePane = pane; streamSplit.addSplitViewItem(NSSplitViewItem(viewController: primaryColumn))
        refreshPaneFocus()
        status.stringValue = "SIMULATED SAMPLE — no model request or command execution"; primaryColumn.updateHeader()
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
        case #selector(toggleChatDisplayMode(_:)):
            item.state = chatDisplayMode == .showLogs ? .on : .off
            return true
        case #selector(forkSession(_:)), #selector(interrupt(_:)), #selector(send(_:)):
            return focusedColumn.session != nil
        case #selector(exportLog(_:)): return session != nil
        case #selector(selectPreviousProject(_:)), #selector(selectNextProject(_:)):
            return projectUpButton.isEnabled
        case #selector(closeFocusedPane(_:)):
            return samplePane == nil && (columns.count > 1 || focusedColumn.session != nil)
        case #selector(singlePane(_:)),
             #selector(focusPreviousPane(_:)), #selector(focusNextPane(_:)),
             #selector(arrangePanes(_:)), #selector(balancePanes(_:)):
            return samplePane == nil && columns.count > 1
        case #selector(splitStream(_:)): return canSplit(focusedColumn, on: .right)
        case #selector(stackStream(_:)), #selector(splitBelow(_:)): return canSplit(focusedColumn, on: .bottom)
        case #selector(splitAbove(_:)): return canSplit(focusedColumn, on: .top)
        case #selector(moveChatLeft(_:)): return columns.first !== focusedColumn && focusedColumn.session != nil
        case #selector(moveChatRight(_:)): return columns.last !== focusedColumn && focusedColumn.session != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        default: return true
        }
    }
}
