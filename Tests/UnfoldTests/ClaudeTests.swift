import XCTest
@testable import ThoughtStream

final class ClaudeTests: XCTestCase {
    func testProviderSettingsStaySeparate() throws {
        let name = "ClaudeSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let codex = InferenceSettings(model: "gpt-example", effort: "medium", tier: "fast")
        codex.save(to: defaults)
        let claude = InferenceSettings(model: "opus", effort: "high", tier: "default")
        claude.save(to: defaults, provider: .claude)
        XCTAssertEqual(InferenceSettings.load(from: defaults), codex)
        XCTAssertEqual(InferenceSettings.load(from: defaults, provider: .claude), claude)
    }

    @MainActor
    func testStreamFramingAndFinalResponseDoNotDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .claude)
        defer { session.stop() }
        let runtime = ClaudeConnection()
        runtime.onEvent = { session.receive($0) }
        session.receive(["method": "turn/started", "params": ["turn": ["id": "t"]]])
        let events: [[String: Any]] = [
            ["type": "stream_event", "event": ["type": "message_start", "message": ["id": "m"]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello 🌍"]]],
            ["type": "assistant", "message": ["id": "m", "content": [["type": "text", "text": "Hello 🌍"]]]],
            ["type": "result", "result": "Hello 🌍", "is_error": false]
        ]
        // Split every byte, including UTF-8 emoji and JSON boundaries.
        for event in events {
            var bytes = try JSONSerialization.data(withJSONObject: event); bytes.append(10)
            for byte in bytes { runtime.receive(Data([byte])) }
        }
        let prose = session.history.filter { $0.kind == StreamKind.prose.rawValue }
        XCTAssertEqual(prose.map(\.text), ["Hello 🌍"])
        XCTAssertEqual(prose.first?.isFinalResponse, true)
        XCTAssertNil(session.turn)
    }

    @MainActor
    func testToolLifecycleAndApprovalCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .claude)
        defer { session.stop() }
        let runtime = ClaudeConnection(); runtime.onEvent = { session.receive($0) }
        runtime.receive(["type": "assistant", "message": ["id": "m", "content": [["type": "tool_use", "id": "tool", "name": "Bash", "input": ["command": "pwd"]]]]])
        XCTAssertEqual(session.history.first?.command?.state, .running)
        runtime.receive(["type": "control_request", "request_id": "approval", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "pwd"]]])
        XCTAssertTrue(session.isPending("approval"))
        runtime.receive(["type": "control_cancel_request", "request_id": "approval"])
        XCTAssertFalse(session.isPending("approval"))
        runtime.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool", "is_error": true, "content": "Denied"]]]])
        XCTAssertEqual(session.history.first?.command?.state, .failed)
        XCTAssertTrue(session.history.contains { $0.kind == StreamKind.output.rawValue && $0.text == "Denied" })
    }

    @MainActor
    func testPermissionsAndResumeArguments() {
        let settings = InferenceSettings(model: "sonnet", effort: "high", tier: "ultrafast")
        let args = ClaudeConnection.arguments(settings: settings, mode: .workspace, resume: "exact-thread", fork: false)
        XCTAssertTrue(args.contains("manual")); XCTAssertFalse(args.contains("bypassPermissions"))
        XCTAssertTrue(args.contains("exact-thread")); XCTAssertFalse(args.contains("ultrafast"))
    }

    func testClaudeDefaultsToMostCapableModelAndMigratesOldImplicitDefault() {
        XCTAssertEqual(InferenceSettings.claudeModel(saved: nil, migrated: false), "claude-fable-5-2")
        XCTAssertEqual(InferenceSettings.claudeModel(saved: nil, migrated: true), "claude-fable-5-2")
        XCTAssertEqual(InferenceSettings.claudeModel(saved: "sonnet", migrated: false), "claude-fable-5-2")
        XCTAssertEqual(InferenceSettings.claudeModel(saved: "sonnet", migrated: true), "sonnet")
        XCTAssertEqual(InferenceSettings.claudeModel(saved: "haiku", migrated: false), "haiku")
        XCTAssertEqual(InferenceSettings(model: "opus", effort: "high", tier: "default").displayName, "Opus 5.5")
    }

    func testLocalHistoryChecksExactProjectAndOmitsInternalThinking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("a.b"), other = root.appendingPathComponent("a-b")
        let folder = ClaudeHistory.directory(project, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(folder, ClaudeHistory.directory(other, root: root))
        let id = UUID().uuidString
        let rows: [[String: Any]] = [
            ["type": "user", "uuid": "u", "cwd": project.path, "message": ["content": "Hello Claude"]],
            ["type": "assistant", "uuid": "a", "cwd": project.path, "message": ["content": [["type": "thinking", "thinking": "internal"], ["type": "text", "text": "Hello human"]]]]
        ]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        try bytes.write(to: folder.appendingPathComponent(id + ".jsonl"))
        XCTAssertEqual(ClaudeHistory.conversations(in: project, root: root).map(\.id), [id])
        XCTAssertTrue(ClaudeHistory.conversations(in: other, root: root).isEmpty)
        XCTAssertEqual(try ClaudeHistory.transcript(id, project: project, root: root).map(\.text), ["Hello Claude", "Hello human"])
    }

    @MainActor
    func testProviderAndForkSourcePersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .claude, forkSource: "original")
        session.stop()
        let data = try Data(contentsOf: root.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["provider"] as? String, "claude")
        XCTAssertEqual(saved["forkSource"] as? String, "original")
    }

    @MainActor
    func testLiveClaudeConversationResumeAndToolWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THOUGHTSTREAM_CLAUDE_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in live Claude account test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thoughtstream-claude-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .claude)
        defer { session.stop() }
        // Exercise changing settings before the first prompt, when hook frames
        // may have arrived but no resumable conversation exists yet.
        InferenceSettings(model: "sonnet", effort: "high", tier: "default").save(provider: .claude)
        try await session.connect(ClaudeConnection.executable())
        let authenticated = try await session.isAuthenticated(); XCTAssertTrue(authenticated)
        try await session.send("Remember the token amber-otter-731. Reply exactly: Claude is connected. Do not use tools.", model: "sonnet", effort: "low")
        try await waitForTurn(session)
        XCTAssertTrue(session.history.contains { $0.kind == StreamKind.prose.rawValue && $0.text.contains("Claude is connected") })
        let thread = try XCTUnwrap(session.thread)
        session.stop()
        let resumed = Session(project: root, thread: thread, storageRoot: root, provider: .claude)
        defer { resumed.stop() }
        try await resumed.connect(ClaudeConnection.executable())
        // The callback only approves the exact, read-only command requested by this test.
        resumed.onRequest = { id, _, params in
            let input = params["input"] as? [String: Any]
            let allowed = params["tool_name"] as? String == "Bash" && input?["command"] as? String == "pwd"
            try? resumed.respond(id, ["decision": allowed ? "accept" : "decline"])
        }
        try await resumed.send("Run the exact Bash command pwd once, then reply with the token I asked you to remember. Do not use other tools.", model: "sonnet", effort: "low")
        try await waitForTurn(resumed)
        XCTAssertEqual(resumed.thread, thread)
        XCTAssertTrue(resumed.history.contains { $0.kind == StreamKind.prose.rawValue && $0.text.contains("amber-otter-731") })
        XCTAssertTrue(resumed.history.contains { $0.kind == StreamKind.command.rawValue })
        XCTAssertTrue(resumed.history.contains { $0.kind == StreamKind.output.rawValue && $0.text.contains(root.path) })
        XCTAssertFalse(resumed.history.contains { $0.kind == StreamKind.error.rawValue })
    }

    @MainActor private func waitForTurn(_ session: Session) async throws {
        let deadline = Date().addingTimeInterval(120)
        while session.turn != nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(session.turn, "Claude turn timed out")
        XCTAssertFalse(session.history.contains { $0.kind == StreamKind.error.rawValue }, "\(session.history.map(\.text))")
    }
}
