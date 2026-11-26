import AppKit
import XCTest
@testable import ThoughtStream

final class SingleChatIdentityTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    @MainActor
    func testReselectingChatPreservesTranscriptSelectionAndScrollThroughProjectSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chat = Session(project: root, storageRoot: root)
        let spare = Session(project: root, storageRoot: root)
        let other = Session(project: root.appendingPathComponent("Other"), storageRoot: root)
        for i in 0..<40 { chat.report(.prose, "Reply \(i). " + String(repeating: "Conversation history. ", count: 30)) }
        let workspace = WorkspaceWindow(restoredSessions: [chat, spare, other], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let regions = columns(workspace)
        regions[0].stream.restoreViewState(StreamViewState(firstRecord: 3, follows: false, fontSize: 18, searchQuery: "history", searchVisible: true))
        regions[0].conversation.transcript.setSelectedRange(NSRange(location: 2, length: 5))
        regions[0].prompt.string = "Draft stays here"
        workspace.select(0, in: regions[1])
        XCTAssertEqual(columns(workspace).count, 2)
        XCTAssertTrue(regions[0].session === chat); XCTAssertTrue(regions[1].session === spare)
        XCTAssertEqual(regions[0].conversation.transcript.selectedRange(), NSRange(location: 2, length: 5))
        XCTAssertEqual(regions[0].stream.viewState.firstRecord, 3)
        workspace.selectProject(other.project.path)
        workspace.selectProject(root.path)
        try await Task.sleep(nanoseconds: 150_000_000)
        let returned = columns(workspace)
        XCTAssertEqual(returned.compactMap { $0.session?.id }, [chat.id, spare.id])
        XCTAssertEqual(returned[0].stream.viewState.firstRecord, 3)
        XCTAssertEqual(returned[0].stream.viewState.searchQuery, "history")
        XCTAssertEqual(returned[0].prompt.string, "Draft stays here")
    }

    @MainActor
    func testSidebarFocusesExistingRegionAndClosedChatReopensWithDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<2).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { workspace.stopAll(); workspace.window?.close() }
        let original = columns(workspace)
        original[0].prompt.string = "Keep when closed"
        original[1].onFocus?()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let sidebar = try XCTUnwrap(descendants(try XCTUnwrap(workspace.window?.contentView))
            .compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Chats" })
        let row = try XCTUnwrap((0..<sidebar.numberOfRows).first {
            (workspace.tableView(sidebar, viewFor: nil, row: $0) as? NSTableCellView)?.textField?.stringValue == chats[0].sidebarTitle
        })
        sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebar.action), to: sidebar.target, from: sidebar))
        XCTAssertTrue(workspace.window?.firstResponder === original[0].prompt)
        XCTAssertEqual(columns(workspace).count, 2)
        workspace.closePane(original[0])
        XCTAssertEqual(sidebar.numberOfRows, 2, "Closing keeps the chat in the chat list")
        workspace.select(0, in: original[1])
        XCTAssertEqual(columns(workspace).count, 2)
        XCTAssertEqual(columns(workspace).first { $0.session === chats[0] }?.prompt.string, "Keep when closed")
    }
}
