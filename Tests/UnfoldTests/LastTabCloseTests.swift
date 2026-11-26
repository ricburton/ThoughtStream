import AppKit
import XCTest
@testable import ThoughtStream

final class LastTabCloseTests: XCTestCase {
    @MainActor
    private final class CloseTracker: NSObject {
        var didClose = false
        @objc func closed(_ notification: Notification) { didClose = true }
    }

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
    func testClosingFinalChatMovesUpInRecencyOrderAndKeepsDrafts() throws {
        for useShortcut in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chats = (1...3).map { index -> Session in
                let chat = session(index, project: root.appendingPathComponent("Project \(index)"), root: root)
                chat.importSearchHistory([StreamRecord(kind: "You", text: "Work \(index)",
                    time: Date(timeIntervalSince1970: Double(index * 100)))])
                return chat
            }
            let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
            let closing = chats[1], destination = chats[2]
            store.save(WorkspaceSnapshot(drafts: [destination.id: "Destination draft"], selectedProject: closing.project.path,
                projects: Dictionary(uniqueKeysWithValues: chats.map { ($0.project.path, state([[$0]])) })))
            store.flush()
            let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
            defer { workspace.stopAll(); workspace.window?.close() }
            let window = try XCTUnwrap(workspace.window)
            let tracker = CloseTracker()
            NotificationCenter.default.addObserver(tracker, selector: #selector(CloseTracker.closed(_:)),
                name: NSWindow.willCloseNotification, object: window)
            defer { NotificationCenter.default.removeObserver(tracker) }
            let pane = try XCTUnwrap(columns(workspace).first)
            pane.prompt.string = "Closing draft"
            closing.turn = "still-working"
            XCTAssertTrue(workspace.validateMenuItem(NSMenuItem(title: "Close Chat",
                action: #selector(WorkspaceWindow.closeFocusedPane(_:)), keyEquivalent: "")))
            workspace.toggleProjectHistory(closing.project.path)
            if useShortcut { workspace.closeTab(nil) }
            else { workspace.closePane(pane) }
            XCTAssertFalse(tracker.didClose)
            XCTAssertEqual(window.title, destination.title)
            XCTAssertTrue(columns(workspace)[0].session === destination)
            XCTAssertEqual(columns(workspace)[0].prompt.string, "Destination draft")
            XCTAssertEqual(closing.turn, "still-working")
            store.flush()
            XCTAssertEqual(store.load()?.selectedProject, destination.project.path)
            XCTAssertTrue(store.load()?.closedTabs?.contains(closing.id) == true)
            workspace.selectProject(closing.project.path)
            XCTAssertNil(columns(workspace)[0].session, "Returning to the project must not reopen the closed chat")
            workspace.reopenClosedTab(nil)
            XCTAssertTrue(columns(workspace)[0].session === closing)
            XCTAssertEqual(columns(workspace)[0].prompt.string, "Closing draft")
        }
    }

    @MainActor
    func testClosingTopProjectWrapsAndClosingEmptyProjectNavigates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = session(1, project: root.appendingPathComponent("A"), root: root)
        let b = session(2, project: root.appendingPathComponent("B"), root: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: a.project.path,
            projects: [a.project.path: state([[a]]), b.project.path: state([[b]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [b, a], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.closeTab(nil)
        XCTAssertTrue(columns(workspace)[0].session === b)
        workspace.selectProject(a.project.path)
        XCTAssertNil(columns(workspace)[0].session)
        workspace.closeTab(nil)
        XCTAssertTrue(columns(workspace)[0].session === b)
    }

    @MainActor
    func testRepeatedCloseInOnlyProjectKeepsWindowOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = session(1, project: root, root: root)
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { workspace.stopAll(); workspace.window?.close() }
        let tracker = CloseTracker()
        NotificationCenter.default.addObserver(tracker, selector: #selector(CloseTracker.closed(_:)),
            name: NSWindow.willCloseNotification, object: workspace.window)
        defer { NotificationCenter.default.removeObserver(tracker) }
        workspace.closeTab(nil)
        workspace.closeTab(nil)
        workspace.closePane(try XCTUnwrap(columns(workspace).first))
        XCTAssertFalse(tracker.didClose)
        XCTAssertNil(columns(workspace)[0].session)
    }


    @MainActor
    func testClosingChatPreservesOtherRegionAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...3).map { session($0, project: root, root: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: state([[chats[0]], [chats[0], chats[2]]])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: Array(chats.reversed()), stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let regions = columns(workspace)
        XCTAssertEqual(regions.count, 2)
        regions[1].prompt.string = "Keep the other draft"
        workspace.closePane(regions[0])
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(columns(workspace)[0] === regions[1])
        XCTAssertTrue(regions[1].session === chats[2])
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(columns(restored).count, 1)
        XCTAssertTrue(columns(restored)[0].session === chats[2])
        XCTAssertEqual(columns(restored)[0].prompt.string, "Keep the other draft")
    }
    @MainActor
    func testFinalChatLeavesEmptyWorkspaceWithoutOpeningAnotherConversation() throws {
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
            XCTAssertNil(pane.session)
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
        XCTAssertNil(columns(workspace)[0].session)
    }

    @MainActor
    func testLastConversationDoesNotReappearOnRelaunch() throws {
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
        XCTAssertNil(columns(workspace)[0].session)
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertNil(columns(restored)[0].session)
        XCTAssertNil(columns(restored)[0].session)
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
        XCTAssertNil(columns(workspace)[0].session)
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
        XCTAssertEqual(columns(workspace)[0].session?.id, chats[2].id)
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
