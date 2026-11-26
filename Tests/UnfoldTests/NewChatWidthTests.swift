import AppKit
import XCTest
@testable import ThoughtStream

final class NewChatWidthTests: XCTestCase {
    @MainActor
    func testNewChatsPreserveResizedWidthsInSmallWorkspace() throws {
        try checkInsertion(count: 3)
    }

    @MainActor
    func testNewChatsPreserveResizedWidthsInOverflowingWorkspace() throws {
        try checkInsertion(count: 7)
    }

    @MainActor
    private func checkInsertion(count: Int) throws {
        let previousStyle = InterfaceStyle.current
        InterfaceStyle.current = .roundedPanes
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let sessions = (0..<count).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        var created: [Session] = []
        defer {
            workspace.stopAll(); window.close()
            created.forEach { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent($0.id.uuidString)) }
            try? FileManager.default.removeItem(at: root)
            InterfaceStyle.current = previousStyle
        }
        func descendants(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(descendants)
        }
        func columns() -> [ChatColumn] {
            window.contentViewController.map(descendants)?.compactMap { $0 as? ChatColumn } ?? []
        }
        window.setContentSize(NSSize(width: 1800, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(window.contentViewController.map(descendants)?.compactMap { $0 as? PaneCanvasController }.first)
        let split = try XCTUnwrap(window.contentViewController.map(descendants)?.compactMap { $0 as? NSSplitViewController }.first {
            $0.splitViewItems.allSatisfy { $0.viewController is PaneLayoutController }
        }?.splitView)
        split.setPosition(try XCTUnwrap(split.subviews.first).frame.width + 180, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(canvas.hasCustomSizing)
        let originalWindow = window.frame
        columns()[0].prompt.string = "Keep this draft"
        let original = columns()[0]

        for _ in 0..<2 {
            let before = Dictionary(uniqueKeysWithValues: columns().map { ($0.columnID, $0.view.frame.width) })
            let canvasWidth = canvas.canvasSize.width
            workspace.newChat(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let added = try XCTUnwrap(columns().first { before[$0.columnID] == nil })
            created.append(try XCTUnwrap(added.session))
            for column in columns() {
                if let width = before[column.columnID] {
                    XCTAssertEqual(column.view.frame.width, width, accuracy: 1,
                                   "Creating a chat must preserve existing custom widths")
                }
            }
            let preferred = PaneLayout.adaptiveMinimum(viewport: canvas.viewport, paneInset: PaneSurface.inset).width
            XCTAssertEqual(added.view.frame.width, preferred, accuracy: 1)
            XCTAssertGreaterThan(canvas.canvasSize.width, canvasWidth)
            XCTAssertTrue(canvas.hasCustomSizing)
            XCTAssertTrue(window.firstResponder === added.prompt)
            XCTAssertEqual(window.frame, originalWindow)
            XCTAssertEqual(original.prompt.string, "Keep this draft")
        }
        let expected = columns().map { $0.view.frame.width }
        workspace.stopAll(); store.flush()
        let reopened = WorkspaceWindow(restoredSessions: sessions + created, stateStore: store)
        defer { reopened.stopAll(); reopened.window?.close() }
        reopened.window?.setContentSize(NSSize(width: 1800, height: 1000))
        reopened.window?.contentView?.layoutSubtreeIfNeeded()
        let restored = reopened.window?.contentViewController.map(descendants)?.compactMap { $0 as? ChatColumn } ?? []
        XCTAssertEqual(restored.count, expected.count)
        for (column, width) in zip(restored, expected) {
            XCTAssertEqual(column.view.frame.width, width, accuracy: 1)
        }
    }
}
