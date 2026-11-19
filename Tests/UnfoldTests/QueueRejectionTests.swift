import XCTest
@testable import ThoughtStream

@MainActor
final class QueueRejectionTests: XCTestCase {
    func testChildAgentLifecycleCannotReplaceOrCompleteTheChatTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "parent", storageRoot: root)
        defer { session.stop() }
        func event(_ method: String, thread: String, turn: String) -> [String: Any] {
            ["method": method, "params": ["threadId": thread, "turn": ["id": turn, "status": "completed"]]]
        }
        session.receive(event("turn/started", thread: "parent", turn: "parent-turn"))
        session.receive(event("turn/started", thread: "child", turn: "child-turn"))
        XCTAssertEqual(session.turn, "parent-turn")
        try session.enqueueChat("Follow up", attachments: [], settings: .preferred)
        XCTAssertEqual(session.outbox.pending?.expectedTurn, "parent-turn")
        session.receive(event("turn/completed", thread: "child", turn: "child-turn"))
        XCTAssertEqual(session.turn, "parent-turn", "Child completion must not drain the parent's waiting queue")
        session.receive(event("turn/completed", thread: "parent", turn: "parent-turn"))
        XCTAssertNil(session.turn)
    }

    func testStaleTurnRejectionReconnectsAndSendsOnce() async throws {
        try await exercise(mode: "stale")
    }

    func testSavedUncertainSteerRecoversFromItsRecordedRejection() async throws {
        try await exercise(mode: "saved-stale")
    }

    func testDrainingServerRecoversPreviouslyBlockedQueue() async throws {
        try await exercise(mode: "Server is draining; retry after reconnecting")
    }

    func testWriterConflictRecoversPreviouslyBlockedQueue() async throws {
        try await exercise(mode: "thread thread already has an active writer")
    }

    func testCompletionBeforeAcknowledgementDoesNotStrandNextMessage() async throws {
        try await exercise(mode: "early-completion")
    }

    func testRejectedReceiptLookupDoesNotResendAnUncertainMessage() async throws {
        try await exercise(mode: "uncertain-receipt")
    }

    func testFailureBeforeAcknowledgementKeepsItsRetryQueued() async throws {
        try await exercise(mode: "early-failure")
    }

    func testTransportErrorIsNotProofOfRejection() {
        let text = "Server is draining; retry after reconnecting"
        XCTAssertTrue(MessageOutbox.isTransientFailure(message: text))
        XCTAssertFalse(MessageOutbox.isRetryableRejection(CodexConnection.error(text)))
        XCTAssertTrue(MessageOutbox.isRetryableRejection(NSError(domain: "ThoughtStream.CodexResponse", code: -1,
                                                                 userInfo: [NSLocalizedDescriptionKey: text])))
        XCTAssertFalse(MessageOutbox.isRetryableRejection(message: "network connection lost after acceptance"))
    }

    func testJournalRecoveryRequiresTheLatestMatchingRejectedSubmission() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let request: [String: Any] = ["_direction": "outgoing", "method": "turn/steer", "id": 52,
                                      "params": ["threadId": "thread", "expectedTurnId": "stale",
                                                 "input": [["type": "text", "text": "First"]]]]
        let rejection: [String: Any] = ["_direction": "incoming", "id": 52,
                                        "error": ["message": "expected active turn id `stale` but found `actual`"]]
        let activity: [String: Any] = ["_direction": "incoming", "method": "item/agentMessage/delta",
                                       "emittedAtMs": 1_001_000, "params": ["delta": String(repeating: "x", count: 70_000)]]
        func write(_ events: [[String: Any]]) throws {
            var data = Data()
            for event in events {
                data.append(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)); data.append(10)
            }
            try data.write(to: url)
        }
        func recover(text: String = "First", time: TimeInterval = 1000) -> Bool {
            QueueSubmissionJournal.rejectedSteer(in: url, thread: "thread", expectedTurn: "stale", text: text,
                                                imagePaths: [], createdAt: Date(timeIntervalSince1970: time))
        }
        try write([request, rejection, activity])
        XCTAssertTrue(recover(), "Recovery crosses chunk boundaries and matches the response ID")
        XCTAssertFalse(recover(text: "Different"))
        XCTAssertFalse(recover(time: 1200), "An older identical request is not proof for this message")
        try write([request, activity])
        XCTAssertFalse(recover(), "No acknowledgement is not a rejection")
        var wrongID = rejection; wrongID["id"] = 51
        try write([request, wrongID, activity])
        XCTAssertFalse(recover())
        var ambiguous = rejection; ambiguous["error"] = ["message": "network connection lost after acceptance"]
        try write([request, ambiguous, activity])
        XCTAssertFalse(recover())
        try write([request, rejection, activity, request, activity])
        XCTAssertFalse(recover(), "A later unacknowledged attempt supersedes an earlier rejection")
        var success = rejection; success.removeValue(forKey: "error"); success["result"] = [:] as [String: String]
        try write([request, success, activity])
        XCTAssertFalse(recover(), "Accepted input must never be resent")
    }

    private func exercise(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("runtime")
        try Self.runtime.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { true })
        let session = Session(project: root, storageRoot: root)
        defer { session.stop(); monitor.stop() }
        session.thread = "thread"
        if mode == "stale" || mode == "saved-stale" { session.turn = "stale" }
        let settings = InferenceSettings(model: "gpt-6-astra", effort: "high", tier: "default")
        try session.enqueueChat("First", attachments: [], settings: settings)
        if mode == "saved-stale" {
            let message = try XCTUnwrap(session.outbox.pending)
            try session.outbox.update(message.id, state: .uncertain, baselineItems: [])
            let events: [[String: Any]] = [
                ["_direction": "outgoing", "id": 52, "method": "turn/steer",
                 "params": ["threadId": "thread", "expectedTurnId": "stale", "input": [["type": "text", "text": "First"]]]],
                ["_direction": "incoming", "id": 52, "error": ["message": "expected active turn id `stale` but found `actual`"]],
                ["_direction": "incoming", "emittedAtMs": message.createdAt.timeIntervalSince1970 * 1000 + 1000,
                 "method": "thread/status/changed", "params": [:] as [String: String]]
            ]
            var journal = Data()
            for event in events { journal.append(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)); journal.append(10) }
            try journal.write(to: root.appendingPathComponent(session.id.uuidString).appendingPathComponent("protocol.jsonl"))
        } else if !["stale", "early-completion", "early-failure", "uncertain-receipt"].contains(mode) {
            try session.outbox.update(try XCTUnwrap(session.outbox.pending).id, state: .blocked, detail: mode)
        }
        // The second message belongs to a later turn, not the rejected steer.
        session.turn = nil
        if mode != "uncertain-receipt" { try session.enqueueChat("Second", attachments: [], settings: settings) }
        if mode == "stale" || mode == "saved-stale" { session.turn = "stale" }
        session.configureMessageQueue(connectivity: monitor) {
            try await session.connect(script, persistentRuntime: false)
        }
        let deadline = Date().addingTimeInterval(12)
        if mode == "uncertain-receipt" {
            var calls = ""
            repeat {
                try await Task.sleep(nanoseconds: 20_000_000)
                calls = (try? String(contentsOf: root.appendingPathComponent("calls"))) ?? ""
            } while Date() < deadline && (calls.components(separatedBy: "thread/read\n").count < 5 || session.queueWorker != nil)
            XCTAssertGreaterThanOrEqual(calls.components(separatedBy: "thread/read\n").count - 1, 4, calls)
            XCTAssertEqual(session.outbox.pending?.state, .uncertain)
            XCTAssertEqual(calls.components(separatedBy: "turn/start\n").count - 1, 1, calls)
            return
        }
        while session.outbox.pending != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(session.outbox.pending, "Mode: \(mode)")
        XCTAssertNil(session.turn, "A delayed acknowledgement must not resurrect a completed turn")
        let calls = (try? String(contentsOf: root.appendingPathComponent("calls"))) ?? ""
        XCTAssertEqual(calls.components(separatedBy: "turn/start\n").count - 1, mode == "early-failure" ? 3 : 2, calls)
        XCTAssertEqual(calls.components(separatedBy: "turn/steer\n").count - 1, mode == "stale" ? 1 : 0, calls)
        XCTAssertEqual(session.history.filter { $0.kind == "You" }.map(\.text), ["First", "Second"])
    }

    private static let runtime = #"""
#!/usr/bin/python3
import json, os, sys
root = os.path.dirname(__file__)
mode = open(os.path.join(root, 'mode')).read()
rejected = os.path.join(root, 'rejected')
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method', '')
    with open(os.path.join(root, 'calls'), 'a') as log:
        log.write(method + '\n')
    if 'id' not in request:
        continue
    result, error = {}, None
    if method == 'thread/resume':
        if mode not in ('stale', 'saved-stale', 'early-completion', 'early-failure', 'uncertain-receipt') and not os.path.exists(rejected):
            open(rejected, 'w').close()
            error = mode
        else:
            active = mode == 'stale' and not os.path.exists(rejected)
            result = {'thread': {'id': 'thread', 'status': {'type': 'active' if active else 'idle'},
                       'turns': [{'id': 'stale', 'status': 'inProgress', 'items': []}] if active else []}}
    elif method == 'thread/read':
        if mode == 'uncertain-receipt' and os.path.exists(rejected):
            error = 'Server is draining; retry after reconnecting'
        else:
            result = {'thread': {'id': 'thread', 'historyMode': 'legacy', 'turns': []}}
    elif method == 'model/list':
        result = {'data': []}
    elif method == 'turn/steer':
        open(rejected, 'w').close()
        error = 'expected active turn id `stale` but found `actual`'
    elif method == 'turn/start':
        if mode == 'uncertain-receipt':
            open(rejected, 'w').close()
            error = 'network connection lost after acceptance'
        else:
            turn = {'id': 'finished', 'status': 'completed'}
            if mode == 'early-failure' and not os.path.exists(rejected):
                open(rejected, 'w').close()
                turn.update(status='failed', error={'message': 'stream disconnected before completion'})
            print(json.dumps({'method': 'turn/completed', 'params': {'turn': turn}}), flush=True)
            result = {'turn': {'id': 'finished'}}
    response = {'id': request['id']}
    response['error' if error else 'result'] = {'code': -32600, 'message': error} if error else result
    print(json.dumps(response), flush=True)
"""#
}
