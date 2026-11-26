import AppKit
import XCTest
@testable import ThoughtStream

final class RebalanceColumnsTests: XCTestCase {
    func testRebalanceWidthFitsFiveColumnsAcrossViewport() {
        for width: CGFloat in [600, 900, 1600, 3409] {
            for inset: CGFloat in [0, 8] {
                let column = PaneLayout.rebalancedColumnWidth(viewport: NSSize(width: width, height: 700), paneInset: inset)
                XCTAssertEqual(5 * (column + 2 * inset) + 4, width, accuracy: 0.001)
            }
        }
    }

    @MainActor
    func testButtonShrinksColumnsAndPersistsAcrossResizeAndRestore() throws {
        let oldStyle = InterfaceStyle.current
        InterfaceStyle.current = .roundedPanes
        defer { InterfaceStyle.current = oldStyle }
        for count in [1, 3, 5, 6, 12] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
            let sessions = (0..<count).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
            let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
            let window = try XCTUnwrap(workspace.window)
            defer { workspace.stopAll(); window.close() }
            window.setContentSize(NSSize(width: 1800, height: 1000))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func controllers(_ controller: NSViewController) -> [NSViewController] {
                [controller] + controller.children.flatMap(controllers)
            }
            let buttons = views(content).compactMap { $0 as? AddPaneButton }
            let settings = try XCTUnwrap(buttons.first { $0.title == "Settings" })
            let button = try XCTUnwrap(buttons.first { $0.title == "Rebalance" })
            // Rebalance opens the view section, set apart from the app section that Settings closes.
            XCTAssertEqual(button.frame.minX, settings.frame.maxX + WorkspaceHeaderRow.sectionSpacing, accuracy: 0.5)
            XCTAssertEqual(button.frame.minY, settings.frame.minY, accuracy: 0.5)
            XCTAssertEqual(button.symbolName, "rectangle.split.3x1")
            XCTAssertNotNil(NSImage(systemSymbolName: button.symbolName, accessibilityDescription: nil))
            XCTAssertTrue(button.isEnabled)
            let canvas = try XCTUnwrap(window.contentViewController.map(controllers)?.compactMap { $0 as? PaneCanvasController }.first)
            let columns = try XCTUnwrap(window.contentViewController).children.flatMap(controllers).compactMap { $0 as? ChatColumn }
            columns.first?.prompt.string = "Keep this draft"
            let originalWindow = window.frame
            button.performClick(nil)
            for _ in 0..<3 { canvas.fit(); content.layoutSubtreeIfNeeded() }
            XCTAssertEqual(columns.count, count)
            for column in columns { XCTAssertEqual(column.view.frame.width, (canvas.viewport.width - 4) / 5 - 2 * PaneSurface.inset, accuracy: 1) }
            XCTAssertEqual(columns.first?.prompt.string, "Keep this draft")
            XCTAssertEqual(window.frame, originalWindow)
            XCTAssertEqual(canvas.overflows.horizontal, count > 5)
            window.setContentSize(NSSize(width: 900, height: 900))
            content.layoutSubtreeIfNeeded()
            canvas.fit()
            for column in columns { XCTAssertEqual(column.view.frame.width, (canvas.viewport.width - 4) / 5 - 2 * PaneSurface.inset, accuracy: 1) }
            XCTAssertEqual(canvas.overflows.horizontal, count > 5)
            if count == 3 {
                let header = try XCTUnwrap(button.superview)
                let bitmap = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: header.bounds))
                header.cacheDisplay(in: header.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/thoughtstream-rebalance-header.png"))
            }
            workspace.stopAll(); store.flush()
            let restored = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
            defer { restored.stopAll(); restored.window?.close() }
            restored.window?.setContentSize(NSSize(width: 1800, height: 1000))
            restored.window?.contentView?.layoutSubtreeIfNeeded()
            let restoredColumns = restored.window?.contentViewController.map(controllers)?.compactMap { $0 as? ChatColumn } ?? []
            XCTAssertEqual(restoredColumns.count, count)
            let restoredCanvas = try XCTUnwrap(restored.window?.contentViewController.map(controllers)?.compactMap { $0 as? PaneCanvasController }.first)
            for column in restoredColumns {
                XCTAssertEqual(column.view.frame.width, (restoredCanvas.viewport.width - 4) / 5 - 2 * PaneSurface.inset, accuracy: 1)
            }
        }
    }

    @MainActor
    func testRebalancePreservesStackHeights() throws {
        let ids = (0..<4).map { _ in UUID() }
        let model = PaneLayout.split(vertical: false, fraction: 0.35,
            first: .split(vertical: true, fraction: 0.7, first: .pane(ids[0]), second: .pane(ids[1])),
            second: .split(vertical: true, fraction: 0.6, first: .pane(ids[2]), second: .pane(ids[3])))
        let columns = ids.map { ChatColumn(id: $0) }
        let layout = PaneLayoutController(layout: model,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let canvas = PaneCanvasController()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = canvas
        window.setContentSize(NSSize(width: 1800, height: 1000))
        canvas.setLayout(layout)
        window.contentView?.layoutSubtreeIfNeeded()
        let heights = columns.map { $0.view.frame.height }
        canvas.shrinkColumnsToMinimum()
        for (column, height) in zip(columns, heights) {
            let inset = InterfaceStyle.hasRoundedPanes ? PaneSurface.inset : 0
            XCTAssertEqual(column.view.frame.width, (canvas.viewport.width - 4) / 5 - 2 * inset, accuracy: 1)
            XCTAssertEqual(column.view.frame.height, height, accuracy: 1)
        }
    }
}
