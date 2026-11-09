import AppKit
import XCTest
@testable import ThoughtStream

final class PaneLimitsTests: XCTestCase {
    func testColumnAndRowCapsIncludeNestedSplits() {
        for (vertical, limit) in [(true, 12), (false, 6)] {
            var layout = PaneLayout.pane(UUID())
            for _ in 1..<limit {
                let target = layout.ids.last!
                XCTAssertTrue(layout.permitsSplit(of: target, vertical: vertical))
                layout = layout.replacing(target, with: .split(vertical: vertical, fraction: 0.5,
                                                               first: .pane(target), second: .pane(UUID())))
            }
            XCTAssertFalse(layout.permitsSplit(of: layout.ids.last!, vertical: vertical))
            XCTAssertTrue(layout.permitsSplit(of: layout.ids.last!, vertical: !vertical))
        }
    }

    func testWindowCapacityAndClosingRestoreRoom() {
        let id = UUID(), next = UUID()
        let single = PaneLayout.pane(id)
        XCTAssertFalse(single.permitsSplit(of: id, vertical: false, availableSize: NSSize(width: 900, height: 600)))
        XCTAssertTrue(single.permitsSplit(of: id, vertical: false, availableSize: NSSize(width: 900, height: 601)))
        let stacked = single.replacing(id, with: .split(vertical: false, fraction: 0.5, first: .pane(id), second: .pane(next)))
        XCTAssertFalse(stacked.permitsSplit(of: next, vertical: false, availableSize: NSSize(width: 900, height: 800)))
        XCTAssertTrue(stacked.removing(next)!.permitsSplit(of: id, vertical: false, availableSize: NSSize(width: 900, height: 800)))
        XCTAssertFalse(single.permitsSplit(of: UUID(), vertical: true))
    }

    @MainActor
    func testRepeatedStackingStopsAndDisablesAllEntryPoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [original], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        func panes(_ controller: NSViewController) -> [ChatColumn] {
            (controller as? ChatColumn).map { [$0] } ?? controller.children.flatMap(panes)
        }
        let window = try XCTUnwrap(workspace.window)
        let controller = try XCTUnwrap(window.contentViewController)
        var created: [Session] = []
        defer {
            workspace.stopAll(); window.close()
            for session in created { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(session.id.uuidString)) }
            try? FileManager.default.removeItem(at: root)
        }
        window.setContentSize(NSSize(width: 1400, height: 1400))
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<20 { workspace.stackStream(nil) }
        let current = panes(controller)
        created = current.compactMap(\.session).filter { $0 !== original }
        XCTAssertGreaterThan(current.count, 1)
        XCTAssertLessThanOrEqual(current.count, 6)
        let last = try XCTUnwrap(current.last)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let stack = try XCTUnwrap(views(last.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Stack pane below" })
        XCTAssertFalse(stack.isEnabled)
        let menu = NSMenuItem(title: "Stack", action: #selector(WorkspaceWindow.stackStream(_:)), keyEquivalent: "")
        XCTAssertFalse(workspace.validateMenuItem(menu))
        let first = try XCTUnwrap(current.first)
        XCTAssertFalse(workspace.canDropTab(ChatTabDrag(sessionID: original.id, columnID: first.columnID), on: .bottom, in: last))
        XCTAssertFalse(workspace.dropTab(ChatTabDrag(sessionID: original.id, columnID: first.columnID), on: .bottom, in: last))
        XCTAssertEqual(first.tabIDs, [original.id])
        XCTAssertEqual(panes(controller).count, current.count)
        workspace.closeFocusedPane(nil)
        XCTAssertTrue(workspace.validateMenuItem(menu))
    }
}
