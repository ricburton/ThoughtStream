import AppKit
import XCTest
@testable import ThoughtStream

final class LastTabCloseTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    @MainActor
    private func session(_ number: Int, project: URL, root: URL, live: Bool = true) -> Session {
        Session(project: project,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                title: "Chat \(number)", thread: live ? "thread-\(number)" : nil, storageRoot: root)
    }

    @MainActor
    private func state(_ tabs: [[Session]]) -> ProjectViewState {
        let panes = tabs.map { PaneViewState(id: UUID(), session: $0.first?.id, tabs: $0.map(\.id), tabOffset: 0) }
        let layout = panes.dropFirst().reduce(PaneLayout.pane(panes[0].id)) {
            .split(vertical: true, fraction: 0.5, first: $0, second: .pane($1.id))
        }
        return ProjectViewState(layout: layout, panes: panes, focusedPane: panes[0].id)
    }

    @MainActor
    func testFinalTabClosesPaneAndPreservesOtherPaneAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...3).map { session($0, project: root, root: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chats[0]], [chats[0], chats[2]]])]))
        store.flush()
        // Storage order deliberately differs from the live list's UUID order.
        let workspace = WorkspaceWindow(restoredSessions: Array(chats.reversed()), stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        panes[1].prompt.string = "Keep the other pane's draft"
        workspace.window?.makeFirstResponder(panes[1].prompt)
        panes[0].onCloseChat?(2)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(columns(workspace)[0] === panes[1])
        XCTAssertTrue(panes[1].session === chats[0])
        XCTAssertEqual(panes[1].tabIDs, [chats[0].id, chats[2].id])
        XCTAssertEqual(panes[1].prompt.string, "Keep the other pane's draft")
        XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        let restoredPanes = columns(restored)
        XCTAssertEqual(restoredPanes.count, 1)
        XCTAssertTrue(restoredPanes[0].session === chats[0])
        XCTAssertEqual(restoredPanes[0].tabIDs, [chats[0].id, chats[2].id])
        XCTAssertEqual(restoredPanes[0].prompt.string, "Keep the other pane's draft")
    }

    @MainActor
    func testFinalTabClosesWindowWithoutOpeningAnotherConversation() throws {
        for closing in [1, 2] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chats = (1...3).map { session($0, project: root, root: root) }
            let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
            store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chats[closing]]])]))
            store.flush()
            let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
            defer { workspace.stopAll(); workspace.window?.close() }
            let pane = try XCTUnwrap(columns(workspace).first)
            workspace.closeTab(nil)
            XCTAssertNil(pane.session)
            XCTAssertTrue(pane.tabIDs.isEmpty)
            XCTAssertFalse(workspace.window?.isVisible ?? true)
            workspace.stopAll()
            XCTAssertTrue(store.load()?.closedTabs?.contains(chats[closing].id) == true)
        }
    }

    @MainActor
    func testWorkingFinalTabDoesNotOpenAnotherLiveConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...3).map { session($0, project: root, root: root) }
        chats[2].turn = "running"
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chats[2]]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.closeTab(nil)
        XCTAssertNil(columns(workspace)[0].session)
        XCTAssertTrue(columns(workspace)[0].tabIDs.isEmpty)
    }

    @MainActor
    func testLastConversationClosesWindowAndDoesNotReappearOnRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = session(1, project: root, root: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chat]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.closeTab(nil)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertNil(columns(workspace)[0].session)
        XCTAssertTrue(columns(workspace)[0].tabIDs.isEmpty)
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertNil(columns(restored)[0].session)
        XCTAssertTrue(columns(restored)[0].tabIDs.isEmpty)
        restored.reopenClosedTab(nil)
        XCTAssertTrue(columns(restored)[0].session === chat)
    }

    @MainActor
    func testDraftFinalTabClosesWithoutReopeningOtherChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = session(1, project: root, root: root, live: false)
        let closed = session(2, project: root, root: root)
        let next = session(3, project: root, root: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(closedTabs: [closed.id], selectedProject: root.path,
                                     projects: [root.path: state([[draft]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [draft, closed, next], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.closeTab(nil)
        XCTAssertNil(columns(workspace)[0].session)
        XCTAssertTrue(columns(workspace)[0].tabIDs.isEmpty)
    }

    @MainActor
    func testRemainingPaneTabTakesPriorityOverNextLiveConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...3).map { session($0, project: root, root: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chats[0], chats[2]]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.closeTab(nil)
        XCTAssertTrue(columns(workspace)[0].session === chats[2])
        XCTAssertEqual(columns(workspace)[0].tabIDs, [chats[2].id])
    }

    @MainActor
    func testFinalTabPreservesSiblingPaneWithoutSwitchingProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let closing = session(1, project: a, root: root)
        let next = session(2, project: b, root: root)
        let sibling = session(3, project: a, root: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: a.path,
                                     projects: [a.path: state([[closing], [sibling]]), b.path: state([[next]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [closing, sibling, next], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        columns(workspace)[1].prompt.string = "Keep project A's draft"
        workspace.closeTab(nil)
        let panes = columns(workspace)
        XCTAssertEqual(panes.count, 1)
        XCTAssertTrue(panes[0].session === sibling)
        XCTAssertEqual(panes[0].prompt.string, "Keep project A's draft")
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: [closing, sibling, next], stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(columns(restored).count, 1)
        XCTAssertTrue(columns(restored)[0].session === sibling)
    }
}
