import AppKit

extension Session {
    /// Called before clearing the composer. Failure leaves its draft untouched.
    func enqueueChat(_ text: String, attachments: [ChatAttachment], settings: InferenceSettings) throws {
        _ = try Self.messageInput(text, attachments: attachments)
        let message = try outbox.enqueue(text: text, attachments: attachments, settings: settings, expectedTurn: turn)
        setInferenceSettings(settings)
        appendQueuedChat(message)
        onStatus?("Queued Chat")
        resumeMessageQueue()
    }

    func configureMessageQueue(connectivity suppliedConnectivity: ConnectivityMonitor? = nil, connect: @escaping () async throws -> Void) {
        let connectivity = suppliedConnectivity ?? .shared
        queueConnection = connect
        queueConnectivity = connectivity
        if queueNetworkObserver == nil {
            connectivity.start()
            queueNetworkObserver = NotificationCenter.default.addObserver(forName: .connectivityDidChange, object: connectivity, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resumeConnection(); self?.resumeMessageQueue() }
            }
        }
        resumeMessageQueue()
        resumeConnection()
    }

    func stopMessageQueue() {
        reconnectRequested = false; reconnectTask?.cancel(); reconnectTask = nil
        queueRetry?.cancel(); queueRetry = nil
        queueWorker?.cancel()
        queueConnection = nil
        if let observer = queueNetworkObserver { NotificationCenter.default.removeObserver(observer); queueNetworkObserver = nil }
    }

    /// Transport recovery is independent of the message outbox. Rejoining a
    /// thread must never send a synthetic prompt, even after repeated failures.
    func resumeConnection() {
        // Codex's socket is local: reattach even while Internet probes fail.
        guard reconnectRequested, reconnectTask == nil, let connect = queueConnection,
              provider == .codex || queueConnectivity.isOnline else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }
            var delay: UInt64 = 2
            while self.reconnectRequested && !Task.isCancelled {
                guard self.provider == .codex || self.queueConnectivity.isOnline else { return }
                do {
                    try await connect()
                    try Task.checkCancellation()
                    self.reconnectRequested = false
                    self.resumeMessageQueue()
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.onStatus?("Reconnecting…")
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                    catch { return }
                    delay = min(60, delay * 2)
                }
            }
        }
    }

    func resumeMessageQueue(retryBlocked: Bool = false) {
        guard queueWorker == nil, queueConnection != nil, let pending = outbox.pending else { return }
        if pending.state == .blocked {
            // Older builds blocked before submission when an accelerated tier
            // vanished. Let the live capability resolver pick a supported speed.
            let speedWasUnavailable = pending.baselineItems == nil &&
                pending.detail?.contains("availability could not be confirmed for") == true
            guard retryBlocked || speedWasUnavailable else { return }
            do { try outbox.update(pending.id, state: .queued) }
            catch { onStatus?("Queue could not be saved: \(error.localizedDescription)"); return }
        }
        guard queueConnectivity.isOnline else { onStatus?("Offline · Queued Chat"); return }
        queueRetry?.cancel(); queueRetry = nil
        queueWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainMessageQueue()
            self.queueWorker = nil
            self.scheduleQueueRetry()
        }
    }

    private func drainMessageQueue() async {
        while let message = outbox.pending, queueConnection != nil, !Task.isCancelled {
            guard queueConnectivity.isOnline, message.state != .blocked else { return }
            if let turn, message.expectedTurn != turn, message.state == .queued { return }
            do {
                try await queueConnection?()
                try Task.checkCancellation()
                if message.state == .uncertain || message.state == .submitting {
                    // Never infer non-delivery from an absent receipt. A timed-out
                    // request can still complete remotely after a history read.
                    guard provider == .codex, let baseline = message.baselineItems,
                          let receipt = Self.deliveryReceipt(for: message, baseline: Set(baseline), items: try await queuedRemoteItems()) else {
                        onStatus?("Queued Chat · Waiting to confirm delivery")
                        return
                    }
                    removeDuplicateQueuedReceipt(receipt)
                    try outbox.update(message.id, state: .delivered)
                } else {
                    try await send(message.text, attachments: message.attachments, model: message.model,
                                   effort: message.effort, tier: message.tier, queuedID: message.id)
                    try outbox.update(message.id, state: .delivered)
                }
                try commitDeliveredQueueRecords()
                queueRetryDelay = 2
                refreshQueuePresentation()
            } catch {
                if Task.isCancelled { return }
                let current = outbox.messages.first { $0.id == message.id }
                if current?.state == .delivered {
                    onStatus?("Message delivered; local receipt could not be saved: \(error.localizedDescription)")
                    return
                }
                let state: QueuedChat.State = current?.state == .submitting || current?.state == .uncertain
                    ? .uncertain : MessageOutbox.isConnectivityFailure(error) || queueConnectivity.isOffline || error.localizedDescription.contains("already connecting") ? .queued : .blocked
                let detail = state == .uncertain ? "Waiting to confirm delivery before retrying." : state == .queued ? nil : error.localizedDescription
                do { try outbox.update(message.id, state: state, detail: detail) }
                catch { onStatus?("Queue could not be saved: \(error.localizedDescription)"); return }
                refreshQueuePresentation()
                onStatus?(state == .queued ? "Offline · Queued Chat" : state == .uncertain ? "Queued Chat · Waiting to confirm delivery" : "Queued Chat · \(error.localizedDescription)")
                return
            }
        }
        if outbox.pending == nil { onStatus?(turn == nil ? "Ready" : "Agent is working") }
    }

    private func scheduleQueueRetry() {
        guard queueConnection != nil, let pending = outbox.pending, pending.state != .blocked else { return }
        let delay = queueRetryDelay
        queueRetryDelay = min(60, delay * 2)
        queueRetry = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            catch { return }
            self?.queueRetry = nil; self?.resumeMessageQueue()
        }
    }

    func markQueueSubmitting(_ id: UUID, baseline: [String]?) throws {
        try Task.checkCancellation()
        try outbox.update(id, state: .submitting, baselineItems: baseline)
        // Persist the thread ID before any turn request so recovery can inspect it.
        save()
        refreshQueuePresentation()
    }

    func queuedRemoteItems() async throws -> [[String: Any]] {
        guard let client, let thread else { return [] }
        let response = try await client.request("thread/read", ["threadId": thread, "includeTurns": true])
        guard let metadata = response["thread"] as? [String: Any] else {
            throw CodexConnection.error("Delivery confirmation is not available yet.")
        }
        if metadata["historyMode"] as? String == "paginated" {
            var items: [[String: Any]] = [], cursor: String?, seen = Set<String>()
            repeat {
                var params: [String: Any] = ["threadId": thread, "itemsView": "full", "sortDirection": "asc", "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let page = try await client.request("thread/turns/list", params)
                guard let turns = page["data"] as? [[String: Any]] else { throw CodexConnection.error("Delivery history is unavailable.") }
                items += turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }
                cursor = page["nextCursor"] as? String
                if let cursor, !cursor.isEmpty, !seen.insert(cursor).inserted { throw CodexConnection.error("Delivery history repeated a page.") }
            } while cursor != nil && cursor != ""
            return items
        }
        guard let turns = metadata["turns"] as? [[String: Any]] else { throw CodexConnection.error("Delivery history is unavailable.") }
        return turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }
    }

    static func deliveryReceipt(for message: QueuedChat, baseline: Set<String>, items: [[String: Any]]) -> String? {
        for item in items {
            guard item["type"] as? String == "userMessage", let id = item["id"] as? String,
                  !baseline.contains(id), let content = item["content"] as? [[String: Any]] else { continue }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let paths = content.filter { ["localImage", "local_image"].contains($0["type"] as? String ?? "") }.compactMap { $0["path"] as? String }
            if text == message.text, paths == message.attachments.map(\.path),
               content.count == (message.text.isEmpty ? 0 : 1) + message.attachments.count { return id }
        }
        return nil
    }
}
