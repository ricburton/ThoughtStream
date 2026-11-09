import AppKit
import XCTest
@testable import ThoughtStream

final class QueuedChatTests: XCTestCase {
    @MainActor
    func testOfflineQueuePreservesTextAttachmentsAndRestoresOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: image)
        let attachment = ChatAttachment(id: UUID(), name: "Original image", path: image.path)
        let session = Session(project: root, storageRoot: root)
        let text = "  Keep whitespace\n\nand this draft 🌍  "
        try session.enqueueChat(text, attachments: [attachment], settings: .preferred)
        XCTAssertEqual(session.outbox.pending?.text, text)
        XCTAssertEqual(session.outbox.pending?.attachments, [attachment])
        XCTAssertEqual(session.history.filter { $0.kind == "You" }.count, 2)
        XCTAssertEqual(session.history.first?.queuedStatus, "queued")
        session.stop()
        let restored = Session(project: root, id: session.id, storageRoot: root)
        XCTAssertEqual(restored.history.filter { $0.kind == "You" }.count, 2)
        XCTAssertEqual(restored.outbox.pending?.text, text)
        XCTAssertEqual(restored.outbox.pending?.attachments, [attachment])
        restored.stop()
    }

    @MainActor
    func testInterruptedSubmissionIsUncertainAndDeliveredReceiptIsJournaled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        try session.enqueueChat("Hello", attachments: [], settings: .preferred)
        let message = try XCTUnwrap(session.outbox.pending)
        try session.markQueueSubmitting(message.id, baseline: ["old"])
        session.stop()
        let restored = Session(project: root, id: session.id, storageRoot: root)
        XCTAssertEqual(restored.outbox.pending?.state, .uncertain)
        XCTAssertEqual(restored.outbox.pending?.baselineItems, ["old"])
        try restored.outbox.update(message.id, state: .delivered)
        try restored.commitDeliveredQueueRecords()
        XCTAssertTrue(restored.outbox.messages.isEmpty)
        restored.stop()
        let again = Session(project: root, id: session.id, storageRoot: root)
        XCTAssertEqual(again.history.filter { $0.kind == "You" }.map(\.text), ["Hello"])
        XCTAssertNil(again.history.first?.queuedStatus)
        again.stop()
    }

    @MainActor
    func testUnwritableOrCorruptQueueNeverAcceptsOrOverwritesDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("outbox.json")
        let corrupt = Data("recover me".utf8)
        try corrupt.write(to: url)
        let outbox = MessageOutbox(url: url)
        XCTAssertThrowsError(try outbox.enqueue(text: "draft", attachments: [], settings: .preferred))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let blocked = MessageOutbox(url: URL(fileURLWithPath: "/dev/null/outbox.json"))
        XCTAssertThrowsError(try blocked.enqueue(text: "draft", attachments: [], settings: .preferred))
        XCTAssertTrue(blocked.messages.isEmpty)
    }

    @MainActor
    func testReceiptRequiresNewIdentityAndExactTextAndImages() throws {
        let message = QueuedChat(id: UUID(), text: "Again", attachments: [], model: "m", effort: "high", tier: "default", createdAt: Date())
        func item(_ id: String, _ text: String) -> [String: Any] {
            ["id": id, "type": "userMessage", "content": [["type": "text", "text": text]]]
        }
        XCTAssertNil(Session.deliveryReceipt(for: message, baseline: ["old"], items: [item("old", "Again")]))
        XCTAssertNil(Session.deliveryReceipt(for: message, baseline: [], items: [item("new", "Different")]))
        XCTAssertEqual(Session.deliveryReceipt(for: message, baseline: ["old"], items: [item("new", "Again")]), "new")
        var imageMessage = message
        // Additional image content cannot be mistaken for the same submission.
        let imageItem: [String: Any] = ["id": "new", "type": "userMessage", "content": [["type": "text", "text": "Again"], ["type": "localImage", "path": "/tmp/image.png"]]]
        imageMessage.state = .uncertain
        XCTAssertNil(Session.deliveryReceipt(for: imageMessage, baseline: [], items: [imageItem]))
    }

    @MainActor
    func testInlineBubbleDisappearsWhenSendingAndReturnsIfDeliveryIsUncertain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        let column = ChatColumn(); column.loadViewIfNeeded(); column.display(session)
        try session.enqueueChat("This is the actual text", attachments: [], settings: .preferred)
        _ = column.stream.recordsSnapshot()
        let text = column.conversation.transcript.string
        XCTAssertEqual(text.components(separatedBy: "Queued Chat").count - 1, 1)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Queued Chat")?.lowerBound), try XCTUnwrap(text.range(of: "This is the actual text")?.lowerBound))
        let pending = try XCTUnwrap(session.outbox.pending)
        try session.markQueueSubmitting(pending.id, baseline: [])
        XCTAssertFalse(column.conversation.transcript.string.contains("Queued Chat"))
        XCTAssertTrue(column.conversation.transcript.string.contains("This is the actual text"))
        XCTAssertEqual(session.history.first?.queuedMessageID, pending.id.uuidString)
        try session.outbox.update(pending.id, state: .uncertain)
        session.refreshQueuePresentation()
        XCTAssertTrue(column.conversation.transcript.string.contains("Queued Chat"))
        try session.outbox.update(pending.id, state: .delivered)
        try session.commitDeliveredQueueRecords()
        session.refreshQueuePresentation()
        XCTAssertFalse(column.conversation.transcript.string.contains("Queued Chat"))
        XCTAssertTrue(column.conversation.transcript.string.contains("This is the actual text"))
        session.stop()
    }

    @MainActor
    func testOlderIdenticalHistoryCannotConsumeQueuedTextOrAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("image.png")
        try Data([1]).write(to: image)
        let session = Session(project: root, storageRoot: root)
        try session.enqueueChat("Repeat", attachments: [ChatAttachment(id: UUID(), name: "image", path: image.path)], settings: .preferred)
        let local = session.history
        var remote = local
        for index in remote.indices {
            remote[index].itemID = "older-\(index)"
            remote[index].queuedStatus = nil; remote[index].queuedMessageID = nil
        }
        let merged = HistoryReconciliation.merge(local: local, remote: remote)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.filter { $0.queuedMessageID != nil }.count, 2)
        session.stop()
    }

    @MainActor
    func testRoutingFailureQueuesThenReconnectSubmitsOnlyOnce() async throws {
        try await exerciseRuntime(ambiguous: false)
    }

    @MainActor
    func testLostAcknowledgementChecksReceiptWithoutResubmitting() async throws {
        try await exerciseRuntime(ambiguous: true)
    }

    @MainActor
    func testQueuedMessagesWaitForEarlierTurnBeforeSubmitting() async throws {
        try await exerciseRuntime(ambiguous: false, multiple: true)
    }

    @MainActor
    func testPaginatedReceiptDoesNotResubmit() async throws {
        try await exerciseRuntime(ambiguous: true, paginated: true)
    }

    @MainActor
    private func exerciseRuntime(ambiguous: Bool, multiple: Bool = false, paginated: Bool = false) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Python fixture unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("runtime")
        try Self.runtime.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let flag = root.appendingPathComponent(ambiguous ? "ambiguous" : "offline")
        try Data().write(to: flag)
        if paginated { try Data().write(to: root.appendingPathComponent("paginated")) }
        let imageURL = root.appendingPathComponent("attached.png")
        try Data([1, 2, 3]).write(to: imageURL)
        let attachment = ChatAttachment(id: UUID(), name: "Attached image", path: imageURL.path)
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { true })
        let session = Session(project: root, storageRoot: root)
        defer { session.stop(); monitor.stop() }
        session.configureMessageQueue(connectivity: monitor) {
            try await session.connect(script, persistentRuntime: false)
            let authenticated = try await session.isAuthenticated()
            XCTAssertTrue(authenticated)
        }
        try session.enqueueChat("Persist and send once", attachments: [attachment], settings: .preferred)
        if multiple { try session.enqueueChat("Next queued message", attachments: [], settings: .preferred) }
        if !ambiguous {
            try await waitUntil { (try? String(contentsOf: root.appendingPathComponent("calls")))?.contains("project/list") == true && session.queueWorker == nil }
            XCTAssertEqual(session.outbox.pending?.state, .queued)
            XCTAssertEqual(session.history.filter { $0.kind == "You" }.count, multiple ? 3 : 2)
            try FileManager.default.removeItem(at: flag)
            session.resumeMessageQueue()
        }
        if multiple {
            try await waitUntil { session.outbox.messages.count == 1 && session.turn != nil && session.queueWorker == nil }
            let calls = try String(contentsOf: root.appendingPathComponent("calls"))
            XCTAssertEqual(calls.components(separatedBy: "turn/start\n").count - 1, 1)
            XCTAssertEqual(session.outbox.pending?.text, "Next queued message")
            session.receive(["method": "turn/completed", "params": ["turn": ["id": "turn", "status": "completed"]]])
        }
        try await waitUntil { session.outbox.pending == nil }
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertEqual(calls.components(separatedBy: "turn/start\n").count - 1, multiple ? 2 : 1)
        XCTAssertFalse(calls.contains("turn/steer"))
        XCTAssertEqual(session.history.filter { $0.kind == "You" }.count, multiple ? 3 : 2)
        XCTAssertNil(session.history.first { $0.kind == "You" }?.queuedStatus)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for the mock runtime")
    }

    private static let runtime = #"""
#!/usr/bin/python3
import json, os, sys
root = os.path.dirname(__file__)
items = []
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method', '')
    with open(os.path.join(root, 'calls'), 'a') as log:
        log.write(method + '\n')
    if 'id' not in request:
        continue
    result = {}
    error = None
    if method == 'project/list':
        if os.path.exists(os.path.join(root, 'offline')):
            error = 'workspace routing discovery failed: network is unreachable'
        else:
            result = {'data': [{'id': 'project', 'name': 'Project', 'roots': [{'path': root}]}]}
    elif method == 'model/list':
        result = {'data': []}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt'}}
    elif method == 'thread/start':
        result = {'thread': {'id': 'thread'}}
    elif method == 'thread/read':
        if os.path.exists(os.path.join(root, 'paginated')):
            result = {'thread': {'historyMode': 'paginated'}}
        else:
            result = {'thread': {'historyMode': 'legacy', 'turns': [{'items': items}]}}
    elif method == 'thread/turns/list':
        if 'cursor' not in request.get('params', {}):
            result = {'data': [], 'nextCursor': 'next'}
        else:
            result = {'data': [{'items': items}]}
    elif method == 'turn/start':
        items.append({'id': 'receipt', 'type': 'userMessage', 'content': request['params']['input']})
        if os.path.exists(os.path.join(root, 'ambiguous')):
            error = 'network connection lost after acceptance'
        else:
            result = {'turn': {'id': 'turn'}}
    response = {'id': request['id']}
    response['error' if error else 'result'] = {'message': error} if error else result
    print(json.dumps(response), flush=True)
"""#
}
