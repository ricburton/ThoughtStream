import AppKit
import XCTest
@testable import ThoughtStream

final class ProjectPaneWidthTests: XCTestCase {
    @MainActor
    func testMouseDragCanExpandPastTheCompactFloorOnBothAxes() throws {
        for vertical in [true, false] {
            let ids = (0..<6).map { _ in UUID() }
            let columns = ids.map { ChatColumn(id: $0) }
            let controller = PaneLayoutController(
                layout: PaneLayout.arranged(ids, as: vertical ? .columns : .rows)!,
                columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
                configureHost: { _, _ in }, resized: {})
            let canvas = PaneCanvasController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = canvas
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 800, height: 600))
            defer { window.close() }
            canvas.setLayout(controller)
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.fit()
            let split = try XCTUnwrap(controller.children.first as? NSSplitViewController).splitView
            let first = try XCTUnwrap(split.subviews.first)
            let original = vertical ? first.frame.width : first.frame.height
            let originalCanvas = vertical ? canvas.canvasSize.width : canvas.canvasSize.height
            let originalWindow = window.frame
            let point = vertical ? NSPoint(x: first.frame.maxX + 0.5, y: split.bounds.midY)
                : NSPoint(x: split.bounds.midX, y: first.frame.maxY + 0.5)
            let start = split.convert(point, to: nil)
            func event(_ type: NSEvent.EventType, delta: CGFloat) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: start.x + (vertical ? delta : 0), y: start.y + (vertical ? 0 : -delta)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            for delta: CGFloat in [40, 80, 120] {
                NSApp.postEvent(try event(.leftMouseDragged, delta: delta), atStart: false)
            }
            NSApp.postEvent(try event(.leftMouseUp, delta: 120), atStart: false)
            split.mouseDown(with: try event(.leftMouseDown, delta: 0))
            window.contentView?.layoutSubtreeIfNeeded()
            let resized = vertical ? first.frame.width : first.frame.height
            XCTAssertEqual(resized, original + 120, accuracy: 1, "The divider must follow the mouse at the compact floor")
            XCTAssertGreaterThan(vertical ? canvas.canvasSize.width : canvas.canvasSize.height, originalCanvas + 100)
            XCTAssertEqual(window.frame, originalWindow)
            XCTAssertTrue(canvas.hasCustomSizing)
            let saved = canvas.canvasSize
            for _ in 0..<5 { canvas.fit() }
            XCTAssertEqual(canvas.canvasSize, saved, "Passive layout must not keep expanding the canvas")
        }
    }

    @MainActor
    func testProjectRoundTripsPreserveNestedPaneWidths() throws {
        try checkProjectRoundTrip(paneCount: 9, drag: false)
        try checkProjectRoundTrip(paneCount: 3, drag: true)
        try checkProjectRoundTrip(paneCount: 9, drag: true)
        try checkProjectRoundTrip(paneCount: 9, drag: true, expand: true)
    }

    @MainActor
    private func checkProjectRoundTrip(paneCount: Int, drag: Bool, expand: Bool = false) throws {
        let originalStyle = InterfaceStyle.current
        defer { InterfaceStyle.current = originalStyle }
        InterfaceStyle.current = .roundedPanes
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let project = root.appendingPathComponent("A")
        let sessions = (0..<paneCount).map { Session(project: project, title: "Pane \($0)", storageRoot: root) }
        let other = Session(project: root.appendingPathComponent("B"), storageRoot: root)
        let ids = sessions.map { _ in UUID() }
        let layout: PaneLayout
        if paneCount == 3 {
            layout = .split(vertical: true, fraction: 0.25, first: .pane(ids[0]),
                second: .split(vertical: true, fraction: 0.6, first: .pane(ids[1]), second: .pane(ids[2])))
        } else {
            let tail = PaneLayout.split(vertical: false, fraction: 0.5, first: .pane(ids[7]), second: .pane(ids[8]))
            let four = PaneLayout.split(vertical: true, fraction: 0.5,
                first: .split(vertical: true, fraction: 0.5, first: .pane(ids[2]), second: .pane(ids[3])),
                second: .split(vertical: true, fraction: 0.5, first: .pane(ids[4]), second: .pane(ids[5])))
            let six = PaneLayout.split(vertical: true, fraction: 1.0 / 6, first: .pane(ids[0]),
                second: .split(vertical: true, fraction: 0.2, first: .pane(ids[1]), second: four))
            layout = .split(vertical: true, fraction: 0.875,
                first: .split(vertical: true, fraction: 6.0 / 7, first: six, second: .pane(ids[6])), second: tail)
        }
        store.save(WorkspaceSnapshot(selectedProject: project.path, projects: [
            project.path: ProjectViewState(layout: layout,
                panes: zip(ids, sessions).map { PaneViewState(id: $0.0, session: $0.1.id, tabs: [$0.1.id], tabOffset: 0) })
        ]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: sessions + [other], stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close() }
        func widths() -> [CGFloat] {
            func descend(_ controller: NSViewController) -> [ChatColumn] {
                if let column = controller as? ChatColumn { return [column] }
                return controller.children.flatMap(descend)
            }
            return window.contentViewController.map(descend)?.map { $0.view.frame.width } ?? []
        }
        window.setContentSize(NSSize(width: 2056, height: 1250))
        window.contentView?.layoutSubtreeIfNeeded()
        if drag {
            func findSplit(_ controller: NSViewController) -> NSSplitView? {
                if let controller = controller as? NSSplitViewController,
                   controller.splitViewItems.allSatisfy({ $0.viewController is PaneLayoutController }) {
                    return controller.splitView
                }
                return controller.children.compactMap(findSplit).first
            }
            let split = try XCTUnwrap(window.contentViewController.flatMap(findSplit))
            let before = widths()
            let frame = window.frame
            split.setPosition(expand ? split.bounds.width + 200 : split.bounds.width * 0.57, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(zip(before, widths()).contains { abs($0 - $1) > 10 },
                          "Dragging must actually resize panes, including an overflowing project")
            XCTAssertEqual(window.frame, frame, "Expanding panes must not resize the app window")
        }
        let expected = widths()
        XCTAssertEqual(expected.count, paneCount)
        for _ in 0..<3 {
            workspace.selectProject(other.project.path)
            workspace.selectProject(project.path)
            window.contentView?.layoutSubtreeIfNeeded()
            for (actual, saved) in zip(widths(), expected) {
                XCTAssertEqual(actual, saved, accuracy: 1, "Returning to the project must preserve its pane widths")
            }
        }
        // Saving while minimum widths clamp the layout must retain the wider layout's proportions.
        window.setContentSize(NSSize(width: 860, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.selectProject(other.project.path)
        workspace.selectProject(project.path)
        window.setContentSize(NSSize(width: 2056, height: 1250))
        window.contentView?.layoutSubtreeIfNeeded()
        for (actual, saved) in zip(widths(), expected) {
            XCTAssertEqual(actual, saved, accuracy: 1, "Temporary minimum widths must not overwrite the saved proportions")
        }
        // Verify the on-disk state too, using a new window and state store.
        workspace.stopAll()
        store.flush()
        let reopened = WorkspaceWindow(restoredSessions: sessions + [other],
            stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        let reopenedWindow = try XCTUnwrap(reopened.window)
        defer { reopened.stopAll(); reopenedWindow.close() }
        reopenedWindow.setContentSize(NSSize(width: 2056, height: 1250))
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        let restoredWidths = reopenedWindow.contentViewController.map(columns)?.map { $0.view.frame.width } ?? []
        XCTAssertEqual(restoredWidths.count, expected.count)
        for (actual, saved) in zip(restoredWidths, expected) {
            XCTAssertEqual(actual, saved, accuracy: 1, "Saved pane widths must survive reopening the workspace")
        }
    }

}
