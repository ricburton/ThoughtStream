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
    func testDropOnEitherSideMovesOnlyTheTabAndRestoresDraftsAfterRelaunch() throws {
        for side in [TabSplitSide.left, .right] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
            let first = Session(project: root, title: "First", storageRoot: root)
            let second = Session(project: root, title: "Second", storageRoot: root)
            store.save(WorkspaceSnapshot(drafts: [first.id: "First draft", second.id: "Second draft"], selectedProject: root.path,
                projects: [root.path: ProjectViewState(primary: first.id, primaryTabs: [first.id, second.id])]))
            store.flush()
            let workspace = WorkspaceWindow(restoredSessions: [first, second], stateStore: store)
            defer { workspace.stopAll(); workspace.window?.close() }
            let source = try XCTUnwrap(columns(workspace).first)
            source.prompt.string = "Unsaved first draft"
            let drag = ChatTabDrag(sessionID: first.id, columnID: source.columnID)
            // Preview validation and cancellation never mutate tabs or create panes.
            XCTAssertTrue(workspace.canDropTab(drag, on: side))
            XCTAssertEqual(columns(workspace).count, 1)
            XCTAssertEqual(source.tabIDs, [first.id, second.id])
            XCTAssertTrue(workspace.dropTab(drag, on: side))
            let panes = columns(workspace)
            XCTAssertEqual(panes.count, 2)
            let target = panes[side == .left ? 0 : 1]
            let other = panes[side == .left ? 1 : 0]
            XCTAssertTrue(target.session === first)
            XCTAssertTrue(other.session === second)
            XCTAssertEqual(target.tabIDs, [first.id])
            XCTAssertEqual(other.tabIDs, [second.id])
            XCTAssertEqual(target.prompt.string, "Unsaved first draft")
            XCTAssertEqual(other.prompt.string, "Second draft")
            XCTAssertEqual(panes[0].view.frame.width, panes[1].view.frame.width, accuracy: 1)
            XCTAssertTrue(workspace.window?.firstResponder === target.prompt)
            workspace.stopAll()
            let restored = WorkspaceWindow(restoredSessions: [first, second], stateStore: store)
            defer { restored.stopAll(); restored.window?.close() }
            XCTAssertEqual(columns(restored).map(\.tabIDs), panes.map(\.tabIDs))
            XCTAssertEqual(columns(restored).map { $0.prompt.string }, panes.map { $0.prompt.string })
        }
    }

    @MainActor
    func testExistingPaneCanBeSplitAgainAndRejectsForeignDrag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let a = Session(project: root, title: "A", storageRoot: root)
        let b = Session(project: root, title: "B", storageRoot: root)
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(primary: a.id, secondary: b.id, primaryTabs: [a.id], secondaryTabs: [b.id])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [a, b], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        // Three usable panes now require enough room for their minimum widths.
        workspace.window?.setContentSize(NSSize(width: 1400, height: 1000))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let panes = columns(workspace)
        let drag = ChatTabDrag(sessionID: b.id, columnID: panes[1].columnID)
        XCTAssertTrue(workspace.canDropTab(drag, on: .right))
        XCTAssertFalse(workspace.dropTab(ChatTabDrag(sessionID: b.id, columnID: UUID()), on: .left))
        XCTAssertTrue(workspace.dropTab(drag, on: .left))
        XCTAssertEqual(panes[0].tabIDs, [a.id])
        XCTAssertTrue(panes[0].session === a)
        XCTAssertTrue(panes[1].tabIDs.isEmpty)
        XCTAssertNil(panes[1].session)
        XCTAssertEqual(columns(workspace).count, 3)
        XCTAssertTrue(columns(workspace)[1].session === b)
        let widths = columns(workspace).map { $0.view.frame.width }
        XCTAssertEqual(widths[0], widths[1], accuracy: 1)
        XCTAssertEqual(widths[1], widths[2], accuracy: 1)
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
