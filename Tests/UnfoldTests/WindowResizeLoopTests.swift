import AppKit
import XCTest
@testable import ThoughtStream

final class WindowResizeLoopTests: XCTestCase {
    @MainActor
    func testResizeCallbackCannotReenterLayout() {
        @MainActor final class Callback {
            weak var controller: PaneLayoutController?
            var active = false
            var reentries = 0
            var calls = 0
            func resized() {
                calls += 1
                if active { reentries += 1; return }
                active = true
                // NSWindow posts didResize synchronously when a callback changes
                // its minimum/frame. Bound the regression so a failure cannot hang.
                controller?.restoreFractions()
                active = false
            }
        }
        let callback = Callback()
        let a = ChatColumn(), b = ChatColumn()
        let controller = PaneLayoutController(layout: .split(vertical: true, fraction: 0.5,
            first: .pane(a.columnID), second: .pane(b.columnID)),
            columns: [a.columnID: a, b.columnID: b], configureHost: { _, _ in },
            resized: { callback.resized() })
        callback.controller = controller
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1200, height: 650))
        controller.restoreFractions()
        XCTAssertGreaterThan(callback.calls, 0)
        XCTAssertEqual(callback.reentries, 0, "A resize notification must not recursively run the same layout callback")
    }

    @MainActor
    func testFourPaneResizeKeepsMinimumStableAndAllowsSwitchingToTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<4).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let ids = chats.map { _ in UUID() }
        let layout = PaneLayout.split(vertical: true, fraction: 0.5,
            first: .split(vertical: true, fraction: 0.5, first: .pane(ids[0]), second: .pane(ids[1])),
            second: .split(vertical: true, fraction: 0.5, first: .pane(ids[2]), second: .pane(ids[3])))
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(windowFrame: "{{0, 689}, {1364, 600}}", selectedProject: root.path,
            projects: [root.path: ProjectViewState(layout: layout,
                panes: zip(ids, chats).map { PaneViewState(id: $0.0, session: $0.1.id, tabs: [$0.1.id], tabOffset: 0) })]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let minimum = window.minSize
        let start = ProcessInfo.processInfo.systemUptime
        for step in 0..<20 {
            let desired = NSRect(x: 0, y: 120, width: max(minimum.width, 1364) + CGFloat(step) * 0.5,
                                 height: max(minimum.height, 600) + CGFloat(step) * 0.5)
            window.setFrame(desired, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            workspace.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            XCTAssertEqual(window.minSize, minimum, "Resizing must not recalculate a new minimum from transient view geometry")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        workspace.setLayoutMode(.tabs)
        XCTAssertEqual(workspace.layoutMode, .tabs)
        XCTAssertEqual(window.minSize, NSSize(width: 860, height: 600))
    }
}
