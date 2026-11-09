import AppKit

@MainActor
final class Session {
    let id: UUID
    let project: URL
    var provider: AgentProvider {
        didSet {
            if provider != oldValue { storedInferenceSettings = nil; recoveredInferenceSettings = true }
        }
    }
    private var storedInferenceSettings: InferenceSettings?
    private var recoveredInferenceSettings = false
    /// The selection belongs to this conversation, including unsent changes.
    var inferenceSettings: InferenceSettings {
        if let storedInferenceSettings { return storedInferenceSettings }
        if !recoveredInferenceSettings {
            recoveredInferenceSettings = true
            let recovered = persistence.sync {
                SessionInferenceHistory.latest(in: folder.appendingPathComponent("protocol.jsonl"), provider: provider)
            }
            if let recovered { storedInferenceSettings = recovered; save(); return recovered }
        }
        return InferenceSettings.load(provider: provider)
    }
    func setInferenceSettings(_ settings: InferenceSettings) {
        storedInferenceSettings = settings
        recoveredInferenceSettings = true
        save()
    }
    var forkSource: String?
    private var claude: ClaudeConnection?
    private var claudeSettings: InferenceSettings?
    var title: String
    var sidebarSummary: String?
    var sidebarSummaryFingerprint: String?
    var sidebarTitle: String { sidebarSummary ?? title }
    var thread: String?
    var turn: String?
    var client: CodexConnection?
    var ready = false
    private(set) var needsHistory: Bool
    /// The app quit or crashed while this chat's turn was still running.
    private(set) var turnWasInterrupted: Bool
    private var historyLoad: Task<Void, Error>?
    var onStatus: ((String) -> Void)?
    var onRequest: ((Any, String, [String: Any]) -> Void)?
    var onModels: (([[String: Any]]) -> Void)?
    private(set) var codexModels: [[String: Any]] = []
    private var serviceTierWarning: String?

    /// Retry transient discovery failures, then use the fastest advertised tier
    /// without changing the requested model or reasoning effort.
    private func confirmedCodexSettings(_ requested: InferenceSettings, using runtime: CodexConnection,
                                        refresh: Bool) async throws -> InferenceSettings {
        var settings = requested
        if settings.tier == "priority" { settings.tier = "fast" }
        guard settings.tier != "default" else { return settings }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if refresh || attempt > 0 {
                onStatus?("Checking \(settings.tier.capitalized) availability…")
                codexModels = try await runtime.listModels()
                onModels?(codexModels)
            }
            if InferenceSettings.codexTiers(for: settings.model, in: codexModels).contains(settings.tier) {
                return settings
            }
        }
        if codexModels.contains(where: { ($0["model"] as? String ?? $0["id"] as? String) == settings.model }) {
            let fallback = settings.resolvingCodexTier(in: codexModels).tier
            let requestedTier = settings.tier
            settings.tier = fallback
            onStatus?("\(requestedTier.capitalized) unavailable · using \(fallback == "default" ? "Standard" : "Fast")")
            return settings
        }
        throw CodexConnection.error("Could not load availability for \(settings.displayName). Your message is saved; retry when connected.")
    }
    var onRequestResolved: ((String) -> Void)?
    private var connecting = false
    private struct PaneReference { weak var value: StreamPane? }
    private var panes: [PaneReference] = []
    var isDisplayedInMultiplePanes: Bool { panes.compactMap(\.value).count > 1 }
    private var streamed: [String: String] = [:]
    private var finalResponse: StreamRecord?
    private var requests = Set<String>()
    private var feed = FeedBuffer()
    var history: [StreamRecord] { outbox.decorate(feed.records) }
    /// Undecorated, so sorting chats doesn't rebuild every transcript.
    var lastActivity: Date? { feed.records.last?.time }
    /// Startup and connection bookkeeping should not make an old chat look new.
    var lastConversationActivity: Date? {
        feed.records.last { $0.kind == StreamKind.user.rawValue || $0.kind == StreamKind.prose.rawValue }?.time
    }
    let outbox: MessageOutbox
    var queueWorker: Task<Void, Never>?
    var queueRetry: Task<Void, Never>?
    var queueConnection: (() async throws -> Void)?
    var queueNetworkObserver: NSObjectProtocol?
    var queueRetryDelay: UInt64 = 2
    var queueConnectivity = ConnectivityMonitor.shared
    private(set) var protocolEvents: [[String: Any]] = []
    private let folder: URL
    private let historyStore: ConversationStore
    /// One serial queue for every session: reopening a folder drains any
    /// pending writes from an earlier instance before reading it.
    private static let persistenceQueue = DispatchQueue(label: "app.unfold.persistence", qos: .utility)
    private let persistence = Session.persistenceQueue
    private var pendingProtocol = Data()
    private var protocolFlushScheduled = false
    private var intentionalStop = false
    var reconnectTask: Task<Void, Never>?
    var reconnectRequested = false
    private var turnRevision = 0
    private var connectionGeneration = UUID()

    init(project: URL, id: UUID = UUID(), title: String = "New chat", thread: String? = nil, storageRoot: URL? = nil, needsHistory: Bool = false, provider: AgentProvider = .codex, forkSource: String? = nil, turnWasInterrupted: Bool = false) {
        self.project = project; self.id = id; self.title = title; self.thread = thread
        self.turnWasInterrupted = turnWasInterrupted
        self.provider = provider; self.forkSource = forkSource
        self.needsHistory = needsHistory
        folder = (storageRoot ?? Self.base).appendingPathComponent(id.uuidString, isDirectory: true)
        historyStore = ConversationStore(folder: folder)
        outbox = MessageOutbox(url: folder.appendingPathComponent("outbox.json"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = historyStore, protocolURL = folder.appendingPathComponent("protocol.jsonl")
        let loaded = persistence.sync { store.load() }
        if let metadata = persistence.sync(execute: { ConversationStore.metadata(in: folder) }),
           let json = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] {
            sidebarSummary = (json["sidebarSummary"] as? String).flatMap(ChatThreadSummary.clean)
            if sidebarSummary != nil { sidebarSummaryFingerprint = json["sidebarSummaryFingerprint"] as? String }
            if let settings = json["inferenceSettings"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: settings) {
                storedInferenceSettings = try? JSONDecoder().decode(InferenceSettings.self, from: data)
            }
        }
        if storedInferenceSettings == nil, let message = outbox.messages.last {
            storedInferenceSettings = InferenceSettings(model: message.model, effort: message.effort, tier: message.tier)
        }
        let cancelled = (try? outbox.removeLegacyRestartPrompts()) ?? []
        feed = FeedBuffer(loaded.filter { record in
            !MessageOutbox.isLegacyRestartRecord(record) &&
            !cancelled.contains(where: { record.itemID == $0 || record.itemID?.hasPrefix($0 + ":") == true })
        })
        restoreQueuedRecords()
        // Only completed items are needed to restore outcomes. Skip parsing the
        // (much larger) stream of deltas for every saved chat at launch.
        let completed = persistence.sync { Self.completedItemEvents(at: protocolURL) }
        restoreFinalResponses(completed)
        restoreCommandOutcomes(completed)
        // A saved running event does not prove the process survived a crash.
        settleRunningCommands(as: .unknown)
        if store.needsCheckpoint || feed.records != loaded { save() }
        if outbox.messages.contains(where: { $0.state == .delivered }) { try? commitDeliveredQueueRecords() }
    }
    static var base: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UnfoldNative/Sessions", isDirectory: true) }
    static func restored() -> [Session] {
        ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
            guard let data = ConversationStore.metadata(in: url), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let raw = json["id"] as? String, let id = UUID(uuidString: raw), let project = json["project"] as? String else { return nil }
            return Session(project: URL(fileURLWithPath: project), id: id, title: json["title"] as? String ?? "Session", thread: json["thread"] as? String, needsHistory: json["needsHistory"] as? Bool ?? false, provider: AgentProvider(rawValue: json["provider"] as? String ?? "") ?? .codex, forkSource: json["forkSource"] as? String, turnWasInterrupted: json["turnInFlight"] as? Bool ?? legacyTurnInFlight(in: url))
        }.sorted { $0.lastActivity ?? .distantPast > $1.lastActivity ?? .distantPast }
    }
    /// Chats saved before the marker existed: a recent protocol log whose last
    /// turn event is a start means the app quit mid-turn.
    nonisolated static func legacyTurnInFlight(in folder: URL) -> Bool {
        let url = folder.appendingPathComponent("protocol.jsonl")
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < 30 * 60,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let tail = try? handle.readToEnd() else { return false }
        // JSONSerialization escapes slashes; accept either spelling.
        func last(_ event: String) -> Int {
            [#""method":"turn/"#, #""method":"turn\/"#].compactMap { tail.range(of: Data(($0 + event + "\"").utf8), options: .backwards)?.lowerBound }.max() ?? -1
        }
        let started = last("started")
        return started >= 0 && started > last("completed")
    }
    func attach(_ pane: StreamPane) { panes.removeAll { $0.value == nil }; panes.append(PaneReference(value: pane)); pane.projectDirectory = project; pane.replace(history) }
    func detach(_ pane: StreamPane) { panes.removeAll { $0.value == nil || $0.value === pane } }
    func restoreQueuedRecords() {
        let existing = Set(feed.records.compactMap(\.itemID))
        for message in outbox.messages {
            for record in message.records where !existing.contains(record.itemID ?? "") {
                feed.append(record, merging: false)
            }
        }
    }
    func refreshQueuePresentation() {
        panes.forEach { $0.value?.updateQueuePresentation(outbox, records: feed.records) }
        save()
    }
    func removeDuplicateQueuedReceipt(_ receiptID: String) {
        feed = FeedBuffer(feed.records.filter { !($0.kind == StreamKind.user.rawValue && $0.itemID == receiptID) })
    }
    func commitDeliveredQueueRecords() throws {
        // Journal the accepted prompt before removing its crash-recovery copy.
        let records = history
        try historyStore.append(.init(replacement: records))
        try outbox.removeDelivered()
    }
    func appendQueuedChat(_ message: QueuedChat) {
        if title == "New chat" { title = String((message.text.isEmpty ? message.attachments.first?.name ?? "Image chat" : message.text).prefix(50)) }
        for record in message.records {
            persistMutation(.init(record: record, merging: false))
            feed.append(record, merging: false)
            let decorated = outbox.decorate([record])[0]
            panes.forEach { $0.value?.append(decorated, item: decorated.itemID) }
        }
        save()
    }
    func report(_ kind: StreamKind, _ text: String, language: String? = nil, item: String? = nil, delta: Bool = false, command: CommandActivity? = nil) {
        let record = StreamRecord(kind: kind.rawValue, text: text, language: language, itemID: item, command: command)
        persistMutation(.init(record: record, merging: delta))
        feed.append(record, merging: delta)
        panes.forEach { $0.value?.append(record, item: item, delta: delta) }
        scheduleSave()
    }
    private var saveScheduled = false
    private func scheduleSave() {
        guard !saveScheduled else { return }; saveScheduled = true
        // The journal already holds every delta; checkpoints only bound replay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.saveScheduled = false; self?.save() }
    }
    func save() {
        var meta: [String: Any] = ["id": id.uuidString, "project": project.path, "title": title, "thread": thread as Any? ?? NSNull(), "needsHistory": needsHistory, "provider": provider.rawValue, "forkSource": forkSource as Any? ?? NSNull(), "turnInFlight": turn != nil || turnWasInterrupted]
        meta["sidebarSummary"] = sidebarSummary
        meta["sidebarSummaryFingerprint"] = sidebarSummaryFingerprint
        if let settings = storedInferenceSettings {
            meta["inferenceSettings"] = ["model": settings.model, "effort": settings.effort, "tier": settings.tier]
        }
        do {
            let metadata = try JSONSerialization.data(withJSONObject: meta)
            let records = history, store = historyStore
            // The checkpoint and journal must share one ordering: capture the
            // records and the journal offset together, so an older snapshot
            // cannot skip newer deltas. Encoding and writing happen off-main.
            let offset = try store.prepareCheckpoint(metadata: metadata, records: records)
            persistence.async { [weak self] in
                do { try store.writeCheckpoint(metadata: metadata, records: records, journalOffset: offset) }
                catch { Self.reportPersistenceFailure(error, to: self) }
            }
        } catch { onStatus?("History could not be saved: \(error.localizedDescription)") }
    }
    private func persistMutation(_ change: ConversationStore.Mutation) {
        // Written before the change is published, so an app crash cannot lose
        // it. Streaming deltas arrive many times per second; skip the per-line
        // fsync and leave flushing to the kernel.
        do { try historyStore.append(change, synchronize: false) }
        catch { onStatus?("History could not be saved: \(error.localizedDescription)") }
    }
    private nonisolated static func reportPersistenceFailure(_ error: Error, to session: Session?) {
        let message = "History could not be saved: \(error.localizedDescription)"
        DispatchQueue.main.async { MainActor.assumeIsolated { session?.onStatus?(message) } }
    }
    private func flushProtocol() {
        protocolFlushScheduled = false
        guard !pendingProtocol.isEmpty else { return }
        let data = pendingProtocol; pendingProtocol.removeAll(keepingCapacity: true)
        let url = folder.appendingPathComponent("protocol.jsonl")
        persistence.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }

    func loadClaudeHistory(refresh: Bool = false) async throws {
        guard provider == .claude, needsHistory || refresh, let thread else { return }
        let project = project
        let records = try await Task.detached { try ClaudeHistory.transcript(thread, project: project) }.value
        try Task.checkCancellation()
        reconcileHistory(records)
    }

    func loadHistory(using history: ProjectHistory, refresh: Bool = false) async throws {
        guard needsHistory || refresh, provider == .codex, let thread else { return }
        if let historyLoad { return try await historyLoad.value }
        let task = Task { @MainActor in
            let records = try await history.transcript(thread)
            try Task.checkCancellation()
            reconcileHistory(records)
        }
        historyLoad = task
        defer { historyLoad = nil }
        try await task.value
    }

    /// Search imports already-local transcripts without starting a provider runtime.
    func importSearchHistory(_ records: [StreamRecord]) {
        reconcileHistory(records)
    }

    private func reconcileHistory(_ records: [StreamRecord]) {
        // A request may finish after a new turn starts. Defer reconciliation
        // rather than overwriting a live stream with an older provider read.
        guard turn == nil else { return }
        let current = history
        let merged = HistoryReconciliation.merge(local: current, remote: records.filter { !MessageOutbox.isLegacyRestartRecord($0) })
        // Reselecting a tab refreshes from the provider. Most reads change
        // nothing; don't journal and redraw a full copy of the transcript.
        if merged == current {
            if needsHistory { needsHistory = false; save() }
            return
        }
        persistMutation(.init(replacement: merged))
        feed = FeedBuffer(merged); needsHistory = false
        panes.forEach { $0.value?.replace(merged) }
        save()
    }

    func connect(_ executable: URL, persistentRuntime: Bool = true) async throws {
        if ready { return }
        if provider == .claude { try await connectClaude(executable); return }
        guard !connecting else { throw CodexConnection.error("Codex is already connecting. Please try again when it is ready.") }
        connecting = true; intentionalStop = false
        let generation = connectionGeneration
        defer { connecting = false }
        let runtime = CodexConnection(); client = runtime
        runtime.onEvent = { [weak self] event in self?.receive(event) }
        runtime.onDisconnect = { [weak self, weak runtime] in
            guard let self = self, self.client === runtime else { return }
            self.turnWasInterrupted = self.turnWasInterrupted || self.turn != nil
            self.ready = false; self.turn = nil; self.resolveAllRequests()
            self.settleRunningCommands(as: .unknown)
            guard !self.intentionalStop else { return }
            self.save()
            self.reconnectRequested = self.thread != nil
            self.onStatus?("Reconnecting…")
            self.resumeConnection()
        }
        do {
            try await runtime.start(executable: executable, project: project, persistentID: persistentRuntime ? id : nil)
            // Resume also carries inference settings, so discover capabilities
            // before sending any thread or turn settings.
            let models: [[String: Any]]
            do { models = try await runtime.listModels() }
            catch {
                guard thread != nil else { throw error }
                models = []
            }
            codexModels = models
            onModels?(codexModels)
            if let thread = thread {
                var params = AccessMode.selected.threadParameters
                // Reattach to the existing thread without replacing its model,
                // reasoning or speed. Availability matters only for a new turn.
                params["threadId"] = thread
                params["cwd"] = project.path
                params["developerInstructions"] = AgentInstructions.text
                params["excludeTurns"] = true
                params["initialTurnsPage"] = ["limit": 1, "itemsView": "full", "sortDirection": "desc"]
                let revision = turnRevision
                let response = try await runtime.request("thread/resume", params)
                let reader = ProjectHistory(request: { method, params in try await runtime.request(method, params) })
                do { try await loadHistory(using: reader, refresh: true) }
                catch {
                    if needsHistory && history.isEmpty { throw error }
                    onStatus?("Using saved history")
                }
                if revision == turnRevision { restoreRuntimeState(response) }
            }
            guard generation == connectionGeneration, !intentionalStop else { throw CancellationError() }
            ready = true
            turnWasInterrupted = false
            save()
        } catch { client = nil; runtime.stop(); ready = false; throw error }
        onStatus?(turn == nil ? "Ready" : "Agent is working")
    }
    private func connectClaude(_ executable: URL, settings requestedSettings: InferenceSettings? = nil) async throws {
        guard !connecting else { throw CodexConnection.error("Claude Code is already connecting.") }
        connecting = true; intentionalStop = false
        defer { connecting = false }
        do { try await loadClaudeHistory(refresh: true) }
        catch {
            if needsHistory && history.isEmpty { throw error }
            onStatus?("Using saved history; sync will retry when reopened.")
        }
        let runtime = ClaudeConnection()
        claude = runtime
        runtime.onEvent = { [weak self] in self?.receive($0) }
        runtime.onSession = { [weak self] id in self?.thread = id; self?.forkSource = nil; self?.save() }
        runtime.onModels = { [weak self] in self?.onModels?($0) }
        runtime.onDisconnect = { [weak self, weak runtime] in
            guard let self, self.claude === runtime else { return }
            self.ready = false; self.turn = nil; self.resolveAllRequests()
            self.settleRunningCommands(as: .unknown)
            if !self.intentionalStop {
                self.reconnectRequested = self.thread != nil
                self.onStatus?("Reconnecting…"); self.resumeConnection()
            }
        }
        let settings = requestedSettings ?? inferenceSettings
        do {
            try await runtime.start(executable: executable, project: project, settings: settings, resume: forkSource ?? thread, fork: forkSource != nil)
            claudeSettings = settings; ready = true; onStatus?("Claude Code connected")
        } catch { claude = nil; runtime.stop(); throw error }
    }
    func isAuthenticated() async throws -> Bool {
        if provider == .claude { return try await ClaudeConnection.isAuthenticated() }
        guard let client = client, ready else { return false }
        let result = try await client.request("account/read", ["refreshToken": false])
        return (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
    }
    func loginIfNeeded() async throws {
        if provider == .claude {
            if try await isAuthenticated() { onStatus?("Claude Code connected"); return }
            throw CodexConnection.error("Sign in to Claude Code in Terminal with: claude auth login. Then return here and send again.")
        }
        if try await isAuthenticated() { onStatus?("ChatGPT connected"); return }
        guard let client = client, ready else { throw CodexConnection.error("Connect Codex first.") }
        let result = try await client.request("account/login/start", ["type": "chatgpt"])
        if let text = result["authUrl"] as? String, let url = URL(string: text), url.scheme == "https", url.host == "auth.openai.com" {
            NSWorkspace.shared.open(url); onStatus?("Finish signing in in your browser")
        } else { report(.system, Self.pretty(result)) }
    }
    static func messageInput(_ prompt: String, attachments: [ChatAttachment]) throws -> [[String: Any]] {
        guard attachments.count <= ChatAttachment.maximumCount else { throw CodexConnection.error("Attach up to 8 images per message.") }
        var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
        for attachment in attachments {
            guard FileManager.default.isReadableFile(atPath: attachment.path) else {
                throw CodexConnection.error("\(attachment.name) is unavailable. Remove it and attach it again.")
            }
            input.append(attachment.input)
        }
        guard !input.isEmpty else { throw CodexConnection.error("Add a message or an image first.") }
        return input
    }
    func send(_ prompt: String, attachments: [ChatAttachment] = [], model: String? = nil, effort: String? = nil, tier: String? = nil, queuedID: UUID? = nil) async throws {
        if provider == .claude {
            try await sendClaude(prompt, attachments: attachments, model: model, effort: effort, tier: tier, queuedID: queuedID)
            return
        }
        guard let client = client, ready else { throw CodexConnection.error("Connect Codex first.") }
        let input = try Self.messageInput(prompt, attachments: attachments)
        let saved = inferenceSettings
        let requested = InferenceSettings(model: model ?? saved.model, effort: effort ?? saved.effort, tier: tier ?? saved.tier)
        // Steering supplies input to an existing turn and cannot change its tier.
        let settings: InferenceSettings
        if turn != nil { settings = requested }
        else { settings = try await confirmedCodexSettings(requested, using: client, refresh: true) }
        if queuedID == nil || settings != requested {
            setInferenceSettings(settings)
            if settings != requested { onModels?(codexModels) }
        }
        if thread == nil {
            let projectID = try await CodexProjects.resolve(project, using: client)
            var params = AccessMode.selected.threadParameters
            params.merge(settings.threadParameters) { _, value in value }
            params["cwd"] = project.path
            params["projectId"] = projectID
            params["developerInstructions"] = AgentInstructions.text
            serviceTierWarning = nil
            let result = try await client.request("thread/start", params)
            thread = (result["thread"] as? [String: Any])?["id"] as? String
            title = prompt.isEmpty ? attachments.first?.name ?? "Image chat" : String(prompt.prefix(50)); save()
            if let warning = serviceTierWarning { throw CodexConnection.error(warning) }
        }
        guard let thread = thread else { throw CodexConnection.error("No thread ID was returned.") }
        if queuedID == nil {
            if !prompt.isEmpty { report(.user, prompt) }
            for attachment in attachments {
                report(.user, Self.pretty(["type": "local_image", "path": attachment.path, "name": attachment.name]))
            }
        }
        var params: [String: Any] = ["threadId": thread, "input": input]
        if let queuedID {
            let baseline = try? await queuedRemoteItems()
            try markQueueSubmitting(queuedID, baseline: baseline?.compactMap { $0["id"] as? String })
        }
        if let turn = turn { params["expectedTurnId"] = turn; _ = try await client.request("turn/steer", params) }
        else {
            params.merge(AccessMode.selected.turnParameters(project: project)) { _, value in value }
            params["summary"] = "auto"
            params.merge(settings.turnParameters) { _, value in value }
            let result = try await client.request("turn/start", params); turn = (result["turn"] as? [String: Any])?["id"] as? String
        }
    }
    private func sendClaude(_ prompt: String, attachments: [ChatAttachment], model: String?, effort: String?, tier: String?, queuedID: UUID? = nil) async throws {
        _ = try Self.messageInput(prompt, attachments: attachments)
        let saved = inferenceSettings
        let settings = InferenceSettings(model: model ?? saved.model, effort: effort ?? saved.effort, tier: tier ?? saved.tier)
        // Model, effort and speed changes are applied by restarting the idle CLI and resuming
        // the exact session ID, never by substituting another provider's model.
        if claudeSettings != settings {
            guard turn == nil else { throw CodexConnection.error("Wait for Claude to finish before changing its model, effort or speed.") }
            claude?.stop(); claude = nil; ready = false
            try await connectClaude(ClaudeConnection.executable(), settings: settings)
        }
        guard ready, let claude else { throw CodexConnection.error("Connect Claude Code first.") }
        var content: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
        for attachment in attachments {
            let data = try Data(contentsOf: URL(fileURLWithPath: attachment.path))
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]])
        }
        if let queuedID { try markQueueSubmitting(queuedID, baseline: nil) }
        try claude.send(content)
        if queuedID == nil { setInferenceSettings(settings) }
        if title == "New chat" { title = String((prompt.isEmpty ? attachments.first?.name ?? "Image chat" : prompt).prefix(50)) }
        if queuedID == nil {
            if !prompt.isEmpty { report(.user, prompt) }
            for attachment in attachments { report(.user, Self.pretty(["type": "local_image", "path": attachment.path, "name": attachment.name])) }
        }
        save()
    }
    func interrupt() async throws {
        if provider == .claude {
            guard let claude, turn != nil else { throw CodexConnection.error("No active turn.") }
            try await claude.interrupt(); return
        }
        guard let client = client, let thread = thread, let turn = turn else { throw CodexConnection.error("No active turn.") }
        _ = try await client.request("turn/interrupt", ["threadId": thread, "turnId": turn]); report(.system, "Interruption requested. Waiting for the runtime to confirm.")
    }
    func respond(_ id: Any, _ result: [String: Any]) throws {
        guard requests.contains(String(describing: id)) else { throw CodexConnection.error("This request is no longer pending.") }
        if provider == .claude {
            guard let claude, ready else { throw CodexConnection.error("Claude Code is disconnected.") }
            try claude.respond(String(describing: id), result: result); resolveRequest(id); return
        }
        guard let client = client, ready else { throw CodexConnection.error("Codex is disconnected.") }
        try client.respond(id, result: result); resolveRequest(id); report(.system, "Response sent. The action is not yet confirmed complete.")
    }
    func isPending(_ id: Any) -> Bool { requests.contains(String(describing: id)) }
    private func resolveRequest(_ id: Any) {
        let key = String(describing: id)
        if requests.remove(key) != nil { onRequestResolved?(key) }
    }
    private func resolveAllRequests() {
        let pending = requests; requests.removeAll()
        pending.forEach { onRequestResolved?($0) }
    }
    func fork() async throws -> Session {
        if provider == .claude {
            guard let thread, turn == nil else { throw CodexConnection.error("Finish the active Claude turn before forking.") }
            let session = Session(project: project, title: title + " · fork", provider: .claude, forkSource: thread)
            session.setInferenceSettings(inferenceSettings)
            session.reconcileHistory(history)
            return session
        }
        guard let client = client, let thread = thread, turn == nil else { throw CodexConnection.error("Finish or interrupt an active turn before forking.") }
        let result = try await client.request("thread/fork", ["threadId": thread])
        guard let newID = (result["thread"] as? [String: Any])?["id"] as? String else { throw CodexConnection.error("The runtime did not return a fork.") }
        let session = Session(project: project, title: title + " · fork", thread: newID)
        session.setInferenceSettings(inferenceSettings)
        session.reconcileHistory(history)
        session.report(.system, "Forked from \(thread). The runtime copied context; the original local feed remains intact."); return session
    }
    func export(_ url: URL) throws {
        flushProtocol(); persistence.sync {}
        try Data(contentsOf: folder.appendingPathComponent("protocol.jsonl")).write(to: url, options: .atomic)
    }
    /// Restore the connection, never manufacture a user message or a new turn.
    @discardableResult
    func reconnectAfterRestart() -> Bool {
        guard turnWasInterrupted else { return false }
        guard thread != nil || forkSource != nil else { turnWasInterrupted = false; return false }
        reconnectRequested = true
        resumeConnection()
        return true
    }

    func restoreRuntimeState(_ response: [String: Any]) {
        let metadata = response["thread"] as? [String: Any] ?? [:]
        let turns = (response["initialTurnsPage"] as? [String: Any])?["data"] as? [[String: Any]]
            ?? metadata["turns"] as? [[String: Any]] ?? []
        let isActive = (metadata["status"] as? [String: Any])?["type"] as? String == "active"
        turn = isActive ? turns.first(where: { $0["status"] as? String == "inProgress" })?["id"] as? String : nil
        streamed.removeAll()
        // Deltas after reconnection append to the hydrated prefix exactly once.
        if turn != nil {
            for record in history {
                if let id = record.itemID, let kind = StreamKind(rawValue: record.kind), [.prose, .reasoning, .output].contains(kind) {
                    streamed[id, default: ""] += record.text
                }
            }
        }
    }

    func stop() {
        intentionalStop = true; connectionGeneration = UUID()
        turnWasInterrupted = turnWasInterrupted || turn != nil
        stopMessageQueue(); historyLoad?.cancel(); save(); flushProtocol(); persistence.sync {}
        client?.stop(terminateRuntime: !turnWasInterrupted)
        claude?.stop(); ready = false; turn = nil
    }
    func disconnectForAccessChange(to mode: AccessMode) {
        connectionGeneration = UUID(); turnWasInterrupted = false
        reconnectRequested = false; reconnectTask?.cancel(); reconnectTask = nil
        let runtime = client; client = nil; ready = false; turn = nil
        runtime?.stop(terminateRuntime: true); claude?.stop(); claude = nil; resolveAllRequests()
        settleRunningCommands(as: .interrupted)
        report(.system, "Access changed to \(mode.label). The \(provider.label) runtime was stopped. Existing file changes and independent background processes are not undone.")
        onStatus?(mode.label + " · disconnected")
    }

    func receive(_ original: [String: Any]) {
        let event = Self.redact(original) as? [String: Any] ?? [:]; protocolEvents.append(event)
        if let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) {
            pendingProtocol.append(data); pendingProtocol.append(10)
            if !protocolFlushScheduled {
                protocolFlushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flushProtocol() }
            }
        }
        guard event["_direction"] as? String != "outgoing" else { return }
        let method = event["method"] as? String ?? "", p = event["params"] as? [String: Any] ?? [:]
        if let id = event["id"], !method.isEmpty { requests.insert(String(describing: id)); onStatus?("Input required"); onRequest?(id, method, p); return }
        switch method {
        case "item/reasoning/summaryTextDelta": delta(.reasoning, p)
        case "item/agentMessage/delta": delta(.prose, p)
        case "item/commandExecution/outputDelta": delta(.output, p)
        case "item/started":
            if let item = p["item"] as? [String: Any] {
                if item["type"] as? String == "commandExecution" { report(.command, (item["cwd"] as? String ?? "") + "\n$ " + (item["command"] as? String ?? "Command unavailable"), language: "bash", item: item["id"] as? String, command: CommandActivity(state: .running, startedAt: Date())); onStatus?("Running command") }
                else if ["mcpToolCall", "dynamicToolCall", "webSearch"].contains(item["type"] as? String ?? "") { report(.tool, Self.pretty(item)) }
            }
        case "item/completed":
            guard let item = p["item"] as? [String: Any] else { return }
            let id = item["id"] as? String ?? "", type = item["type"] as? String ?? ""
            if type == "agentMessage", let text = item["text"] as? String {
                finish(.prose, text: text, item: id)
                if item["phase"] as? String == "final_answer" || item["phase"] == nil {
                    finalResponse = StreamRecord(kind: StreamKind.prose.rawValue, text: text, itemID: id, isFinalResponse: true)
                }
            }
            if type == "reasoning", let summary = item["summary"] as? [String] { finish(.reasoning, text: summary.joined(separator: "\n\n"), item: id) }
            if type == "commandExecution" {
                if let output = item["aggregatedOutput"] as? String { finish(.output, text: output, item: id) }
                finishCommand(item, id: id)
                report(.system, "Command status: \(item["status"] ?? "unknown") · exit \(item["exitCode"] ?? "unavailable") · duration \(item["durationMs"] ?? "unavailable") ms")
            }
            if type == "fileChange" { for change in item["changes"] as? [[String: Any]] ?? [] { report(.change, (change["path"] as? String ?? "") + "\n" + (change["diff"] as? String ?? Self.pretty(change)), language: "diff") } }
            if type == "contextCompaction" { report(.compaction, "The runtime reported context compaction. The condensed context and omitted material were not supplied in this event.") }
            if ["mcpToolCall", "dynamicToolCall", "webSearch"].contains(type) { report(.tool, Self.pretty(item)) }
        case "turn/diff/updated": report(.change, p["diff"] as? String ?? Self.pretty(p), language: "diff")
        case "turn/started":
            turnRevision += 1; turnWasInterrupted = false
            finalResponse = nil; streamed.removeAll(); turn = (p["turn"] as? [String: Any])?["id"] as? String; onStatus?("Agent is working")
            // Record the running turn now, so a quit or crash can resume it.
            save()
        case "turn/completed":
            turnRevision += 1; turnWasInterrupted = false
            turn = nil; resolveAllRequests(); streamed.removeAll()
            settleRunningCommands(as: .unknown)
            let turnData = p["turn"] as? [String: Any] ?? [:]
            let status = turnData["status"] as? String ?? "unknown"
            onStatus?(status == "completed" ? "Ready" : "Turn \(status)")
            if let error = turnData["error"] as? [String: Any] { report(.error, error["message"] as? String ?? Self.pretty(error)) }
            if status == "completed" {
                if let items = turnData["items"] as? [[String: Any]],
                   let final = items.last(where: { $0["type"] as? String == "agentMessage" && $0["phase"] as? String == "final_answer" }),
                   let text = final["text"] as? String {
                    finalResponse = StreamRecord(kind: StreamKind.prose.rawValue, text: text, itemID: final["id"] as? String, isFinalResponse: true)
                }
                if let finalResponse, !finalResponse.text.isEmpty {
                    persistMutation(.init(final: finalResponse))
                    feed.finalizeResponse(finalResponse)
                    panes.forEach { $0.value?.finalizeResponse(finalResponse) }
                }
            } else { report(.system, "Turn \(status).") }
            finalResponse = nil; save(); flushProtocol()
            resumeMessageQueue()
        case "account/login/completed": report(.system, Self.pretty(p)); onStatus?((p["success"] as? Bool) == true ? "ChatGPT connected" : "Sign-in failed")
        case "serverRequest/resolved": if let id = p["requestId"] { resolveRequest(id) }
        case "runtime/stderr": report(.system, p["text"] as? String ?? "")
        case "warning":
            let message = p["message"] as? String ?? Self.pretty(p)
            if message.hasPrefix("Configured service tier "), message.contains("will be omitted from requests") {
                serviceTierWarning = "Codex could not apply your requested speed. Retry after availability refreshes, or choose another speed.\n\n" + message
                report(.error, serviceTierWarning!)
            } else { report(.system, message) }
        case "error": report(.error, Self.pretty(p))
        case "account/updated": onStatus?(p["authMode"] as? String == "chatgpt" ? "ChatGPT connected" : "Sign in to ChatGPT")
        case "remoteControl/status/changed", "thread/tokenUsage/updated", "account/rateLimits/updated", "thread/status/changed", "thread/started", "model/rerouted", "item/reasoning/summaryPartAdded": break
        default:
            // Legacy compatibility events duplicate the typed app-server stream.
            if !method.isEmpty && !method.hasPrefix("codex/event/") { report(.system, method + "\n" + Self.pretty(p)) }
        }
    }
    private nonisolated static func completedItemEvents(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let marker = Data("item/completed".utf8)
        return data.split(separator: 10).compactMap { line in
            guard line.range(of: marker) != nil else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }
    /// The full protocol log, read from disk on demand rather than kept for every chat.
    func protocolSnapshot() -> [[String: Any]] {
        flushProtocol()
        let url = folder.appendingPathComponent("protocol.jsonl")
        guard let data = persistence.sync(execute: { try? Data(contentsOf: url) }) else { return protocolEvents }
        return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }
    private func restoreFinalResponses(_ events: [[String: Any]]) {
        var finals: [String: String] = [:]
        for event in events where event["method"] as? String == "item/completed" {
            guard let params = event["params"] as? [String: Any], let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage", item["phase"] as? String == "final_answer",
                  let id = item["id"] as? String, let text = item["text"] as? String else { continue }
            finals[id] = text
        }
        guard !finals.isEmpty else { return }
        var restored = FeedBuffer()
        var seen = Set<String>()
        for var record in history {
            if record.kind == StreamKind.prose.rawValue, let id = record.itemID, let text = finals[id] {
                guard seen.insert(id).inserted else { continue }
                record.text = text; record.isFinalResponse = true
            }
            restored.append(record, merging: false)
        }
        feed = restored
    }

    private func finishCommand(_ item: [String: Any], id: String) {
        let previous = feed.records.last { $0.kind == StreamKind.command.rawValue && $0.itemID == id }
        let exit = item["exitCode"] as? Int
        let duration = item["durationMs"] as? Int
        let status = item["status"] as? String ?? ""
        let state = Self.commandState(status: status, exit: exit)
        let now = Date()
        let activity = CommandActivity(state: state, startedAt: previous?.command?.startedAt ?? previous?.time ?? now.addingTimeInterval(-Double(duration ?? 0) / 1000), finishedAt: now, durationMs: duration, exitCode: exit)
        if previous != nil { updateCommand(activity, id: id) }
        else if let text = item["command"] as? String {
            report(.command, (item["cwd"] as? String ?? "") + "\n$ " + text, language: "bash", item: id, command: activity)
        }
    }
    private func updateCommand(_ activity: CommandActivity, id: String) {
        guard feed.records.contains(where: { $0.kind == StreamKind.command.rawValue && $0.itemID == id }) else { return }
        persistMutation(.init(command: activity, itemID: id))
        feed.updateCommand(activity, itemID: id)
        panes.forEach { $0.value?.updateCommand(activity, itemID: id) }
        scheduleSave()
    }
    private static func commandState(status: String, exit: Int?) -> CommandActivity.State {
        if status == "interrupted" || status == "cancelled" { return .interrupted }
        if status == "failed" || status == "declined" || (exit != nil && exit != 0) { return .failed }
        if status == "succeeded" { return .succeeded }
        return exit == 0 ? .succeeded : .unknown
    }
    private func restoreCommandOutcomes(_ events: [[String: Any]]) {
        // Recover real completion results for commands recorded by older builds.
        var completed: [String: [String: Any]] = [:]
        for event in events where event["method"] as? String == "item/completed" {
            guard let params = event["params"] as? [String: Any], let item = params["item"] as? [String: Any], item["type"] as? String == "commandExecution", let id = item["id"] as? String else { continue }
            completed[id] = item
        }
        for record in history where record.kind == StreamKind.command.rawValue && record.command == nil {
            guard let id = record.itemID, let item = completed[id] else { continue }
            let duration = item["durationMs"] as? Int, exit = item["exitCode"] as? Int
            let activity = CommandActivity(state: Self.commandState(status: item["status"] as? String ?? "", exit: exit), startedAt: record.time, finishedAt: duration.map { record.time.addingTimeInterval(Double($0) / 1000) }, durationMs: duration, exitCode: exit)
            feed.updateCommand(activity, itemID: id)
        }
    }
    private func settleRunningCommands(as state: CommandActivity.State) {
        for record in feed.records where record.command?.state == .running {
            guard let id = record.itemID, var activity = record.command else { continue }
            activity.state = state; activity.finishedAt = Date()
            updateCommand(activity, id: id)
        }
    }
    private func finish(_ kind: StreamKind, text: String, item: String) {
        guard !text.isEmpty, streamed[item] != text else { return }
        let prior = streamed[item] ?? ""
        if !prior.isEmpty && text.hasPrefix(prior) {
            report(kind, String(text.dropFirst(prior.count)), item: item, delta: true)
        } else { report(kind, text, item: item) }
        streamed[item] = text
    }
    private func delta(_ kind: StreamKind, _ p: [String: Any]) {
        let id = p["itemId"] as? String ?? "", value = p["delta"] as? String ?? ""
        streamed[id, default: ""] += value; report(kind, value, item: id, delta: true)
    }
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
    static func redact(_ value: Any, key: String = "") -> Any {
        if ["access_token", "refresh_token", "id_token", "authorization", "api_key", "apikey", "password", "accesstoken", "refreshtoken", "idtoken", "authurl"].contains(key.lowercased()) { return "[REDACTED]" }
        if let dict = value as? [String: Any] { return dict.reduce(into: [String: Any]()) { $0[$1.key] = redact($1.value, key: $1.key) } }
        if let array = value as? [Any] { return array.map { redact($0) } }
        // Every streamed token passes through here; only run the pattern when
        // one of its required literals is present.
        if let string = value as? String {
            guard string.contains("sk-") || string.contains("Bearer ") else { return string }
            return secretPattern.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: "[REDACTED]")
        }
        return value
    }
    private static let secretPattern = try! NSRegularExpression(pattern: "\\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}|Bearer [A-Za-z0-9._~-]+")
}
