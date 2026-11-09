import AppKit
import XCTest
@testable import ThoughtStream

final class ProjectHistoryTests: XCTestCase {
    @MainActor
    func testDiscoveryPagesFiltersFolderAndDeduplicatesThreads() async throws {
        let project = URL(fileURLWithPath: "/tmp/ThoughtStream-history-test")
        var calls: [[String: Any]] = []
        let reader = ProjectHistory { method, params in
            XCTAssertEqual(method, "thread/list")
            calls.append(params)
            if params["archived"] as? Bool == true {
                return ["data": [["id": "a", "cwd": project.path], ["id": "archived", "cwd": project.path, "name": "Archived chat"]]]
            }
            if params["cursor"] == nil {
                return ["data": [
                    ["id": "a", "cwd": project.path, "name": "Named chat", "preview": "ignored", "updatedAt": 1234] as [String: Any],
                    ["id": "elsewhere", "cwd": project.path + "-other"],
                    ["id": "child", "cwd": project.path, "parentThreadId": "a"]
                ], "nextCursor": "second"]
            }
            return ["data": [["id": "a", "cwd": project.path], ["id": "b", "cwd": project.path, "preview": "Earlier conversation\nsecond line"]]]
        }
        let result = try await reader.conversations(in: project)
        XCTAssertEqual(result.map(\.id), ["a", "b", "archived"])
        XCTAssertEqual(result.map(\.title), ["Named chat", "Earlier conversation", "Archived chat"])
        XCTAssertEqual(result.first?.updatedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0]["cwd"] as? [String], [project.path])
        XCTAssertEqual(calls[0]["modelProviders"] as? [String], [])
        XCTAssertEqual(calls[0]["archived"] as? Bool, false)
        XCTAssertEqual(calls[2]["archived"] as? Bool, true)
    }

    @MainActor
    func testPaginatedTranscriptIncludesAllTurnsAndOnlyReasoningSummaries() async throws {
        var methods: [String] = []
        let reader = ProjectHistory { method, params in
            methods.append(method)
            if method == "thread/read" { return ["thread": ["historyMode": "paginated", "createdAt": 10]] }
            XCTAssertEqual(params["itemsView"] as? String, "full")
            XCTAssertEqual(params["sortDirection"] as? String, "asc")
            if params["cursor"] == nil {
                return ["data": [["startedAt": 20, "items": [
                    ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "Earlier question"]]],
                    ["id": "r", "type": "reasoning", "summary": ["Useful summary"], "content": ["Do not display"]],
                    ["id": "c", "type": "commandExecution", "cwd": "/tmp", "command": "pwd", "status": "completed", "exitCode": 0, "aggregatedOutput": "/tmp", "durationMs": 12]
                ]]], "nextCursor": "next"]
            }
            return ["data": [["startedAt": 30, "items": [["id": "a", "type": "agentMessage", "text": "Earlier answer"]]]]]
        }
        let records = try await reader.transcript("previous")
        XCTAssertEqual(methods, ["thread/read", "thread/turns/list", "thread/turns/list"])
        XCTAssertEqual(records.map(\.text), ["Earlier question", "Useful summary", "/tmp\n$ pwd", "/tmp", "Earlier answer"])
        XCTAssertEqual(records.first?.time, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(records.first { $0.kind == StreamKind.command.rawValue }?.command?.state, .succeeded)
    }

    @MainActor
    func testFailedHistoryLoadRetriesWithoutLosingPendingImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, thread: "previous", storageRoot: root, needsHistory: true)
        var attempts = 0
        let reader = ProjectHistory { _, params in
            attempts += 1
            if attempts == 1 { throw CodexConnection.error("Unavailable") }
            if params["includeTurns"] as? Bool == false { return ["thread": ["historyMode": "legacy"]] }
            return ["thread": ["turns": [["items": [["type": "agentMessage", "text": "Restored answer"]]]]]]
        }
        do { try await session.loadHistory(using: reader); XCTFail("Should fail") } catch { }
        XCTAssertTrue(session.needsHistory)
        XCTAssertTrue(session.history.isEmpty)
        try await session.loadHistory(using: reader)
        XCTAssertFalse(session.needsHistory)
        XCTAssertEqual(session.history.map(\.text), ["Restored answer"])
        try await session.loadHistory(using: reader)
        XCTAssertEqual(attempts, 3)
        session.stop()
        let metadata = try Data(contentsOf: root.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(json["needsHistory"] as? Bool, false)
    }

    @MainActor
    func testProjectHistoryIsLazyPreservesDraftsAndReopensClosedChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let existing = Session(project: a, title: "Existing", thread: "existing", storageRoot: root)
        let closed = Session(project: a, title: "Closed", thread: "closed", storageRoot: root)
        let other = Session(project: b, title: "Other", storageRoot: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(drafts: [existing.id: "Keep my draft", closed.id: "Closed draft"], closedTabs: [closed.id], selectedProject: a.path,
                                    projects: [a.path: ProjectViewState(primary: existing.id, primaryTabs: [existing.id]), b.path: ProjectViewState(primary: other.id)]))
        store.flush()
        var searches = 0
        let reader = ProjectHistory { method, params in
            if method == "thread/list" {
                searches += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                let paths = params["cwd"] as? [String] ?? []
                return ["data": paths.contains(a.path) ? [
                    ["id": "existing", "cwd": a.path], ["id": "closed", "cwd": a.path],
                    ["id": "new", "cwd": a.path, "preview": "Recovered chat"]
                ] : []]
            }
            return ["thread": ["historyMode": "legacy", "turns": []]]
        }
        let workspace = WorkspaceWindow(restoredSessions: [existing, closed, other], stateStore: store, history: reader)
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        let controller = try XCTUnwrap(workspace.window?.contentViewController)
        let sidebar = try XCTUnwrap(descend(controller.view).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Projects" })
        var imported: [UUID] = []
        defer {
            workspace.stopAll(); workspace.window?.close()
            for id in imported { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(id.uuidString)) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(searches, 0, "Collapsed projects should not start discovery")
        XCTAssertEqual(sidebar.numberOfRows, 2)
        let projectCell = try XCTUnwrap(workspace.tableView(sidebar, viewFor: nil, row: 0) as? SidebarProjectCell)
        let disclosure = try XCTUnwrap(projectCell.subviews.compactMap { $0 as? ProjectHistoryDisclosureButton }.first)
        XCTAssertTrue(disclosure.accessibilityLabel()?.contains("Expand") == true)
        disclosure.performClick(nil)
        // Complete A's discovery while B is visible.
        workspace.selectProject(b.path)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(columns(controller).first?.session === other)
        XCTAssertEqual(sidebar.numberOfRows, 5, "Both provider pages must deduplicate existing and closed threads")
        workspace.selectProject(a.path)
        try await Task.sleep(nanoseconds: 150_000_000)
        let pane = try XCTUnwrap(columns(controller).first)
        XCTAssertTrue(pane.session === existing)
        XCTAssertEqual(pane.prompt.string, "Keep my draft")
        XCTAssertEqual(pane.tabIDs, [existing.id], "Discovery must not open historical chats as tabs")
        func click(_ title: String) throws {
            let row = try XCTUnwrap((0..<sidebar.numberOfRows).first {
                (workspace.tableView(sidebar, viewFor: nil, row: $0) as? NSTableCellView)?.textField?.stringValue == title
            })
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebar.action), to: sidebar.target, from: sidebar))
        }
        try click("Closed")
        XCTAssertTrue(pane.session === closed)
        XCTAssertEqual(pane.prompt.string, "Closed draft")
        XCTAssertEqual(pane.tabIDs.filter { $0 == closed.id }.count, 1)
        try click("Recovered chat")
        let recovered = try XCTUnwrap(pane.session)
        imported = [recovered.id]
        XCTAssertEqual(recovered.thread, "new")
        try click("Recovered chat")
        XCTAssertEqual(pane.tabIDs.filter { $0 == recovered.id }.count, 1)
        XCTAssertEqual(sidebar.numberOfRows, 5)
        workspace.toggleProjectHistory(a.path)
        XCTAssertEqual(sidebar.numberOfRows, 2)
        workspace.toggleProjectHistory(a.path)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sidebar.numberOfRows, 5)
        workspace.stopAll()
        XCTAssertEqual(store.load()?.projects?[a.path]?.historyExpanded, true)
        XCTAssertEqual(store.load()?.drafts[existing.id], "Keep my draft")
        XCTAssertFalse(store.load()?.closedTabs?.contains(closed.id) ?? true)
        XCTAssertGreaterThanOrEqual(searches, 2)
    }

    @MainActor
    func testLiveLocalHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["UNFOLD_HISTORY_LIVE_TEST"] == "1" else { throw XCTSkip("Opt in to local history reads.") }
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/UnfoldNative/Build/ThoughtStream.app/Contents/Resources/codex/bin/codex")
        let reader = ProjectHistory(executable: executable)
        defer { reader.stop() }
        let project = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ChatGPT/ThoughtStream")
        let matches = try await reader.conversations(in: project)
        let previous = try XCTUnwrap(matches.last)
        let records = try await reader.transcript(previous.id)
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.contains { $0.kind == StreamKind.user.rawValue })
        print("Read-only local history: \(matches.count) conversations, \(records.count) records in selected transcript")
    }
}
