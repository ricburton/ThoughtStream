import XCTest
@testable import ThoughtStream

@MainActor
final class ChatThreadSummaryTests: XCTestCase {
    func testTranscriptUsesOriginalGoalAndRecentChatWithoutTools() throws {
        var records = [StreamRecord(kind: "You", text: "Fix the sidebar")]
        records += (0..<20).map { StreamRecord(kind: "Agent", text: "Reply \($0)") }
        records += [StreamRecord(kind: "Command", text: "private command output"),
                    StreamRecord(kind: "Reasoning summary", text: "private reasoning")]
        let input = try XCTUnwrap(ChatThreadSummary.input(records, provider: .codex))
        XCTAssertTrue(input.transcript.contains("Fix the sidebar"))
        XCTAssertTrue(input.transcript.contains("Reply 19"))
        XCTAssertFalse(input.transcript.contains("Reply 0"))
        XCTAssertFalse(input.transcript.contains("private"))
        XCTAssertEqual(ChatThreadSummary.input(records + [StreamRecord(kind: "Session", text: "Ready")], provider: .codex), input)
        XCTAssertNotEqual(ChatThreadSummary.input(records + [StreamRecord(kind: "You", text: "Now fix search")], provider: .codex), input)
        XCTAssertNil(ChatThreadSummary.input([StreamRecord(kind: "Session", text: "Connected")], provider: .codex))
    }

    func testProviderResponsesAreTerseAndRejectErrors() {
        let codex = Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Sidebar chat summaries\"}}\n".utf8)
        XCTAssertEqual(ChatThreadSummary.output(codex, provider: .codex), "Sidebar chat summaries")
        XCTAssertNil(ChatThreadSummary.output(codex + Data("{\"type\":\"turn.failed\"}\n".utf8), provider: .codex))
        XCTAssertEqual(ChatThreadSummary.output(Data("{\"result\":\"Fix sidebar ordering\",\"is_error\":false}".utf8), provider: .claude), "Fix sidebar ordering")
        XCTAssertNil(ChatThreadSummary.output(Data("{\"result\":\"Sign in first\",\"is_error\":true}".utf8), provider: .claude))
        XCTAssertEqual(ChatThreadSummary.clean("  **Sidebar chat summaries.**  "), "Sidebar chat summaries")
        XCTAssertNil(ChatThreadSummary.clean("Here is a summary:\nSidebar chats"))
    }

    func testSummaryPersistsSeparatelyFromOriginalTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, title: "Can you please make this sidebar summarize the chat", storageRoot: root)
        session.report(.user, "Summarize chat threads")
        let coordinator = ChatThreadSummaryCoordinator()
        defer { coordinator.stop(); session.stop() }
        let done = expectation(description: "Summary shown")
        var calls = 0
        coordinator.schedule([session], generate: { _, _ in calls += 1; return "Sidebar chat summaries" }, updated: { done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.sidebarTitle, "Sidebar chat summaries")
        XCTAssertEqual(session.title, "Can you please make this sidebar summarize the chat")
        let restored = Session(project: root, id: session.id, title: session.title, storageRoot: root)
        defer { restored.stop() }
        XCTAssertEqual(restored.sidebarTitle, session.sidebarTitle)
        XCTAssertEqual(restored.sidebarSummaryFingerprint, session.sidebarSummaryFingerprint)
        let duplicate = expectation(description: "Cached result reused"); duplicate.isInverted = true
        let second = ChatThreadSummaryCoordinator()
        defer { second.stop() }
        second.schedule([restored], generate: { _, _ in duplicate.fulfill(); return "Wrong" }, updated: {})
        await fulfillment(of: [duplicate], timeout: 1.2)
    }

    func testStaleResultIsDiscardedAndLatestThreadIsSummarized() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(project: root, storageRoot: root)
        session.report(.user, "Fix sidebar")
        let coordinator = ChatThreadSummaryCoordinator()
        defer { coordinator.stop(); session.stop(); try? FileManager.default.removeItem(at: root) }
        let done = expectation(description: "Fresh result")
        var calls = 0
        coordinator.schedule([session], generate: { chat, _ in
            calls += 1
            if calls == 1 { chat.report(.user, "Also improve search"); return "Old sidebar summary" }
            return "Sidebar and search improvements"
        }, updated: { done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(session.sidebarTitle, "Sidebar and search improvements")
    }

    func testFailureKeepsTitleAndDoesNotLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(project: root, title: "Original label", storageRoot: root)
        session.report(.user, "Fix sidebar")
        let coordinator = ChatThreadSummaryCoordinator()
        defer { coordinator.stop(); session.stop(); try? FileManager.default.removeItem(at: root) }
        var calls = 0
        coordinator.schedule([session], generate: { _, _ in calls += 1; throw CancellationError() }, updated: { XCTFail("Failed summary must not update UI") })
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.sidebarTitle, "Original label")
    }

    func testLiveSummaryWithSyntheticTranscript() async throws {
        guard ProcessInfo.processInfo.environment["THOUGHTSTREAM_TEST_LIVE_SUMMARY"] == "1" else { throw XCTSkip("Opt-in signed-in provider smoke test") }
        let input = try XCTUnwrap(ChatThreadSummary.input([
            StreamRecord(kind: "You", text: "Make the left sidebar show a brief AI summary of each chat thread."),
            StreamRecord(kind: "Agent", text: "Added short, cached chat summaries to the sidebar.")
        ], provider: .codex))
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNFOLD_TEST_CODEX_PATH"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path)
        let label = try await ChatThreadSummary.generate(input: input, provider: .codex, model: InferenceSettings.load(provider: .codex).model, executable: executable)
        XCTAssertLessThanOrEqual(label.count, 48)
        XCTAssertFalse(label.isEmpty)
        print("Synthetic sidebar summary: \(label)")
    }
}
