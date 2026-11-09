import AppKit
import XCTest
@testable import ThoughtStream

final class SplitStackTests: XCTestCase {
    @MainActor
    private func descendants<T: NSViewController>(_ controller: NSViewController, of type: T.Type) -> [T] {
        (controller as? T).map { [$0] } ?? controller.children.flatMap { descendants($0, of: type) }
    }

    @MainActor
    private func panes(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        workspace.window?.contentViewController.map { descendants($0, of: ChatColumn.self) } ?? []
    }

    @MainActor
    private func dividers(_ workspace: WorkspaceWindow) -> [NSSplitView] {
        guard let root = workspace.window?.contentViewController else { return [] }
        func collect(_ controller: NSViewController) -> [NSSplitView] {
            let own = (controller as? NSSplitViewController).flatMap { split in
                split.splitViewItems.count == 2 && split.splitViewItems.allSatisfy { $0.viewController is PaneLayoutController } ? split.splitView : nil
            }
            return (own.map { [$0] } ?? []) + controller.children.flatMap(collect)
        }
        return collect(root)
    }

    @MainActor
    func testSplitAndStackPlaceNewPanesAndRestoreResizedLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let original = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [original], stateStore: store)
        var created: [Session] = []
        defer {
            workspace.stopAll(); workspace.window?.close()
            created.forEach { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent($0.id.uuidString)) }
            try? FileManager.default.removeItem(at: root)
        }
        let window = try XCTUnwrap(workspace.window)
        window.setContentSize(NSSize(width: 1400, height: 1000))
        let first = try XCTUnwrap(panes(workspace).first)
        first.prompt.string = "Original draft"
        workspace.splitStream(nil)
        let right = try XCTUnwrap(panes(workspace).last)
        created.append(try XCTUnwrap(right.session))
        right.prompt.string = "Right draft"
        XCTAssertTrue(window.firstResponder === right.prompt)
        XCTAssertEqual(first.view.frame.width, right.view.frame.width, accuracy: 1)
        workspace.stackStream(nil)
        let bottom = try XCTUnwrap(panes(workspace).last)
        created.append(try XCTUnwrap(bottom.session))
        bottom.prompt.string = "Bottom draft"
        XCTAssertEqual(panes(workspace).count, 3)
        XCTAssertTrue(window.firstResponder === bottom.prompt)
        XCTAssertEqual(right.view.frame.height, bottom.view.frame.height, accuracy: 1)
        let firstRect = first.view.convert(first.view.bounds, to: window.contentView)
        let rightRect = right.view.convert(right.view.bounds, to: window.contentView)
        let bottomRect = bottom.view.convert(bottom.view.bounds, to: window.contentView)
        XCTAssertLessThanOrEqual(firstRect.maxX, rightRect.minX)
        XCTAssertLessThanOrEqual(bottomRect.maxY, rightRect.minY)
        XCTAssertEqual(rightRect.minX, bottomRect.minX, accuracy: 1)
        for split in dividers(workspace) {
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition((length - split.dividerThickness) * (split.isVertical ? 0.61 : 0.45), ofDividerAt: 0)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.stopAll()
        let saved = try XCTUnwrap(store.load()?.projects?[root.path])
        guard case .split(true, let horizontalFraction, .pane, .split(false, let verticalFraction, .pane, .pane)) = saved.layout else {
            return XCTFail("Expected a split whose right pane is stacked")
        }
        XCTAssertEqual(horizontalFraction, 0.61, accuracy: 0.01)
        XCTAssertEqual(verticalFraction, 0.45, accuracy: 0.01)
        let restored = WorkspaceWindow(restoredSessions: [original] + created, stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(panes(restored).map(\.columnID), panes(workspace).map(\.columnID))
        XCTAssertEqual(panes(restored).map { $0.prompt.string }, ["Original draft", "Right draft", "Bottom draft"])
        XCTAssertEqual(Set(panes(restored).compactMap { $0.session?.id }).count, 3)
        XCTAssertTrue(restored.window?.firstResponder === panes(restored).last?.prompt)
        for split in dividers(restored) {
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            let firstLength = split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
            XCTAssertEqual(firstLength / length, split.isVertical ? 0.61 : 0.45, accuracy: 0.01)
        }
    }

    @MainActor
    func testPaneFocusCyclesAndClosingAnotherPanePreservesFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let sessions = (0..<3).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
        workspace.window?.setContentSize(NSSize(width: 1400, height: 1000))
        let first = try XCTUnwrap(panes(workspace).first)
        XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: sessions[1].id, columnID: first.columnID), on: .right, in: first))
        let right = try XCTUnwrap(panes(workspace).last)
        XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: sessions[2].id, columnID: first.columnID), on: .bottom, in: right))
        let bottom = try XCTUnwrap(panes(workspace).last)
        func assertSingleActivePane(_ expected: ChatColumn, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(panes(workspace).filter(\.isActivePane).map(\.columnID), [expected.columnID], file: file, line: line)
            for pane in panes(workspace) {
                XCTAssertEqual((pane.view as? WorkspaceSurface)?.fill, FeedPalette.canvas, file: file, line: line)
                XCTAssertEqual(pane.conversation.fill, FeedPalette.canvas, file: file, line: line)
            }
        }
        workspace.focusNextPane(nil)
        XCTAssertTrue(workspace.window?.firstResponder === first.prompt)
        assertSingleActivePane(first)
        workspace.focusPreviousPane(nil)
        XCTAssertTrue(workspace.window?.firstResponder === bottom.prompt)
        assertSingleActivePane(bottom)
        workspace.closePane(first)
        XCTAssertTrue(workspace.window?.firstResponder === bottom.prompt)
        assertSingleActivePane(bottom)
        workspace.closeFocusedPane(nil)
        XCTAssertEqual(panes(workspace).count, 1)
        XCTAssertTrue(workspace.window?.firstResponder === right.prompt)
        assertSingleActivePane(right)
        workspace.focusNextPane(nil)
        XCTAssertTrue(workspace.window?.firstResponder === right.prompt)
    }
}
