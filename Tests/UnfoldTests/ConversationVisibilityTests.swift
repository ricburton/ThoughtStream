import AppKit
import XCTest
@testable import ThoughtStream

final class ConversationVisibilityTests: XCTestCase {
    @MainActor
    func testOnlyConversationActivityMakesDraftVisible() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = Session(project: root, storageRoot: root)
        defer { draft.stop() }
        XCTAssertFalse(draft.hasStartedConversation)
        draft.ready = true
        draft.report(.system, "Connected")
        draft.report(.error, "Sign in before sending")
        XCTAssertFalse(draft.hasStartedConversation)
        // Image-only messages are also represented by a user record.
        draft.report(.user, "{\"type\":\"local_image\"}")
        XCTAssertTrue(draft.hasStartedConversation)
        draft.stop()
        let restored = Session(project: root, id: draft.id, storageRoot: root)
        defer { restored.stop() }
        XCTAssertTrue(restored.hasStartedConversation)

        for session in [
            Session(project: root, thread: "remote-history", storageRoot: root, needsHistory: true),
            Session(project: root, storageRoot: root, provider: .claude, forkSource: "source"),
            Session(project: root, storageRoot: root)
        ] {
            if session.thread == nil && session.forkSource == nil { session.turn = "running" }
            XCTAssertTrue(session.hasStartedConversation)
            session.stop()
        }
    }

    @MainActor
    func testDraftStaysUsableAndHiddenUntilConversationStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let draft = Session(project: root, storageRoot: root)
        let image = ChatAttachment(id: UUID(), name: "Draft image", path: root.appendingPathComponent("draft.png").path)
        store.save(WorkspaceSnapshot(primary: draft.id, drafts: [draft.id: "Restored draft"], attachmentDrafts: [draft.id: [image]]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [draft], stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        var createdID: UUID?
        defer {
            workspace.stopAll(); window.close()
            if let createdID { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(createdID.uuidString)) }
            try? FileManager.default.removeItem(at: root)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        let content = try XCTUnwrap(window.contentView)
        let live = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Live conversations" })
        let projects = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Projects" })
        let column = try XCTUnwrap(columns(try XCTUnwrap(window.contentViewController)).first)
        func titles() -> [String] {
            (0..<live.numberOfRows).compactMap { (workspace.tableView(live, viewFor: nil, row: $0) as? SidebarConversationCell)?.textField?.stringValue }
        }
        XCTAssertEqual(titles(), ["No open conversations"])
        XCTAssertFalse(workspace.tableView(live, shouldSelectRow: 0))
        XCTAssertEqual((workspace.tableView(projects, viewFor: nil, row: 0) as? SidebarProjectCell)?.toolTip, "\(root.path)\n0 chats")
        XCTAssertEqual(column.prompt.string, "Restored draft")
        XCTAssertEqual(column.attachments, [image])
        column.prompt.string = "Keep my draft"
        workspace.newChat(nil)
        let second = try XCTUnwrap(column.session)
        createdID = second.id
        XCTAssertNotEqual(second.id, draft.id)
        XCTAssertEqual(titles(), ["No open conversations"])
        column.onSelectChat?(0)
        XCTAssertTrue(column.session === draft)
        XCTAssertEqual(column.prompt.string, "Keep my draft")
        XCTAssertEqual(column.attachments, [image])
        XCTAssertTrue(column.sendButton.isEnabled)
        workspace.stopAll()
        XCTAssertEqual(store.load()?.drafts[draft.id], "Keep my draft")
        XCTAssertEqual(store.load()?.attachmentDrafts?[draft.id], [image])

        // Simulate the same user record and status notifications produced by sending.
        draft.title = "First conversation"
        draft.report(.user, "Keep my draft")
        draft.receive(["method": "turn/started", "params": ["turn": ["id": "first-turn"]]])
        XCTAssertEqual(titles(), ["First conversation"])
        XCTAssertEqual(live.selectedRow, 0)
        second.title = "Second conversation"
        second.report(.user, "A newer message")
        second.onStatus?("Ready")
        XCTAssertEqual(titles(), ["First conversation", "Second conversation"])
        draft.receive(["method": "turn/completed", "params": ["turn": ["id": "first-turn", "status": "completed"]]])
        XCTAssertEqual(titles(), ["Second conversation", "First conversation"])
        XCTAssertEqual(live.selectedRow, 1)
    }
}
