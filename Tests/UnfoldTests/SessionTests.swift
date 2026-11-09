import XCTest
@testable import ThoughtStream

final class SessionTests: XCTestCase {
    @MainActor
    func testStreamCompletionPersistsAndDoesNotDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        session.receive(["method": "turn/started", "params": ["turn": ["id": "turn-1"]]])
        for part in ["Hello ", "🌍"] {
            session.receive(["method": "item/agentMessage/delta", "params": ["itemId": "message-1", "delta": part]])
        }
        session.receive(["method": "item/completed", "params": ["item": ["id": "message-1", "type": "agentMessage", "text": "Hello 🌍"]]])
        session.receive(["method": "turn/completed", "params": ["turn": ["id": "turn-1", "status": "completed"]]])
        XCTAssertNil(session.turn)
        XCTAssertEqual(session.history.filter { $0.kind == StreamKind.prose.rawValue }.map(\.text), ["Hello 🌍"])
        session.stop()
        let restored = Session(project: root, id: session.id, storageRoot: root)
        XCTAssertEqual(restored.history.map(\.text), session.history.map(\.text))
        restored.stop()
    }

    @MainActor
    func testCompletionOnlyAddsTheUnstreamedSuffix() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        session.receive(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "Hello"]])
        session.receive(["method": "item/completed", "params": ["item": ["id": "a", "type": "agentMessage", "text": "Hello world"]]])
        XCTAssertEqual(session.history.map(\.text), ["Hello world"])
        session.stop()
    }

    @MainActor
    func testFailedTurnShowsErrorAndClearsActivity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        session.receive(["method": "turn/started", "params": ["turn": ["id": "t"]]])
        session.receive(["method": "turn/completed", "params": ["turn": ["status": "failed", "error": ["message": "Rate limit reached"]]]])
        XCTAssertNil(session.turn)
        XCTAssertTrue(session.history.contains { $0.kind == StreamKind.error.rawValue && $0.text == "Rate limit reached" })
        session.stop()
    }

    @MainActor
    func testProtocolExportRedactsCredentialsAndKeepsMetadataOutOfFeed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        session.receive(["method": "thread/tokenUsage/updated", "params": ["accessToken": "test-secret", "authUrl": "https://auth.openai.com/example"]])
        let export = root.appendingPathComponent("export.jsonl")
        try session.export(export)
        let text = try String(contentsOf: export)
        XCTAssertTrue(text.contains("[REDACTED]")); XCTAssertFalse(text.contains("test-secret"))
        XCTAssertFalse(text.contains("https://auth.openai.com/example")); XCTAssertTrue(session.history.isEmpty)
        session.stop()
    }

    @MainActor
    func testLiveChatGPTStreamWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["UNFOLD_LIVE_TEST"] == "1" else { throw XCTSkip("Set UNFOLD_LIVE_TEST=1 to use the signed-in Codex account.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root)
        defer { session.stop() }
        let executable = ProcessInfo.processInfo.environment["UNFOLD_TEST_CODEX_PATH"] ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/codex")
        try await session.connect(URL(fileURLWithPath: executable))
        let authenticated = try await session.isAuthenticated()
        XCTAssertTrue(authenticated)
        try await session.send("Reply exactly: Unfold is connected. Do not use tools or access files.", model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
        let deadline = Date().addingTimeInterval(90)
        while session.turn != nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(session.turn, "Turn did not complete")
        let answer = session.history.filter { $0.kind == StreamKind.prose.rawValue }.map(\.text).joined()
        XCTAssertTrue(answer.contains("Unfold is connected"), "Expected a streamed answer; received: \(answer)")
        XCTAssertFalse(session.history.contains { $0.kind == StreamKind.error.rawValue })
        let outgoing = session.protocolEvents.first { $0["method"] as? String == "turn/start" && $0["_direction"] as? String == "outgoing" }
        let sent = outgoing?["params"] as? [String: Any]
        XCTAssertEqual(sent?["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(sent?["effort"] as? String, "high")
        let effectiveTier = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
            .resolvingCodexTier(in: session.codexModels).tier
        XCTAssertEqual(sent?["serviceTier"] as? String, effectiveTier)
        let resolved = session.protocolEvents.filter { $0["method"] as? String == "thread/settings/updated" }.compactMap { ($0["params"] as? [String: Any])?["threadSettings"] as? [String: Any] }.last
        XCTAssertEqual(resolved?["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(resolved?["effort"] as? String, "high")
        if effectiveTier == "default" {
            XCTAssertTrue(resolved?["serviceTier"] == nil || resolved?["serviceTier"] is NSNull || resolved?["serviceTier"] as? String == "default")
        } else {
            XCTAssertEqual(resolved?["serviceTier"] as? String, effectiveTier)
        }
    }
}
