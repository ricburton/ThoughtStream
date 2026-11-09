import XCTest
@testable import ThoughtStream

final class HistoryReliabilityTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testJournalRecoversStreamingCommandAndFinalBeforeCheckpoint() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        try store.save(metadata: Data("{}".utf8), records: [])
        try store.append(.init(record: StreamRecord(kind: "Agent", text: "Hello", itemID: "a"), merging: true))
        try store.append(.init(record: StreamRecord(kind: "Agent", text: " 🌍", itemID: "a"), merging: true))
        try store.append(.init(record: StreamRecord(kind: "Command", text: "$ pwd", itemID: "c", command: CommandActivity(state: .running, startedAt: Date()))))
        try store.append(.init(command: CommandActivity(state: .succeeded, startedAt: Date(), exitCode: 0), itemID: "c"))
        try store.append(.init(final: StreamRecord(kind: "Agent", text: "Hello 🌍", itemID: "a")))
        let recovered = ConversationStore(folder: root).load()
        XCTAssertEqual(recovered.map(\.text), ["$ pwd", "Hello 🌍"])
        XCTAssertEqual(recovered.first?.command?.state, .succeeded)
        XCTAssertEqual(recovered.last?.isFinalResponse, true)
    }

    func testDamagedCheckpointFallsBackAndReplaysOnlyMissingDeltas() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        let a = StreamRecord(kind: "Agent", text: "one", itemID: "a")
        try store.save(metadata: Data("{\"title\":\"old\"}".utf8), records: [])
        try store.append(.init(record: a))
        try store.save(metadata: Data("{\"title\":\"new\"}".utf8), records: [a])
        let b = StreamRecord(kind: "Agent", text: "two", itemID: "b")
        try store.append(.init(record: b))
        XCTAssertEqual(store.load().map(\.text), ["one", "two"])
        try Data("broken checkpoint".utf8).write(to: root.appendingPathComponent("history-v1.json"))
        XCTAssertEqual(store.load().map(\.text), ["one", "two"])
        XCTAssertEqual(ConversationStore.snapshot(in: root)?.metadata, Data("{\"title\":\"old\"}".utf8))
        XCTAssertEqual(ConversationStore.metadata(in: root), Data("{\"title\":\"new\"}".utf8))
    }

    func testTornJournalTailDoesNotHideLaterUpdatesOrDestroyLegacyFeed() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        let legacy = StreamRecord(kind: "You", text: "Existing work")
        let original = try JSONEncoder().encode([legacy])
        try original.write(to: root.appendingPathComponent("feed.json"))
        try Data("{\"record\":".utf8).write(to: root.appendingPathComponent("history-journal.jsonl"))
        try store.append(.init(record: StreamRecord(kind: "Agent", text: "Recovered")))
        XCTAssertEqual(store.load().map(\.text), ["Existing work", "Recovered"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("feed.json")), original)
    }

    func testReconciliationIncludesMissingTurnsAndKeepsLocalOnlyRecords() {
        let local = [StreamRecord(kind: "You", text: "Question"),
                     StreamRecord(kind: "Agent", text: "Hel", itemID: "a"),
                     StreamRecord(kind: "Agent", text: "lo", itemID: "a"),
                     StreamRecord(kind: "Session", text: "Disconnected"),
                     StreamRecord(kind: "You", text: "Unsent work")]
        let remote = [StreamRecord(kind: "You", text: "Question", itemID: "u"),
                      StreamRecord(kind: "Agent", text: "Hello", itemID: "a"),
                      StreamRecord(kind: "Agent", text: "Missed while offline", itemID: "b")]
        let merged = HistoryReconciliation.merge(local: local, remote: remote)
        XCTAssertEqual(merged.filter { $0.kind == "Agent" }.map(\.text), ["Hello", "Missed while offline"])
        XCTAssertEqual(merged.filter { $0.text == "Question" }.count, 1)
        XCTAssertTrue(merged.contains { $0.text == "Unsent work" })
        XCTAssertTrue(merged.contains { $0.text == "Disconnected" })
        XCTAssertEqual(HistoryReconciliation.merge(local: merged, remote: remote).map(\.text), merged.map(\.text))
    }

    func testMessageWithAttachmentMatchesTextWithoutDroppingRepeatedPrompts() {
        let local = [StreamRecord(kind: "You", text: "Inspect this"), StreamRecord(kind: "You", text: "Inspect this")]
        let remote = [StreamRecord(kind: "You", text: "Inspect this", itemID: "u1"),
                      StreamRecord(kind: "You", text: "image payload", itemID: "u1"),
                      StreamRecord(kind: "You", text: "Inspect this", itemID: "u2")]
        let merged = HistoryReconciliation.merge(local: local, remote: remote)
        XCTAssertEqual(merged.filter { $0.text == "Inspect this" }.count, 2)
        XCTAssertEqual(merged.filter { $0.text == "image payload" }.count, 1)
        XCTAssertEqual(HistoryReconciliation.merge(local: merged, remote: remote).map(\.text), merged.map(\.text))
    }

    func testStaleShorterReadCannotTruncateLocalResponse() {
        let local = [StreamRecord(kind: "Agent", text: "Complete answer", itemID: "a")]
        let remote = [StreamRecord(kind: "Agent", text: "Complete", itemID: "a")]
        XCTAssertEqual(HistoryReconciliation.merge(local: local, remote: remote).map(\.text), ["Complete answer"])
        XCTAssertEqual(HistoryReconciliation.merge(local: local, remote: []).map(\.text), ["Complete answer"])
    }

    func testUnreadableLegacyFilesSurviveMigration() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        let broken = Data("truncated original".utf8)
        try broken.write(to: root.appendingPathComponent("feed.json"))
        try broken.write(to: root.appendingPathComponent("session.json"))
        try store.save(metadata: Data("{}".utf8), records: [StreamRecord(kind: "You", text: "New work")])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("feed.json")), broken)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("session.json")), broken)
        XCTAssertEqual(store.load().map(\.text), ["New work"])
    }

    func testClaudeHistoryUsesLiveIDsAndRestoresToolOutcome() throws {
        let root = try directory(), project = root.appendingPathComponent("project")
        let folder = ClaudeHistory.directory(project, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let rows: [[String: Any]] = [
            ["uuid": "a", "cwd": project.path, "type": "assistant", "timestamp": "2026-10-24T10:00:00Z", "message": ["id": "live-message", "content": [["type": "text", "text": "Result"], ["type": "tool_use", "id": "live-tool", "name": "Bash", "input": ["command": "pwd"]]]]],
            ["uuid": "b", "cwd": project.path, "type": "user", "timestamp": "2026-10-24T10:00:01Z", "message": ["content": [["type": "tool_result", "tool_use_id": "live-tool", "content": "output", "is_error": false]]]]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        data.append(Data("{truncated tail".utf8))
        try data.write(to: folder.appendingPathComponent(id + ".jsonl"))
        let records = try ClaudeHistory.transcript(id, project: project, root: root)
        XCTAssertEqual(records.first?.itemID, "live-message")
        XCTAssertGreaterThan(records.first?.time ?? .distantPast, .distantPast)
        XCTAssertEqual(records.first { $0.kind == "Command" }?.itemID, "live-tool")
        XCTAssertEqual(records.first { $0.kind == "Command" }?.command?.state, .succeeded)
        XCTAssertEqual(records.last?.itemID, "live-tool")
    }

    @MainActor
    func testHistoryReaderRestartsAfterFailedRequest() async throws {
        let root = try directory(), executable = root.appendingPathComponent("reader.py")
        let script = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        counter = pathlib.Path(__file__ + '.count')
        launches = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(launches))
        for line in sys.stdin:
            message = json.loads(line)
            if 'id' not in message:
                continue
            reply = {'id': message['id'], 'result': {}}
            if message.get('method') == 'thread/list':
                if launches == 1:
                    reply = {'id': message['id'], 'error': {'message': 'Temporary read failure'}}
                else:
                    reply['result'] = {'data': []}
            print(json.dumps(reply), flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let reader = ProjectHistory(executable: executable)
        defer { reader.stop() }
        do { _ = try await reader.conversations(in: root); XCTFail("Expected first request to fail") } catch { }
        let recovered = try await reader.conversations(in: root)
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: executable.path + ".count"), "2")
    }

    @MainActor
    func testSessionRecoversWithoutStopOrDebounceAndRefreshFailureKeepsCache() async throws {
        let root = try directory()
        let session = Session(project: root, thread: "thread", storageRoot: root)
        session.receive(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "Offline copy"]])
        // Read the store directly before save()/stop() or the debounce fires.
        XCTAssertEqual(ConversationStore(folder: root.appendingPathComponent(session.id.uuidString)).load().map(\.text), ["Offline copy"])
        let unavailable = ProjectHistory { _, _ in throw CodexConnection.error("Offline") }
        do { try await session.loadHistory(using: unavailable, refresh: true); XCTFail("Expected offline failure") } catch { }
        XCTAssertEqual(session.history.map(\.text), ["Offline copy"])
        let reader = ProjectHistory { _, params in
            if params["includeTurns"] as? Bool == false { return ["thread": ["historyMode": "legacy"]] }
            return ["thread": ["turns": [["items": [["id": "a", "type": "agentMessage", "text": "Offline copy synced"], ["id": "b", "type": "agentMessage", "text": "New answer"]]]]]]
        }
        try await session.loadHistory(using: reader, refresh: true)
        XCTAssertEqual(session.history.map(\.text), ["Offline copy synced", "New answer"])
        session.stop()
        let restored = Session(project: root, id: session.id, storageRoot: root)
        XCTAssertEqual(restored.history.map(\.text), ["Offline copy synced", "New answer"])
        restored.stop()
    }
}
