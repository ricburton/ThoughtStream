import AppKit

/// How long to wait before pushing a queued message again. Short and capped,
/// so a flaky link is tried many times a minute rather than once.
enum QueueRetryPolicy {
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 3, 5, 8]
        if attempt < steps.count { return steps[max(0, attempt)] }
        return attempt < 30 ? 10 : 20
    }
}

extension Session {
    /// Called before clearing the composer. Failure leaves its draft untouched.
    func enqueueChat(_ text: String, attachments: [ChatAttachment], settings: InferenceSettings) throws {
        _ = try Self.messageInput(text, attachments: attachments)
        // Restore the old feed before the new outbox record becomes visible.
        loadLocalHistory()
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
                Task { @MainActor [weak self] in
                    // A change in the link starts the retry cadence over.
                    self?.queueAttempt = 0
                    self?.resumeConnection(); self?.resumeMessageQueue()
                }
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

    /// Codex's socket and local models live on this Mac. Claude needs the Internet to reattach.
    private var canConnectNow: Bool { ![.claude, .gemini].contains(provider) || queueConnectivity.isOnline }
    /// A local model can answer with no Internet at all.
    private var canSendNow: Bool { !provider.needsInternet || queueConnectivity.isOnline }

    /// Transport recovery is independent of the message outbox. Rejoining a
    /// thread must never send a synthetic prompt, even after repeated failures.
    func resumeConnection() {
        // Codex's socket is local: reattach even while Internet probes fail.
        guard reconnectRequested, reconnectTask == nil, let connect = queueConnection, canConnectNow else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }
            var attempt = 0
            while self.reconnectRequested && !Task.isCancelled {
                guard self.canConnectNow else { return }
                do {
                    try await connect()
                    try Task.checkCancellation()
                    self.reconnectRequested = false
                    self.resumeMessageQueue()
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.onStatus?("Reconnecting…")
                    do { try await Task.sleep(nanoseconds: UInt64(QueueRetryPolicy.delay(afterAttempt: attempt) * 1_000_000_000)) }
                    catch { return }
                    attempt += 1
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
            let runtimeWasBusy = pending.baselineItems == nil &&
                MessageOutbox.isRetryableRejection(message: pending.detail ?? "")
            guard retryBlocked || speedWasUnavailable || runtimeWasBusy else { return }
            do { try outbox.update(pending.id, state: .queued) }
            catch { onStatus?("Queue could not be saved: \(error.localizedDescription)"); return }
        }
        guard canSendNow else {
            // Nothing can leave yet. Keep poking the link, so the queue goes
            // the moment anything answers instead of at the next slow check.
            let waiting = queueConnectivity.isOffline ? "Offline · Queued Chat · retrying" : "Checking connection · Queued Chat"
            if waiting != queueWaitStatus { queueWaitStatus = waiting; onStatus?(waiting) }
            queueConnectivity.checkNow()
            scheduleQueueRetry()
            return
        }
        queueWaitStatus = nil
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
            guard canSendNow, message.state != .blocked else { return }
            // A local model cannot be steered mid-turn; the message follows it.
            if [.local, .gemini].contains(provider), turn != nil { return }
            do {
                if await wasQueuedSteerRejected(message) {
                    try Task.checkCancellation()
                    try outbox.requeue(message, detail: "The previous turn rejected this message. Retrying automatically.")
                    reconnectQueueTransport()
                    refreshQueuePresentation()
                    continue
                }
                try await queueConnection?()
                try Task.checkCancellation()
                // Connecting can take a while. A message cancelled or moved to
                // a local model in the meantime must not be sent after all.
                guard outbox.messages.contains(where: { $0.id == message.id && $0.state != .delivered }) else { continue }
                // Reconnection can reveal a different active turn. Recheck
                // before choosing whether to steer or wait for the next turn.
                if message.state == .queued, let turn, message.expectedTurn != turn { return }
                if message.state == .uncertain || message.state == .submitting {
                    // Never infer non-delivery from an absent receipt. A timed-out
                    // request can still complete remotely after a history read.
                    switch try await deliveryEvidence(for: message) {
                    case .delivered(let receipt):
                        if let receipt { removeDuplicateQueuedReceipt(receipt) }
                        try outbox.update(message.id, state: .delivered)
                    case .notDelivered:
                        // Proven absent: it is safe to send again.
                        try outbox.update(message.id, state: .queued)
                        refreshQueuePresentation()
                        continue
                    case .unknown:
                        onStatus?("Queued Chat · Waiting to confirm delivery")
                        return
                    }
                } else {
                    // Only a message that opens a turn can be resent if that
                    // turn dies on the connection before producing anything.
                    let startsTurn = turn == nil
                    if startsTurn { resendCandidate = message; turnHadActivity = false }
                    try? outbox.recordAttempt(message.id)
                    do {
                        try await send(message.text, attachments: message.attachments, model: message.model,
                                       effort: message.effort, tier: message.tier, queuedID: message.id)
                    } catch {
                        if startsTurn { resendCandidate = nil }
                        throw error
                    }
                    // A failed-turn notification can requeue this input before
                    // the request acknowledgement arrives. Keep that retry.
                    if outbox.messages.first(where: { $0.id == message.id })?.state == .queued { return }
                    try outbox.update(message.id, state: .delivered)
                }
                try commitDeliveredQueueRecords()
                queueAttempt = 0
                refreshQueuePresentation()
            } catch {
                if Task.isCancelled { return }
                let current = outbox.messages.first { $0.id == message.id }
                if current?.state == .delivered {
                    onStatus?("Message delivered; local receipt could not be saved: \(error.localizedDescription)")
                    return
                }
                if provider == .codex, MessageOutbox.isRetryableRejection(error) {
                    let rejectedMethod = (error as NSError).userInfo["CodexRequestMethod"] as? String ?? ""
                    let rejectedSubmission = current?.state == .submitting && ["turn/start", "turn/steer"].contains(rejectedMethod)
                    // A rejected reconnect or receipt lookup says nothing about
                    // an earlier send. Keep its delivery uncertainty intact.
                    guard current?.state == .queued || rejectedSubmission else {
                        reconnectQueueTransport()
                        onStatus?("Queued Chat · Waiting to confirm delivery")
                        return
                    }
                    // Positive rejection is safe to retry. Do not turn it into
                    // an uncertain send that blocks every message behind it.
                    do {
                        if let current { try outbox.requeue(current, detail: "The runtime is reconnecting. Retrying automatically.") }
                    } catch {
                        onStatus?("Queue could not be saved: \(error.localizedDescription)")
                        return
                    }
                    resendCandidate = nil
                    reconnectQueueTransport()
                    refreshQueuePresentation()
                    onStatus?("Queued Chat · reconnecting")
                    return
                }
                let transient = MessageOutbox.isTransientFailure(error) || (provider.needsInternet && queueConnectivity.isOffline)
                    || error.localizedDescription.contains("already connecting")
                let state: QueuedChat.State = current?.state == .submitting || current?.state == .uncertain
                    ? .uncertain : transient ? .queued : .blocked
                let attempts = current?.attempts ?? 0
                let detail = state == .uncertain ? "Waiting to confirm delivery before retrying."
                    : state == .queued ? (attempts > 1 ? "Attempt \(attempts) didn’t go through. Retrying automatically." : nil)
                    : error.localizedDescription
                do { try outbox.update(message.id, state: state, detail: detail) }
                catch { onStatus?("Queue could not be saved: \(error.localizedDescription)"); return }
                refreshQueuePresentation()
                onStatus?(state == .queued ? "Queued Chat · retrying" + (attempts > 1 ? " (attempt \(attempts + 1))" : "")
                          : state == .uncertain ? "Queued Chat · Waiting to confirm delivery" : "Queued Chat · \(error.localizedDescription)")
                // The failure may be the first sign that the link went away.
                if state == .queued, provider.needsInternet { queueConnectivity.checkNow() }
                return
            }
        }
        if outbox.pending == nil { onStatus?(turn == nil ? "Ready" : "Agent is working") }
    }

    private enum DeliveryEvidence { case delivered(receipt: String?), notDelivered, unknown }

    private func reconnectQueueTransport() {
        ready = false
        let previous = client; client = nil; previous?.stop()
    }

    /// Whether an interrupted send reached the provider. Only positive proof
    /// either way changes the message; otherwise it keeps waiting.
    private func deliveryEvidence(for message: QueuedChat) async throws -> DeliveryEvidence {
        switch provider {
        case .codex:
            guard let baseline = message.baselineItems,
                  let receipt = Self.deliveryReceipt(for: message, baseline: Set(baseline), items: try await queuedRemoteItems()) else { return .unknown }
            return .delivered(receipt: receipt)
        case .claude:
            // Claude Code writes every accepted prompt to its local transcript.
            guard let thread else { return .notDelivered }
            guard !message.text.isEmpty else { return .unknown }
            let project = project
            let records = try await Task.detached { try ClaudeHistory.transcript(thread, project: project) }.value
            let received = records.contains {
                $0.kind == StreamKind.user.rawValue && $0.text == message.text && $0.time >= message.createdAt.addingTimeInterval(-2)
            }
            return received ? .delivered(receipt: nil) : .notDelivered
        case .local:
            // The request lived in this process; an interrupted one never finished.
            return .notDelivered
        case .gemini:
            // Missing CLI output is not proof a cloud request was rejected.
            return .unknown
        }
    }

    /// Retries stay quick: one, two, three, five, eight seconds, then every ten.
    func scheduleQueueRetry(afterAttempt attempt: Int? = nil) {
        guard queueConnection != nil, let pending = outbox.pending, pending.state != .blocked else { return }
        let delay = QueueRetryPolicy.delay(afterAttempt: attempt ?? queueAttempt)
        queueAttempt += 1
        queueRetry?.cancel()
        queueRetry = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.queueRetry = nil; self?.resumeMessageQueue()
        }
    }

    /// A turn that failed on the connection before the model produced anything
    /// did not go through. Put its message back so it is pushed again, and
    /// again, until it does. Returns nil when the turn is not retried, else
    /// whether this is the first retry of that message.
    func retryDroppedTurn(status: String, error: String?) -> Bool? {
        defer { resendCandidate = nil }
        guard provider != .gemini else { return nil }
        guard let candidate = resendCandidate, status == "failed", !turnHadActivity, let error,
              MessageOutbox.isTransientFailure(message: error) || (provider.needsInternet && queueConnectivity.isOffline) else { return nil }
        let attempts = max(1, outbox.messages.first { $0.id == candidate.id }?.attempts ?? candidate.attempts ?? 1)
        var retry = candidate
        retry.attempts = attempts
        do { try outbox.requeue(retry, detail: "The connection dropped before a reply. Resending automatically (attempt \(attempts + 1)).") }
        catch { return nil }
        restoreQueuedRecords()
        refreshQueuePresentation()
        if provider.needsInternet { queueConnectivity.checkNow() }
        scheduleQueueRetry(afterAttempt: attempts)
        return attempts <= 1
    }

    /// Take a message that has not been sent out of the queue and the feed.
    /// Returns it so its text can go back to the composer or to another chat.
    @discardableResult
    func withdrawQueuedChat(_ id: UUID) throws -> QueuedChat? {
        guard let message = outbox.messages.first(where: { $0.id == id }),
              message.state == .queued || message.state == .blocked else { return nil }
        try outbox.remove(id)
        if resendCandidate?.id == id { resendCandidate = nil }
        removeQueuedRecords(message)
        if outbox.pending == nil {
            queueRetry?.cancel(); queueRetry = nil
            onStatus?(turn == nil ? "Ready" : "Agent is working")
        }
        return message
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
