import AppKit
import XCTest
@testable import ThoughtStream

final class MemoryRetentionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    func testClosedHistoryStaysOnDiskThroughMetadataChangesAndStop() throws {
        let root = try directory()
        let original = Session(project: root, storageRoot: root)
        original.report(.user, "Available offline")
        original.report(.tool, String(repeating: "Large tool result. ", count: 60_000))
        original.report(.prose, "Saved answer")
        original.stop()
        let expected = original.history

        let restored = Session(project: root, id: original.id, storageRoot: root, deferHistory: true)
        XCTAssertFalse(restored.isHistoryLoaded)
        XCTAssertEqual(restored.residentHistoryBytes, 0)
        XCTAssertEqual(try XCTUnwrap(restored.lastConversationActivity).timeIntervalSince1970,
                       try XCTUnwrap(original.lastConversationActivity).timeIntervalSince1970, accuracy: 0.001)
        restored.title = "Renamed without loading"
        restored.save()
        restored.stop()
        XCTAssertFalse(restored.isHistoryLoaded)
        let folder = root.appendingPathComponent(original.id.uuidString)
        XCTAssertEqual(ConversationStore(folder: folder).load(), expected)
        XCTAssertEqual(restored.history, expected)
        XCTAssertTrue(restored.isHistoryLoaded)
        restored.stop()
    }

    @MainActor
    func testLegacyChatWithoutRemoteThreadRemainsVisibleWithoutLoading() throws {
        let root = try directory(), id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try ConversationStore(folder: folder).save(metadata: Data("{}".utf8), records: [
            StreamRecord(kind: "You", text: "An offline chat", time: date)
        ])
        let session = Session(project: root, id: id, storageRoot: root, deferHistory: true)
        XCTAssertTrue(session.hasStartedConversation)
        XCTAssertEqual(session.lastConversationActivity, date)
        XCTAssertFalse(session.isHistoryLoaded)
        session.stop()
    }

    @MainActor
    func testFirstMutationAfterEvictionIsAppliedExactlyOnce() throws {
        let root = try directory()
        let session = Session(project: root, storageRoot: root)
        session.report(.prose, "Hello", item: "answer", delta: true)
        XCTAssertTrue(session.releaseHistory())
        session.report(.prose, " world", item: "answer", delta: true)
        XCTAssertEqual(session.history.map(\.text), ["Hello world"])
        session.stop()
        let disk = ConversationStore(folder: root.appendingPathComponent(session.id.uuidString)).load()
        XCTAssertEqual(disk.map(\.text), ["Hello world"])
    }

    @MainActor
    func testEnqueueAfterEvictionDoesNotDuplicateOrLoseOfflineMessage() throws {
        let root = try directory()
        let session = Session(project: root, storageRoot: root)
        session.report(.user, "Earlier question")
        XCTAssertTrue(session.releaseHistory())
        try session.enqueueChat("Offline follow-up", attachments: [],
                                settings: InferenceSettings(model: "test", effort: "low", tier: "default"))
        XCTAssertEqual(session.history.filter { $0.text == "Offline follow-up" }.count, 1)
        XCTAssertTrue(session.history.contains { $0.text == "Earlier question" })
        XCTAssertFalse(session.releaseHistory(), "Queued submissions must stay available")
        session.stop()
        let restored = Session(project: root, id: session.id, storageRoot: root, deferHistory: true)
        XCTAssertTrue(restored.isHistoryLoaded)
        XCTAssertEqual(restored.history.filter { $0.text == "Offline follow-up" }.count, 1)
        restored.stop()
    }

    @MainActor
    func testCacheKeepsRecentChatsButProtectsVisibleAndRunningWork() throws {
        let root = try directory()
        let sessions = (0..<6).map { index in
            let session = Session(project: root, storageRoot: root)
            session.report(.user, "Question \(index)")
            return session
        }
        defer { sessions.forEach { $0.stop() } }
        sessions[0].turn = "running"
        let pane = StreamPane()
        sessions[1].attach(pane)
        for session in sessions.dropFirst(2) { _ = session.history }
        SessionHistoryCache.trim(sessions, maximumIdleChats: 2)
        XCTAssertTrue(sessions[0].isHistoryLoaded)
        XCTAssertTrue(sessions[1].isHistoryLoaded)
        XCTAssertFalse(sessions[2].isHistoryLoaded)
        XCTAssertFalse(sessions[3].isHistoryLoaded)
        XCTAssertTrue(sessions[4].isHistoryLoaded)
        XCTAssertTrue(sessions[5].isHistoryLoaded)
        sessions[0].turn = nil
        sessions[1].detach(pane)
    }

    @MainActor
    func testIdleByteBudgetEvictsLargeChatWithoutDeletingHistory() throws {
        let root = try directory()
        let session = Session(project: root, storageRoot: root)
        let text = String(repeating: "Saved tool output\n", count: 10_000)
        session.report(.tool, text)
        SessionHistoryCache.trim([session], maximumIdleBytes: 1024)
        XCTAssertFalse(session.isHistoryLoaded)
        XCTAssertEqual(session.history.map(\.text), [text])
        session.stop()
    }

    @MainActor
    func testWarmCachePrioritizesThreeDaysAndReturnsOlderWorkToDisk() throws {
        let root = try directory(), id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ConversationStore(folder: folder).save(metadata: Data("{}".utf8), records: [
            StreamRecord(kind: "You", text: "Archived work", time: Date().addingTimeInterval(-7 * 86400))
        ])
        let old = Session(project: root, id: id, storageRoot: root)
        let recent = Session(project: root, storageRoot: root)
        recent.report(.user, "Recent work")
        SessionHistoryCache.trim([old, recent])
        XCTAssertTrue(old.isHistoryLoaded, "An older chat just opened gets a switching grace period")
        SessionHistoryCache.trim([old, recent], now: Date().addingTimeInterval(600))
        XCTAssertFalse(old.isHistoryLoaded)
        XCTAssertTrue(recent.isHistoryLoaded)
        XCTAssertEqual(old.history.map(\.text), ["Archived work"])
        old.stop(); recent.stop()
    }

    @MainActor
    func testFullProtocolRemainsExportableWithoutAnInMemoryEventArray() throws {
        let root = try directory()
        let session = Session(project: root, storageRoot: root)
        let large = String(repeating: "payload", count: 150_000)
        session.receive(["_direction": "outgoing", "method": "large", "params": ["text": large]])
        for index in 0..<500 {
            session.receive(["_direction": "outgoing", "method": "small", "params": ["index": index]])
        }
        let log = session.protocolSnapshot()
        XCTAssertEqual(log.count, 501)
        XCTAssertEqual((log.first?["params"] as? [String: Any])?["text"] as? String, large)
        let export = root.appendingPathComponent("export.jsonl")
        try session.export(export)
        XCTAssertEqual(try Data(contentsOf: export).split(separator: 10).count, 501)
        session.stop()
    }

    func testQueuedCheckpointsCoalesceAndReplayLaterJournalEntries() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        let original = Data("{\"title\":\"original\"}".utf8)
        try store.save(metadata: original, records: [])
        let queue = DispatchQueue(label: "test.checkpoints")
        queue.suspend()
        var records: [StreamRecord] = []
        for index in 0..<12 {
            let record = StreamRecord(kind: "You", text: "Question \(index)")
            records.append(record)
            try store.append(.init(record: record))
            let metadata = Data("{\"title\":\"\(index)\"}".utf8)
            let offset = try store.prepareCheckpoint(metadata: metadata, records: records)
            store.enqueueCheckpoint(metadata: metadata, records: records, journalOffset: offset, on: queue) { error in
                XCTFail("Checkpoint failed: \(error)")
            }
        }
        let late = StreamRecord(kind: "Agent", text: "After the last captured snapshot")
        try store.append(.init(record: late))
        queue.resume()
        queue.sync {}
        let backup = try JSONDecoder().decode(ConversationStore.Snapshot.self,
                                             from: Data(contentsOf: root.appendingPathComponent("history-v1.backup.json")))
        XCTAssertEqual(backup.metadata, original, "Only the latest waiting checkpoint should be encoded")
        XCTAssertEqual(store.load(), records + [late])
    }

    func testCatalogInvalidatesForJournalChangesAndDamagedCheckpoint() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        let first = Data("{\"title\":\"first\"}".utf8)
        let second = Data("{\"title\":\"second\"}".utf8)
        try store.save(metadata: first, records: [])
        XCTAssertEqual(ConversationStore.metadata(in: root), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("history-catalog-v1.json").path))
        try store.append(.init(metadata: second))
        XCTAssertEqual(ConversationStore.metadata(in: root), second)
        try Data("broken".utf8).write(to: root.appendingPathComponent("history-v1.json"))
        XCTAssertEqual(ConversationStore.metadata(in: root), second)
    }

    @MainActor
    func testIdleRuntimeCanBeReopenedButActiveWorkIsNeverSuspended() async throws {
        let root = try directory(), executable = root.appendingPathComponent("runtime.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' in request:
                print(json.dumps({'id': request['id'], 'result': {'data': []}}), flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = Session(project: root, storageRoot: root)
        defer { session.stop() }
        try await session.connect(executable, persistentRuntime: false)
        XCTAssertTrue(session.ready)
        session.suspendIdleRuntime()
        XCTAssertTrue(session.ready, "Recently used connections should stay warm")
        session.turn = "active"
        session.suspendIdleRuntime(now: Date().addingTimeInterval(600))
        XCTAssertTrue(session.ready, "Active turns must survive cache maintenance")
        session.turn = nil
        session.suspendIdleRuntime(now: Date().addingTimeInterval(600))
        XCTAssertFalse(session.ready)
        XCTAssertNil(session.client)
        XCTAssertFalse(session.reconnectRequested)
        try await session.connect(executable, persistentRuntime: false)
        XCTAssertTrue(session.ready)
    }

    func testExternalCheckpointDamageDoesNotReplaceGoodBackup() throws {
        let root = try directory(), store = ConversationStore(folder: root)
        try store.save(metadata: Data("{}".utf8), records: [StreamRecord(kind: "You", text: "Original")])
        try store.save(metadata: Data("{}".utf8), records: [StreamRecord(kind: "You", text: "Second")])
        try Data("damaged".utf8).write(to: root.appendingPathComponent("history-v1.json"))
        try store.save(metadata: Data("{}".utf8), records: [StreamRecord(kind: "You", text: "Third")])
        let backup = try JSONDecoder().decode(ConversationStore.Snapshot.self,
                                             from: Data(contentsOf: root.appendingPathComponent("history-v1.backup.json")))
        XCTAssertEqual(backup.records.map(\.text), ["Original"])
    }

    @MainActor
    func testLargeProtocolLineKeepsOnlyItsIncompleteTail() {
        var buffer = Data()
        let large = Data(repeating: 65, count: 1_000_000)
        XCTAssertEqual(CodexConnection.completeLines(appending: large + Data("\npar".utf8), to: &buffer), [large])
        XCTAssertEqual(buffer, Data("par".utf8))
        XCTAssertEqual(CodexConnection.completeLines(appending: Data("tial\nnext\n".utf8), to: &buffer),
                       [Data("partial".utf8), Data("next".utf8)])
        XCTAssertTrue(buffer.isEmpty)
    }

    @MainActor
    func testSocketReassemblesLargeFragmentsAndFollowingPartialFrame() {
        func frame(_ payload: Data, opcode: UInt8, final: Bool) -> Data {
            var bytes = Data([(final ? 0x80 : 0) | opcode])
            if payload.count < 126 { bytes.append(UInt8(payload.count)) }
            else {
                bytes.append(127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    bytes.append(UInt8((UInt64(payload.count) >> shift) & 255))
                }
            }
            bytes.append(payload)
            return bytes
        }
        let socket = LocalRuntimeSocket()
        var messages: [Data] = []
        socket.onMessage = { messages.append($0) }
        let large = Data(repeating: 65, count: 100_000)
        let first = frame(large, opcode: 1, final: false)
        let last = frame(Data("end".utf8), opcode: 0, final: true)
        let next = frame(Data("next".utf8), opcode: 1, final: true)
        socket.receive(Data(first.prefix(13)))
        XCTAssertTrue(messages.isEmpty)
        socket.receive(Data(first.dropFirst(13)) + last + Data(next.prefix(3)))
        XCTAssertEqual(messages, [large + Data("end".utf8)])
        socket.receive(Data(next.dropFirst(3)))
        XCTAssertEqual(messages, [large + Data("end".utf8), Data("next".utf8)])
        socket.close()
    }
}
