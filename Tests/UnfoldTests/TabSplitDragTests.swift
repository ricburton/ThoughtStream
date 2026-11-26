import AppKit
import XCTest
@testable import ThoughtStream

final class TabSplitDragTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    func testEdgeTargetsLeaveCenterAndOutsideInactive() {
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertEqual(TabSplitSide.target(at: NSPoint(x: 100, y: 350), in: bounds), .left)
        XCTAssertEqual(TabSplitSide.target(at: NSPoint(x: 800, y: 350), in: bounds), .right)
        XCTAssertNil(TabSplitSide.target(at: NSPoint(x: 450, y: 350), in: bounds))
        XCTAssertNil(TabSplitSide.target(at: NSPoint(x: -1, y: 350), in: bounds))
        XCTAssertNil(TabSplitSide.target(at: NSPoint(x: 20, y: 701), in: bounds))
        let left = TabSplitSide.left.previewFrame(in: bounds, divider: 1)
        let right = TabSplitSide.right.previewFrame(in: bounds, divider: 1)
        XCTAssertEqual(left.width, right.width)
        XCTAssertEqual(left.minX, bounds.maxX - right.maxX)
    }


    @MainActor
    func testMovingChatInAllDirectionsPreservesRegionDraftAndRestoresLayout() throws {
        for side in [TabSplitSide.left, .right, .top, .bottom] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
            let chats = (0..<3).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
            let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
            defer { workspace.stopAll(); workspace.window?.close() }
            let original = columns(workspace)
            let source = original[0], destination = original[2]
            source.prompt.string = "Unsaved draft"
            source.prompt.setSelectedRange(NSRange(location: 2, length: 4))
            let payload = ChatTabDrag(sessionID: chats[0].id, columnID: source.columnID)
            XCTAssertTrue(workspace.canDropTab(payload, on: side, in: destination))
            XCTAssertEqual(columns(workspace).map(\.columnID), original.map(\.columnID))
            XCTAssertTrue(workspace.dropTab(payload, on: side, in: destination))
            let moved = columns(workspace)
            XCTAssertEqual(moved.count, 3)
            XCTAssertTrue(moved.contains { $0 === source })
            XCTAssertEqual(Set(moved.compactMap { $0.session?.id }).count, 3)
            XCTAssertEqual(source.prompt.string, "Unsaved draft")
            XCTAssertEqual(source.prompt.selectedRange(), NSRange(location: 2, length: 4))
            XCTAssertTrue(workspace.window?.firstResponder === source.prompt)
            let sourceIndex = try XCTUnwrap(moved.firstIndex(of: source))
            let targetIndex = try XCTUnwrap(moved.firstIndex(of: destination))
            XCTAssertEqual(sourceIndex, targetIndex + (side.leading ? -1 : 1))
            workspace.stopAll()
            let restored = WorkspaceWindow(restoredSessions: chats, stateStore: store)
            defer { restored.stopAll(); restored.window?.close() }
            XCTAssertEqual(columns(restored).map(\.columnID), moved.map(\.columnID))
            XCTAssertEqual(columns(restored)[sourceIndex].prompt.string, "Unsaved draft")
        }
    }

    @MainActor
    func testSelfAndForeignDragCannotDuplicateOrVacateAChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { workspace.stopAll(); workspace.window?.close() }
        let column = try XCTUnwrap(columns(workspace).first)
        let payload = ChatTabDrag(sessionID: chat.id, columnID: column.columnID)
        XCTAssertFalse(workspace.dropTab(payload, on: .left, in: column))
        XCTAssertFalse(workspace.dropTab(ChatTabDrag(sessionID: chat.id, columnID: UUID()), on: .right, in: column))
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(column.session === chat)
    }
    @MainActor
    func testHoverPreviewUsesInnermostPaneAndClearsWithoutDropping() {
        let outer = TabSplitHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let inner = TabSplitHostView(frame: NSRect(x: 450, y: 0, width: 450, height: 700))
        outer.addSubview(inner)
        outer.validate = { _, _ in true }; inner.validate = { _, _ in true }
        var drops = 0
        inner.onDrop = { _, _ in drops += 1; return true }
        let payload = ChatTabDrag(sessionID: UUID(), columnID: UUID())
        let match = TabSplitHostView.previewDestination(for: payload, at: NSPoint(x: 890, y: 350), in: outer)
        XCTAssertTrue(match?.0 === inner)
        XCTAssertEqual(inner.previewSide, .right)
        XCTAssertNil(outer.previewSide)
        XCTAssertEqual(drops, 0)
        TabSplitHostView.clearPreviews(in: outer)
        XCTAssertNil(inner.previewSide)
        XCTAssertEqual(drops, 0)
        inner.validate = { _, _ in false }; outer.validate = { _, _ in false }
        XCTAssertNil(TabSplitHostView.previewDestination(for: payload, at: NSPoint(x: 890, y: 350), in: outer))
    }

}
