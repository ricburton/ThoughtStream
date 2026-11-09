import XCTest
@testable import ThoughtStream

@MainActor
final class InterruptedTurnTests: XCTestCase {
    func testRunningTurnIsRecordedAndClearedWhenItCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "thread", storageRoot: root)
        let folder = root.appendingPathComponent(session.id.uuidString)
        func inFlight() throws -> Bool? {
            session.stop()
            let data = try XCTUnwrap(ConversationStore.metadata(in: folder))
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["turnInFlight"] as? Bool
        }
        session.receive(["method": "turn/started", "params": ["turn": ["id": "t"]]])
        // Quitting mid-turn must leave the marker for the next launch.
        XCTAssertEqual(try inFlight(), true)
        session.receive(["method": "turn/started", "params": ["turn": ["id": "t2"]]])
        session.receive(["method": "turn/completed", "params": ["turn": ["id": "t2", "status": "completed"]]])
        XCTAssertEqual(try inFlight(), false)
    }

    func testRestartRequestsReconnectionWithoutQueuingAnyMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "thread", storageRoot: root, turnWasInterrupted: true)
        defer { session.stop() }
        XCTAssertTrue(session.reconnectAfterRestart())
        XCTAssertTrue(session.reconnectAfterRestart())
        XCTAssertTrue(session.reconnectRequested)
        XCTAssertTrue(session.outbox.messages.isEmpty)
        XCTAssertTrue(session.history.isEmpty)
    }

    func testChatWithoutThreadIsNotReconnected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, turnWasInterrupted: true)
        defer { session.stop() }
        XCTAssertFalse(session.reconnectAfterRestart())
        XCTAssertNil(session.outbox.pending)
    }

    func testRejoinedActiveTurnAcceptsDeltasWithoutDuplicatingItsPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "thread", storageRoot: root)
        defer { session.stop() }
        session.report(.prose, "Hello ", item: "answer")
        session.restoreRuntimeState(["thread": ["status": ["type": "active"]], "initialTurnsPage": ["data": [["id": "turn", "status": "inProgress"]]]])
        XCTAssertEqual(session.turn, "turn")
        session.receive(["method": "item/agentMessage/delta", "params": ["itemId": "answer", "delta": "world"]])
        session.receive(["method": "item/completed", "params": ["item": ["id": "answer", "type": "agentMessage", "text": "Hello world"]]])
        XCTAssertEqual(session.history.filter { $0.kind == StreamKind.prose.rawValue }.map(\.text), ["Hello world"])
    }

    func testIdleResumeDoesNotRestartCompletedWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "thread", storageRoot: root, turnWasInterrupted: true)
        defer { session.stop() }
        session.restoreRuntimeState(["thread": ["turns": [["id": "old", "status": "completed"]]]])
        XCTAssertNil(session.turn)
        session.restoreRuntimeState(["thread": ["status": ["type": "idle"], "turns": [["id": "stale", "status": "inProgress"]]]])
        XCTAssertNil(session.turn, "A saved start marker is not evidence the runtime is still working")
        XCTAssertTrue(session.outbox.messages.isEmpty)
    }

    func testCodexRestorationReconnectsOfflineWithoutSubmittingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { false })
        let session = Session(project: root, thread: "thread", storageRoot: root, turnWasInterrupted: true)
        defer { session.stop(); monitor.stop() }
        var connections = 0
        session.configureMessageQueue(connectivity: monitor) { connections += 1 }
        XCTAssertTrue(session.reconnectAfterRestart())
        XCTAssertTrue(session.reconnectAfterRestart())
        let deadline = Date().addingTimeInterval(3)
        while session.reconnectRequested && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(connections, 1)
        XCTAssertFalse(session.reconnectRequested)
        monitor.recordNetworkActivity()
        await Task.yield()
        XCTAssertEqual(connections, 1)
        XCTAssertTrue(session.outbox.messages.isEmpty)
        XCTAssertTrue(session.history.isEmpty)
    }

    func testLegacyRestartQueueIsCancelledButUserMessagesSurvive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let old = Session(project: root, id: id, thread: "thread", storageRoot: root)
        let legacy = "ThoughtStream restarted while you were working, which interrupted your previous turn. Pick up exactly where you left off and carry on with the task. Check the current state first rather than assuming earlier commands or edits completed."
        try old.enqueueChat(legacy, attachments: [], settings: .preferred)
        try old.enqueueChat("Keep this real message", attachments: [], settings: .preferred)
        old.stop()
        let restored = Session(project: root, id: id, thread: "thread", storageRoot: root)
        defer { restored.stop() }
        XCTAssertEqual(restored.outbox.messages.map(\.text), ["Keep this real message"])
        XCTAssertFalse(restored.history.contains { $0.text == legacy })
        XCTAssertTrue(restored.history.contains { $0.text == "Keep this real message" })
    }

    func testLegacyRestartPromptsAreRemovedFromAllQueueStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        let outbox = MessageOutbox(url: folder.appendingPathComponent("outbox.json"))
        for state: QueuedChat.State in [.queued, .submitting, .uncertain, .blocked, .delivered] {
            let message = try outbox.enqueue(text: MessageOutbox.legacyRestartPrompt, attachments: [], settings: .preferred)
            try outbox.update(message.id, state: state, baselineItems: ["previous-item"])
        }
        _ = try outbox.enqueue(text: "Keep my actual prompt", attachments: [], settings: .preferred)
        let session = Session(project: root, id: id, thread: "thread", storageRoot: root)
        defer { session.stop() }
        XCTAssertEqual(session.outbox.messages.map(\.text), ["Keep my actual prompt"])
        XCTAssertFalse(session.history.contains(where: MessageOutbox.isLegacyRestartRecord))
    }

    func testDeliveredRestartParagraphDoesNotReturnFromSavedOrProviderHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let original = Session(project: root, id: id, thread: "thread", storageRoot: root)
        original.report(.user, MessageOutbox.legacyRestartPrompt, item: "provider-restart-item")
        original.report(.user, "Keep my actual message", item: "real-user-item")
        original.stop()
        let restored = Session(project: root, id: id, thread: "thread", storageRoot: root)
        defer { restored.stop() }
        XCTAssertFalse(restored.history.contains(where: MessageOutbox.isLegacyRestartRecord))
        restored.importSearchHistory([
            StreamRecord(kind: StreamKind.user.rawValue, text: MessageOutbox.legacyRestartPrompt, itemID: "provider-restart-item"),
            StreamRecord(kind: StreamKind.user.rawValue, text: "Keep my actual message", itemID: "real-user-item")
        ])
        XCTAssertFalse(restored.history.contains(where: MessageOutbox.isLegacyRestartRecord))
        XCTAssertTrue(restored.history.contains { $0.text == "Keep my actual message" })
    }

    func testLegacyProtocolLogDetectsUnfinishedTurn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("protocol.jsonl")
        func write(_ methods: [String]) throws {
            let lines = try methods.map { String(decoding: try JSONSerialization.data(withJSONObject: ["method": $0, "params": [:]], options: .sortedKeys), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        try write(["turn/started", "item/agentMessage/delta"])
        XCTAssertTrue(Session.legacyTurnInFlight(in: folder))
        try write(["turn/started", "turn/completed"])
        XCTAssertFalse(Session.legacyTurnInFlight(in: folder))
        try write(["turn/started"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: log.path)
        XCTAssertFalse(Session.legacyTurnInFlight(in: folder), "Old crashes are not resumed")
    }
}
