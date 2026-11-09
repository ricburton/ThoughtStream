import AppKit
import XCTest
@testable import ThoughtStream

final class LocalHistorySearchTests: XCTestCase {
    private func fixture() throws -> (URL, LocalHistorySearch.Roots) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-" + UUID().uuidString)
        let roots = LocalHistorySearch.Roots(sessions: base.appendingPathComponent("sessions"), codex: base.appendingPathComponent("codex"), claude: base.appendingPathComponent("claude"), database: base.appendingPathComponent("index.sqlite"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, roots)
    }
    private func save(_ roots: LocalHistorySearch.Roots, id: UUID, title: String = "Orange wallet", records: [StreamRecord]) throws {
        let folder = roots.sessions.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "project": "/tmp/PodWallet", "title": title, "provider": "codex"])
        try ConversationStore(folder: folder).save(metadata: meta, records: records)
    }
    func testExactFuzzySnippetsAndIncrementalUpdates() async throws {
        let (base, roots) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), engine = LocalHistorySearch(roots: roots)
        try save(roots, id: id, records: [
            StreamRecord(kind: "You", text: "How should the charging connector work?"),
            StreamRecord(kind: "Agent", text: String(repeating: "Earlier context. ", count: 100) + "Use CAB-15455 for the connector.\nKeep the port clear.")
        ])
        try await engine.refresh()
        let exact = try await engine.search("CAB-15455")
        XCTAssertEqual(exact.first?.record, 1)
        XCTAssertEqual(exact.first?.approximate, false)
        XCTAssertTrue(exact.first?.snippet.contains("CAB-15455") == true)
        XCTAssertLessThan(exact.first?.snippet.count ?? 999, 260)
        let fuzzy = try await engine.search("connetcor")
        XCTAssertTrue(fuzzy.contains { $0.needle == "connector" && $0.approximate })
        let prefix = try await engine.search("charg")
        XCTAssertEqual(prefix.first?.record, 0)
        let title = try await engine.search("orange wallet")
        XCTAssertEqual(title.first?.document.title, "Orange wallet")
        let project = try await engine.search("PodWallet")
        XCTAssertFalse(project.isEmpty)
        let phrase = try await engine.search("port clear")
        XCTAssertEqual(phrase.first?.approximate, false)
        try save(roots, id: id, records: [StreamRecord(kind: "Agent", text: "Replacement magnet detail")])
        try await engine.refresh()
        let removed = try await engine.search("CAB-15455")
        XCTAssertTrue(removed.isEmpty)
        let replacement = try await engine.search("magnet")
        XCTAssertEqual(replacement.count, 1)
        let reopened = LocalHistorySearch(roots: roots)
        let persisted = try await reopened.search("magnet")
        XCTAssertEqual(persisted.count, 1)
    }
    func testArchivedCodexAndClaudeHistoryLoadLocally() async throws {
        let (base, roots) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let archive = roots.codex.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let codexID = UUID().uuidString
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": codexID, "cwd": "/tmp/Archive"]],
            ["type": "response_item", "timestamp": "2026-10-21T12:00:00Z", "payload": ["type": "message", "role": "system", "content": [["text": "excluded private setup"]]]],
            ["type": "response_item", "timestamp": "2026-10-21T12:00:00Z", "payload": ["type": "message", "role": "assistant", "id": "answer", "phase": "final_answer", "content": [["text": "Archived ruby response"]]]]
        ]
        func jsonl(_ rows: [[String: Any]], to url: URL) throws {
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
            try data.write(to: url)
        }
        try jsonl(rows, to: archive.appendingPathComponent("rollout.jsonl"))
        try jsonl([["id": codexID, "thread_name": "Named archived conversation", "updated_at": "2026-10-21T12:00:00Z"]], to: roots.codex.appendingPathComponent("session_index.jsonl"))
        try FileManager.default.createDirectory(at: roots.claude, withIntermediateDirectories: true)
        try jsonl([["type": "user", "uuid": "claude-u", "cwd": "/tmp/Claude", "message": ["content": "Sapphire question"]]], to: roots.claude.appendingPathComponent(UUID().uuidString + ".jsonl"))
        let engine = LocalHistorySearch(roots: roots)
        try await engine.refresh()
        let codex = try await engine.search("ruby")
        XCTAssertEqual(codex.first?.document.title, "Named archived conversation")
        let loaded = await engine.load(try XCTUnwrap(codex.first))
        XCTAssertEqual(loaded?.records.first?.itemID, "answer")
        let claude = try await engine.search("Sapphire")
        XCTAssertEqual(claude.first?.document.provider, "claude")
        let excluded = try await engine.search("excluded private setup")
        XCTAssertTrue(excluded.isEmpty)
    }
    func testTypoDistanceIsBounded() {
        XCTAssertTrue(LocalHistorySearch.oneEditApart("connector", "connetcor"))
        XCTAssertTrue(LocalHistorySearch.oneEditApart("connector", "conector"))
        XCTAssertTrue(LocalHistorySearch.oneEditApart("connector", "connecctor"))
        XCTAssertFalse(LocalHistorySearch.oneEditApart("connector", "container"))
    }
    func testWarmSearchAcrossLargeHistoryAndJournalRefresh() async throws {
        let (base, roots) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), engine = LocalHistorySearch(roots: roots)
        let records = (0..<2500).map { index in
            StreamRecord(kind: "Agent", text: "Conversation entry \(index). " + String(repeating: "Useful engineering context about parts and fit. ", count: 5) + (index == 2310 ? "Unique magneticlatch detail" : ""))
        }
        try save(roots, id: id, records: records)
        try await engine.refresh()
        let start = Date()
        for _ in 0..<20 {
            let found = try await engine.search("magneticlatch")
            XCTAssertEqual(found.first?.record, 2310)
        }
        print("Local search: 2,500 messages, warm exact query mean \(Date().timeIntervalSince(start) * 1000 / 20) ms")
        let folder = roots.sessions.appendingPathComponent(id.uuidString)
        try ConversationStore(folder: folder).append(.init(record: StreamRecord(kind: "You", text: "Journal-only brassclip addition"), merging: false))
        try await engine.refresh()
        let added = try await engine.search("brassclip")
        XCTAssertEqual(added.first?.record, 2500)
        try FileManager.default.removeItem(at: folder)
        try await engine.refresh()
        let deleted = try await engine.search("magneticlatch")
        XCTAssertTrue(deleted.isEmpty)
    }
    @MainActor
    func testSearchReplacesPanesImmediatelyAndClearingRestoresThem() {
        let controller = WorkspaceHistorySearch()
        var visibility: [Bool] = []
        controller.onVisibility = { visibility.append($0) }
        controller.field.stringValue = "wallet"; controller.queryChanged()
        XCTAssertEqual(visibility, [true]); XCTAssertFalse(controller.view.isHidden)
        controller.dismiss()
        XCTAssertEqual(visibility, [true, false]); XCTAssertTrue(controller.view.isHidden)
        controller.stop()
    }
    @MainActor
    func testResultsHaveTwoLinesAndTypingDoesNotOpenThem() async throws {
        let (base, roots) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try save(roots, id: UUID(), records: [StreamRecord(kind: "Agent", text: "The sapphire connector fits.")])
        let engine = LocalHistorySearch(roots: roots); try await engine.refresh()
        let controller = WorkspaceHistorySearch(index: engine)
        var opened = false
        controller.onOpen = { _ in opened = true }
        controller.field.stringValue = "sapphire"; controller.queryChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        let row = try XCTUnwrap(controller.tableView(NSTableView(), viewFor: nil, row: 0) as? NSStackView)
        let labels = row.arrangedSubviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 2)
        XCTAssertTrue(labels[0].stringValue.contains("Orange wallet · PodWallet"))
        XCTAssertTrue(labels[1].stringValue.contains("sapphire"))
        XCTAssertFalse(opened)
        controller.stop()
    }
    @MainActor
    func testOpeningMatchDisablesFollowAndKeepsRecordTarget() {
        let pane = StreamPane(); pane.loadViewIfNeeded()
        pane.replace([StreamRecord(kind: "You", text: "First"), StreamRecord(kind: "Agent", text: "Connector answer")])
        pane.revealSearchMatch(record: 1, needle: "Connector")
        XCTAssertEqual(pane.viewState.firstRecord, 1)
        XCTAssertFalse(pane.viewState.follows)
    }
    @MainActor
    func testSearchImportPreservesLocalMessagesWithoutAConnection() throws {
        let (base, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let session = Session(project: base, thread: "archived", storageRoot: base, needsHistory: true)
        session.report(.user, "Local draft already sent")
        session.importSearchHistory([StreamRecord(kind: "Agent", text: "Recovered sapphire answer", itemID: "answer")])
        XCTAssertTrue(session.history.contains { $0.text == "Local draft already sent" })
        XCTAssertTrue(session.history.contains { $0.text == "Recovered sapphire answer" })
        XCTAssertFalse(session.needsHistory)
        XCTAssertNil(session.client)
        session.stop()
    }
}
