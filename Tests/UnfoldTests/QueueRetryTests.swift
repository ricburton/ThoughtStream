import AppKit
import XCTest
@testable import ThoughtStream

/// Queued chats are pushed again and again, quickly, until they go through.
final class QueueRetryTests: XCTestCase {
    func testRetriesStayQuickHoweverLongTheOutage() {
        XCTAssertEqual((0..<6).map { QueueRetryPolicy.delay(afterAttempt: $0) }, [1, 2, 3, 5, 8, 10])
        XCTAssertEqual(QueueRetryPolicy.delay(afterAttempt: 29), 10)
        XCTAssertEqual(QueueRetryPolicy.delay(afterAttempt: 5_000), 20, "Never backs off past twenty seconds")
        XCTAssertEqual(QueueRetryPolicy.delay(afterAttempt: -3), 1)
        let firstMinute = (0..<9).reduce(0.0) { $0 + QueueRetryPolicy.delay(afterAttempt: $1) }
        XCTAssertLessThan(firstMinute, 60, "Nine pushes fit in the first minute")
    }

    @MainActor
    func testDroppedLinksAndBusyServicesRetryButAccountProblemsDoNot() {
        for text in ["stream disconnected before completion: error sending request for url", "API Error: Connection error.",
                     "fetch failed", "read ECONNRESET", "Overloaded", "exceeded retry limit, last status: 503 Service Unavailable",
                     "The network connection was lost.", "Request timed out", "429 Too Many Requests", "Could not resolve host: DNS failure"] {
            XCTAssertTrue(MessageOutbox.isTransientFailure(message: text), text)
        }
        for text in ["You've hit your usage limit. Try again at 3:15 PM.", "5-hour limit reached ∙ resets 3pm", "Invalid API key",
                     "Sign in to Codex, then retry this queued message.", "The model `gpt-9` does not exist or you do not have access to it.",
                     "Fixture connection rejected", "Model not found", "Insufficient credit balance; billing required"] {
            XCTAssertFalse(MessageOutbox.isTransientFailure(message: text), text)
        }
        XCTAssertTrue(MessageOutbox.isTransientFailure(URLError(.networkConnectionLost)))
        XCTAssertTrue(MessageOutbox.isTransientFailure(CodexConnection.error("Service temporarily unavailable")))
    }

    @MainActor
    private func deliveredChat(in root: URL) throws -> (Session, QueuedChat, ConnectivityMonitor) {
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { true })
        let session = Session(project: root, storageRoot: root)
        // Connected, with nothing left to send: only the turn's outcome is under test.
        session.configureMessageQueue(connectivity: monitor) {}
        let message = try session.outbox.enqueue(text: "Summarize the flight plan", attachments: [], settings: .preferred)
        session.appendQueuedChat(message)
        try session.outbox.recordAttempt(message.id)
        try session.outbox.update(message.id, state: .delivered)
        try session.commitDeliveredQueueRecords()
        XCTAssertNil(session.outbox.pending)
        session.resendCandidate = message
        session.receive(["method": "turn/started", "params": ["turn": ["id": "turn-1"]]])
        return (session, message, monitor)
    }

    private func failure(_ message: String) -> [String: Any] {
        ["method": "turn/completed", "params": ["turn": ["id": "turn-1", "status": "failed", "error": ["message": message]]]]
    }

    @MainActor
    func testTurnThatDiesOnTheConnectionBeforeAnyReplyIsQueuedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, message, monitor) = try deliveredChat(in: root)
        defer { session.stop(); monitor.stop() }
        var statuses: [String] = []
        session.onStatus = { statuses.append($0) }
        session.receive(failure("stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)"))
        let pending = try XCTUnwrap(session.outbox.pending)
        XCTAssertEqual(pending.id, message.id, "The same message goes back, not a copy")
        XCTAssertEqual(pending.state, .queued)
        XCTAssertEqual(pending.text, "Summarize the flight plan")
        XCTAssertNil(pending.expectedTurn)
        XCTAssertEqual(pending.detail, "The connection dropped before a reply. Resending automatically (attempt 2).")
        XCTAssertNil(session.turn)
        XCTAssertNotNil(session.queueRetry, "A resend is already scheduled")
        XCTAssertNil(session.resendCandidate)
        let history = session.history
        XCTAssertEqual(history.filter { $0.kind == StreamKind.user.rawValue }.count, 1, "The bubble is reused, not duplicated")
        XCTAssertEqual(history.first { $0.kind == StreamKind.user.rawValue }?.queuedStatus, "queued")
        XCTAssertEqual(history.filter { $0.kind == StreamKind.error.rawValue }.count, 1)
        XCTAssertTrue(history.contains { $0.kind == StreamKind.system.rawValue && $0.text.contains("keep resending this message until it goes through") })
        XCTAssertFalse(history.contains { $0.text == "Turn failed." })
        XCTAssertTrue(statuses.contains("Connection dropped · resending"))
        // The second drop of the same message stays quiet in the feed.
        try session.outbox.recordAttempt(message.id)
        try session.outbox.update(message.id, state: .delivered)
        try session.commitDeliveredQueueRecords()
        session.resendCandidate = try XCTUnwrap(session.outbox.messages.first { $0.id == message.id } ?? pending)
        session.resendCandidate?.attempts = 2
        session.receive(["method": "turn/started", "params": ["turn": ["id": "turn-1"]]])
        session.receive(failure("stream disconnected before completion"))
        XCTAssertEqual(session.outbox.pending?.detail, "The connection dropped before a reply. Resending automatically (attempt 3).")
        XCTAssertEqual(session.history.filter { $0.kind == StreamKind.error.rawValue }.count, 1)
        XCTAssertEqual(session.history.filter { $0.kind == StreamKind.user.rawValue }.count, 1)
    }

    @MainActor
    func testTurnThatAlreadyDidWorkOrFailedForAnotherReasonIsNotResent() throws {
        for (error, activity) in [("stream disconnected before completion", true), ("You've hit your usage limit. Try again at 3:15 PM.", false)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (session, _, monitor) = try deliveredChat(in: root)
            defer { session.stop(); monitor.stop() }
            // A command already ran: sending the prompt again could repeat its effects.
            if activity { session.receive(["method": "item/agentMessage/delta", "params": ["itemId": "m1", "delta": "Working on it"]]) }
            session.receive(failure(error))
            XCTAssertNil(session.outbox.pending, error)
            XCTAssertTrue(session.history.contains { $0.text == "Turn failed." })
            XCTAssertEqual(session.history.filter { $0.kind == StreamKind.error.rawValue }.count, 1)
            XCTAssertNil(session.resendCandidate)
        }
    }

    @MainActor
    func testWaitingQueueKeepsPokingTheLinkAndTransientFailuresStayQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probes = Counter()
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { await probes.increment(); return false })
        let session = Session(project: root, storageRoot: root)
        defer { session.stop(); monitor.stop() }
        var attempts = 0
        var statuses: [String] = []
        session.onStatus = { statuses.append($0) }
        session.configureMessageQueue(connectivity: monitor) {
            attempts += 1
            throw CodexConnection.error("stream disconnected before completion")
        }
        try session.enqueueChat("Send when anything answers", attachments: [], settings: .preferred)
        XCTAssertEqual(attempts, 0, "Nothing is sent into a dead link")
        XCTAssertNotNil(session.queueRetry, "But the queue keeps a timer running")
        XCTAssertTrue(statuses.contains("Checking connection · Queued Chat"))
        // The link is checked again within seconds, not at a slow idle cadence.
        let checking = Date().addingTimeInterval(10)
        while Date() < checking, await probes.count < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        let early = await probes.count
        XCTAssertGreaterThanOrEqual(early, 2, "A waiting queue keeps the connection checks coming")
        XCTAssertEqual(attempts, 0)
        // The link answers: the push happens at once, fails on a dropped stream, and is retried quickly.
        monitor.recordNetworkActivity()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, attempts < 3 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThanOrEqual(attempts, 3, "Three pushes within six seconds of the link returning")
        XCTAssertEqual(session.outbox.pending?.state, .queued, "A dropped stream never blocks the message")
        XCTAssertTrue(statuses.contains { $0.hasPrefix("Queued Chat · retrying") })
    }

    @MainActor
    func testWaitingMessageCanBeCancelledBackIntoTheComposerOrOfferedToALocalModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); QueuedChatPresentation.localModelName = nil }
        let session = Session(project: root, storageRoot: root)
        defer { session.stop() }
        let column = ChatColumn()
        _ = column.view
        column.display(session)
        let message = try session.outbox.enqueue(text: "Draft the reply", attachments: [], settings: .preferred)
        session.appendQueuedChat(message)
        column.conversation.replace(session.history)
        // Offline with a model on this Mac: the bubble offers both ways out.
        QueuedChatPresentation.localModelName = "qwen3:8b"
        let label = QueuedChatPresentation.label(status: "queued", detail: nil, messageID: message.id.uuidString)
        XCTAssertTrue(label.string.contains("Answer with qwen3:8b on this Mac"))
        XCTAssertTrue(label.string.contains("Cancel"))
        var links: [URL] = []
        label.enumerateAttribute(.link, in: NSRange(location: 0, length: label.length)) { value, _, _ in if let url = value as? URL { links.append(url) } }
        XCTAssertEqual(links.map(\.host), ["local", "cancel"])
        XCTAssertEqual(links.map(\.lastPathComponent), [message.id.uuidString, message.id.uuidString])
        QueuedChatPresentation.localModelName = nil
        XCTAssertFalse(QueuedChatPresentation.label(status: "queued", detail: nil, messageID: message.id.uuidString).string.contains("on this Mac"))
        XCTAssertFalse(QueuedChatPresentation.label(status: "submitting", detail: nil, messageID: message.id.uuidString).string.contains("Cancel"),
                       "A message already on its way cannot be taken back")
        var moved: UUID?
        column.onAnswerLocally = { moved = $0 }
        XCTAssertTrue(column.conversation.textView(column.conversation.transcript, clickedOnLink: links[0], at: 0))
        XCTAssertEqual(moved, message.id)
        // Cancel: the message leaves the queue and the feed and returns to the composer.
        column.prompt.string = "and add the totals"
        XCTAssertTrue(column.conversation.textView(column.conversation.transcript, clickedOnLink: links[1], at: 0))
        XCTAssertNil(session.outbox.pending)
        XCTAssertFalse(session.history.contains { $0.kind == StreamKind.user.rawValue })
        XCTAssertEqual(column.prompt.string, "Draft the reply\n\nand add the totals")
        // A message being submitted is left alone.
        let sending = try session.outbox.enqueue(text: "Already leaving", attachments: [], settings: .preferred)
        try session.outbox.update(sending.id, state: .submitting)
        XCTAssertNil(try session.withdrawQueuedChat(sending.id))
        XCTAssertNotNil(session.outbox.pending)
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}
