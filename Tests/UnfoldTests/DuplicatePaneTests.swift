import AppKit
import XCTest
@testable import ThoughtStream

final class DuplicatePaneTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    @MainActor
    func testSameConversationKeepsPanePositionsThroughTabProjectAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chat = Session(project: root, storageRoot: root)
        let spare = Session(project: root, storageRoot: root)
        let otherProject = Session(project: root.appendingPathComponent("Other"), storageRoot: root)
        for i in 0..<40 { chat.report(.prose, "Reply \(i). " + String(repeating: "Conversation history. ", count: 30)) }
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(primary: chat.id, secondary: spare.id, primaryTabs: [chat.id, spare.id], secondaryTabs: [chat.id, spare.id])]))
        store.flush()
        let sessions = [chat, spare, otherProject]
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        panes[1].onSelectChat?(0)
        XCTAssertTrue(panes[0].session === chat)
        XCTAssertTrue(panes[1].session === chat)
        panes[0].stream.restoreViewState(StreamViewState(firstRecord: 3, follows: false, fontSize: 16, searchQuery: "left", searchVisible: true))
        panes[1].stream.restoreViewState(StreamViewState(firstRecord: 18, follows: false, fontSize: 20, searchQuery: "right", searchVisible: true))
        try await Task.sleep(nanoseconds: 150_000_000)
        let left = panes[0].stream.viewState
        let right = panes[1].stream.viewState
        XCTAssertEqual(left.firstRecord, 3)
        XCTAssertEqual(right.firstRecord, 18)
        panes[1].onSelectChat?(1)
        XCTAssertTrue(panes[0].session === chat)
        panes[1].onSelectChat?(0)
        XCTAssertEqual(panes[1].stream.viewState.firstRecord, right.firstRecord)
        XCTAssertEqual(panes[1].stream.viewState.searchQuery, "right")
        XCTAssertEqual(panes[0].stream.viewState.firstRecord, left.firstRecord)
        workspace.selectProject(otherProject.project.path)
        workspace.selectProject(root.path)
        let returned = columns(workspace)
        XCTAssertEqual(returned.map { $0.session?.id }, [chat.id, chat.id])
        XCTAssertEqual(returned.map { $0.stream.viewState.firstRecord }, [3, 18])
        XCTAssertEqual(returned.map { $0.stream.viewState.searchQuery }, ["left", "right"])
        workspace.stopAll()
        let relaunched = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { relaunched.stopAll(); relaunched.window?.close() }
        let restored = columns(relaunched)
        XCTAssertEqual(restored.map { $0.session?.id }, [chat.id, chat.id])
        XCTAssertEqual(restored.map { $0.stream.viewState.firstRecord }, [3, 18])
        XCTAssertEqual(restored.map { $0.stream.viewState.fontSize }, [16, 20])
        XCTAssertEqual(restored.map { $0.stream.viewState.follows }, [false, false])
    }

    @MainActor
    func testSharedUpdatesReselectAndDetachLeaveOtherPaneUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chat = Session(project: root, storageRoot: root)
        for i in 0..<20 { chat.report(.prose, "Reply \(i). " + String(repeating: "Older text. ", count: 20)) }
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: ProjectViewState(primary: chat.id, secondary: chat.id)]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        XCTAssertEqual(panes.map { $0.session?.id }, [chat.id, chat.id])
        panes[0].stream.restoreViewState(StreamViewState(firstRecord: 2, follows: false))
        panes[0].conversation.scroll.onScrollUp?()
        panes[0].conversation.transcript.setSelectedRange(NSRange(location: 2, length: 5))
        let transcript = panes[0].conversation.transcript
        panes[0].onSelectChat?(0)
        XCTAssertTrue(panes[0].conversation.transcript === transcript)
        XCTAssertEqual(transcript.selectedRange(), NSRange(location: 2, length: 5))
        XCTAssertEqual(panes[0].stream.viewState.firstRecord, 2)
        // A submission in the right pane resumes only that pane's two views.
        panes[1].stream.resumeLiveActivity()
        panes[1].conversation.resumeLiveActivity()
        chat.report(.user, "New shared request")
        chat.report(.prose, "Shared ", item: "reply", delta: true)
        chat.report(.prose, "answer", item: "reply", delta: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        for pane in panes {
            XCTAssertEqual(pane.stream.recordsSnapshot().last?.text, "Shared answer")
            XCTAssertEqual(pane.conversation.records.last?.text, "Shared answer")
            XCTAssertEqual(pane.stream.records.count, chat.history.count)
        }
        XCTAssertFalse(panes[0].stream.viewState.follows)
        XCTAssertFalse(panes[0].conversation.followsLatest)
        XCTAssertEqual(panes[0].stream.viewState.firstRecord, 2)
        XCTAssertEqual(transcript.selectedRange(), NSRange(location: 2, length: 5))
        XCTAssertTrue(panes[1].stream.viewState.follows)
        XCTAssertTrue(panes[1].conversation.followsLatest)
        panes[1].onCloseChat?(0)
        XCTAssertNil(panes[1].session)
        XCTAssertTrue(panes[0].session === chat)
        XCTAssertFalse(store.load()?.closedTabs?.contains(chat.id) ?? false)
        chat.report(.prose, "Still attached")
        XCTAssertEqual(panes[0].stream.recordsSnapshot().last?.text, "Still attached")
        XCTAssertTrue(panes[1].stream.recordsSnapshot().isEmpty)
    }

    @MainActor
    func testMovingSharedTabVacatesOnlyItsSourceAndCloseCanSelectSharedNeighbor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chat = Session(project: root, storageRoot: root)
        let spare = Session(project: root, storageRoot: root)
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(primary: chat.id, secondary: spare.id, primaryTabs: [chat.id], secondaryTabs: [chat.id, spare.id])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [chat, spare], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        panes[1].onCloseChat?(1)
        XCTAssertTrue(panes[1].session === chat, "Closing a tab can reveal a neighbor already shown elsewhere")
        XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: chat.id, columnID: panes[1].columnID), on: .right, in: panes[1]))
        XCTAssertTrue(panes[0].session === chat)
        XCTAssertNil(panes[1].session)
        XCTAssertTrue(columns(workspace).last?.session === chat)
    }

    @MainActor
    func testConversationSidebarOpensInFocusedPane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chat = Session(project: root, storageRoot: root)
        chat.report(.user, "Existing conversation")
        let ids = [UUID(), UUID()]
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(layout: .split(vertical: true, fraction: 0.5, first: .pane(ids[0]), second: .pane(ids[1])),
                panes: [PaneViewState(id: ids[0], session: chat.id, tabs: [chat.id], tabOffset: 0),
                        PaneViewState(id: ids[1], session: nil, tabs: [], tabOffset: 0)])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        panes[1].onFocus?()
        workspace.window?.makeFirstResponder(panes[1].prompt)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let sidebar = try XCTUnwrap(descendants(try XCTUnwrap(workspace.window?.contentView))
            .compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Live conversations" })
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebar.action), to: sidebar.target, from: sidebar))
        XCTAssertEqual(panes.map { $0.session?.id }, [chat.id, chat.id])
    }
}
