import AppKit
import XCTest
@testable import ThoughtStream

final class SidebarPaneFocusTests: XCTestCase {
    @MainActor
    func testChatListCentersSelectedPaneInBothDirectionsAndOnReselection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chats = (0..<6).map { index in
            let chat = Session(project: root, title: "Conversation \(index)", storageRoot: root)
            chat.report(.user, "Message \(index)")
            return chat
        }
        let regions = chats.map { ChatRegionState(id: UUID(), session: $0.id) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(regions: regions, layout: PaneLayout.arranged(regions.map(\.id), as: .columns),
                             focusedPane: regions[0].id)]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        window.setContentSize(NSSize(width: 1120, height: 800))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func controllers(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        let allControllers = controllers(try XCTUnwrap(window.contentViewController))
        let canvas = try XCTUnwrap(allControllers.compactMap { $0 as? PaneCanvasController }.first)
        let columns = allControllers.compactMap { $0 as? ChatColumn }
        let table = try XCTUnwrap(views(content).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Chats" })
        let scroll = try XCTUnwrap(canvas.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        canvas.fit()
        XCTAssertTrue(canvas.overflows.horizontal)

        func selectAndCheck(_ index: Int) throws {
            let target = try XCTUnwrap(columns.first { $0.session === chats[index] })
            target.prompt.string = "Keep draft \(index)"
            let row = try XCTUnwrap((0..<table.numberOfRows).first {
                (workspace.tableView(table, viewFor: nil, row: $0) as? SidebarConversationCell)?.textField?.stringValue == chats[index].title
            })
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(table.action), to: table.target, from: table))
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            content.layoutSubtreeIfNeeded()
            let rect = document.convert(target.view.bounds, from: target.view)
            let desiredX = min(max(0, rect.midX - canvas.viewport.width / 2),
                               canvas.canvasSize.width - canvas.viewport.width)
            XCTAssertEqual(canvas.visibleRect.minX, desiredX, accuracy: 1, "Center chat \(index), clamping at either end")
            XCTAssertTrue(window.firstResponder === target.prompt)
            XCTAssertEqual(target.prompt.string, "Keep draft \(index)")
            XCTAssertEqual(table.selectedRow, row)
        }

        for index in [3, 0, 4, 5, 1] { try selectAndCheck(index) }
        XCTAssertTrue(canvas.scrollSideways(by: -10_000, over: canvas.horizontalNavigation))
        try selectAndCheck(1) // Clicking the already-selected chat brings it back.
        let previous = canvas.visibleRect.origin
        columns[2].onFocus?() // A direct click inside a pane must not pan the canvas.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(canvas.visibleRect.origin, previous)
        XCTAssertEqual(columns.count, chats.count)
    }
}
