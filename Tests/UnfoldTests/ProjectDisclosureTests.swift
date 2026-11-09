import AppKit
import XCTest
@testable import ThoughtStream

final class ProjectDisclosureTests: XCTestCase {
    @MainActor
    private func table(in workspace: WorkspaceWindow) throws -> NSTableView {
        workspace.projectHistoryTable
    }

    @MainActor
    private func titles(_ workspace: WorkspaceWindow, _ table: NSTableView) -> [String] {
        (0..<table.numberOfRows).compactMap {
            (workspace.tableView(table, viewFor: nil, row: $0) as? NSTableCellView)?.textField?.stringValue
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("History did not settle within two seconds")
    }

    @MainActor
    func testCollapseWhileLoadingRetryAndRestoredExpansion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project")
        let session = Session(project: project, title: "Saved chat", thread: "saved", storageRoot: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        var requests = 0
        var shouldFail = true
        var pending: CheckedContinuation<Void, Never>?
        let history = ProjectHistory { method, params in
            if method != "thread/list" { return ["thread": ["historyMode": "legacy", "turns": []]] }
            requests += 1
            if requests == 1 { await withCheckedContinuation { pending = $0 } }
            if shouldFail { throw CodexConnection.error("Test history unavailable") }
            return ["data": [["id": "saved", "cwd": project.path], ["id": "older", "cwd": project.path, "name": "Old chat"]]]
        }
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: store, history: history)
        defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
        let sidebar = try table(in: workspace)
        workspace.toggleProjectHistory(project.path)
        try await waitUntil { pending != nil }
        XCTAssertTrue(titles(workspace, sidebar).contains("Loading conversations…"))
        let loading = sidebar.numberOfRows - 1
        XCTAssertFalse(workspace.tableView(sidebar, shouldSelectRow: loading))
        workspace.toggleProjectHistory(project.path)
        XCTAssertEqual(sidebar.numberOfRows, 1)
        workspace.toggleProjectHistory(project.path)
        XCTAssertEqual(requests, 1, "Repeated expansion must reuse the in-flight request")
        pending?.resume(); pending = nil
        try await waitUntil { titles(workspace, sidebar).contains("Could not load all chats · Retry") }
        XCTAssertEqual(titles(workspace, sidebar).filter { $0 == "Saved chat" }.count, 1)
        shouldFail = false
        let retryRow = sidebar.numberOfRows - 1
        XCTAssertTrue(workspace.tableView(sidebar, shouldSelectRow: retryRow))
        sidebar.selectRowIndexes(IndexSet(integer: retryRow), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebar.action), to: sidebar.target, from: sidebar))
        try await waitUntil { !titles(workspace, sidebar).contains("Loading conversations…") }
        XCTAssertEqual(titles(workspace, sidebar), ["Project", "Saved chat", "Old chat"])
        XCTAssertEqual(requests, 3, "Retry must read both active and archived history")
        // A failed refresh leaves the previously fetched conversations available.
        shouldFail = true
        workspace.toggleProjectHistory(project.path)
        workspace.toggleProjectHistory(project.path)
        try await waitUntil { titles(workspace, sidebar).contains("Could not load all chats · Retry") }
        XCTAssertTrue(titles(workspace, sidebar).contains("Old chat"))
        workspace.toggleProjectHistory(project.path)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sidebar.numberOfRows, 1, "A late completion must not re-expand a project")
        workspace.toggleProjectHistory(project.path)
        workspace.stopAll()
        XCTAssertEqual(store.load()?.projects?[project.path]?.historyExpanded, true)
        let restored = WorkspaceWindow(restoredSessions: [session], stateStore: store, history: history)
        defer { restored.stopAll(); restored.window?.close() }
        let restoredTable = try table(in: restored)
        XCTAssertTrue(titles(restored, restoredTable).contains("Saved chat"), "Expansion must survive relaunch")
    }

    @MainActor
    func testHistoryFinishingAfterCollapseDoesNotReopenOrSwitchProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = Session(project: root.appendingPathComponent("A"), storageRoot: root)
        let b = Session(project: root.appendingPathComponent("B"), title: "Current project", storageRoot: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        var gate: CheckedContinuation<Void, Never>?
        var requests = 0
        let reader = ProjectHistory { _, params in
            requests += 1
            if requests == 1 { await withCheckedContinuation { gate = $0 } }
            return ["data": [["id": "past", "cwd": a.project.path, "name": "Past chat"]]]
        }
        let workspace = WorkspaceWindow(restoredSessions: [a, b], stateStore: store, history: reader)
        defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
        let sidebar = try table(in: workspace)
        workspace.toggleProjectHistory(a.project.path)
        try await waitUntil { gate != nil }
        workspace.toggleProjectHistory(a.project.path)
        workspace.selectProject(b.project.path)
        gate?.resume(); gate = nil
        try await waitUntil { requests == 2 }
        // Let discovery publish its result after the final page returns.
        await Task.yield()
        XCTAssertEqual(titles(workspace, sidebar), ["A", "B"])
        XCTAssertEqual(workspace.window?.title, "Current project")
        workspace.toggleProjectHistory(a.project.path)
        XCTAssertTrue(titles(workspace, sidebar).contains("Past chat"), "Re-expanding shows cached results immediately")
        XCTAssertEqual(workspace.window?.title, "Current project")
    }

    @MainActor
    func testRepeatedPaginationCursorFailsInsteadOfDuplicatingRows() async throws {
        var calls = 0
        let reader = ProjectHistory { _, _ in
            calls += 1
            return ["data": [["id": "one", "cwd": "/tmp/history"]], "nextCursor": "same"]
        }
        do {
            _ = try await reader.conversations(in: URL(fileURLWithPath: "/tmp/history"))
            XCTFail("A repeated cursor must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("repeated a page"))
        }
        XCTAssertEqual(calls, 2)
    }
}
