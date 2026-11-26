import AppKit
import XCTest
@testable import ThoughtStream

final class PaneContentSizingTests: XCTestCase {
    @MainActor
    func testPopulatedNestedPanesRestoreBalancedWidthsAtEveryWindowSize() throws {
        let originalStyle = InterfaceStyle.current
        defer { InterfaceStyle.current = originalStyle }
        InterfaceStyle.current = .breathe
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<10).map { _ in UUID() }
        let chats = ids.indices.map { Session(project: root, title: "Pane \($0 + 1) conversation", storageRoot: root) }
        chats.forEach { $0.importSearchHistory(Sample.records) }
        func pair(_ index: Int) -> PaneLayout {
            .split(vertical: true, fraction: 0.5, first: .pane(ids[index]), second: .pane(ids[index + 1]))
        }
        let six = PaneLayout.split(vertical: true, fraction: 1.0 / 3, first: pair(1),
            second: .split(vertical: true, fraction: 0.5, first: pair(3), second: pair(5)))
        let seven = PaneLayout.split(vertical: true, fraction: 1.0 / 7, first: .pane(ids[0]), second: six)
        let eight = PaneLayout.split(vertical: true, fraction: 7.0 / 8, first: seven, second: .pane(ids[7]))
        let layout = PaneLayout.split(vertical: true, fraction: 8.0 / 9, first: eight,
            second: .split(vertical: false, fraction: 0.5, first: .pane(ids[8]), second: .pane(ids[9])))
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: ProjectViewState(
            layout: layout, panes: zip(ids, chats).map {
                PaneViewState(id: $0.0, session: $0.1.id, tabs: [$0.1.id], tabOffset: 0)
            }, focusedPane: ids[0])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close() }
        func descendants(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(descendants)
        }
        let controllers = descendants(try XCTUnwrap(window.contentViewController))
        let columns = controllers.compactMap { $0 as? ChatColumn }
        let canvas = try XCTUnwrap(controllers.compactMap { $0 as? PaneCanvasController }.first)
        XCTAssertEqual(columns.count, 10)
        columns[0].prompt.string = "Keep this draft while balancing the panes."
        for size in [NSSize(width: 2056, height: 1250), NSSize(width: 860, height: 600),
                     NSSize(width: 2056, height: 1250)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.fit()
            window.contentView?.layoutSubtreeIfNeeded()
            let expected = (canvas.canvasSize.width - 8) / 9 - 2 * PaneSurface.inset
            for column in columns {
                XCTAssertEqual(column.view.frame.width, expected, accuracy: 1,
                    "Populated nested panes must honor balanced widths, not their content's fitting size")
            }
            XCTAssertEqual(window.contentView?.bounds.size, size)
            XCTAssertEqual(columns[0].prompt.string, "Keep this draft while balancing the panes.")
        }
    }
}
