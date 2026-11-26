import AppKit
import XCTest
@testable import ThoughtStream

final class PaneExpansionTests: XCTestCase {
    @MainActor
    func testExpandingMiddlePanePreservesUnequalNeighborsAndScrolls() throws {
        let ids = (0..<4).map { _ in UUID() }
        let model = PaneLayout.split(vertical: true, fraction: 0.3, first: .pane(ids[0]),
            second: .split(vertical: true, fraction: 0.4, first: .pane(ids[1]),
                second: .split(vertical: true, fraction: 0.5, first: .pane(ids[2]), second: .pane(ids[3]))))
        try checkExpansion(model, ids: ids, target: 1)
    }

    @MainActor
    func testExpansionInsideStackPreservesNeighborOutsideStack() throws {
        let ids = (0..<4).map { _ in UUID() }
        let model = PaneLayout.split(vertical: true, fraction: 0.65,
            first: .split(vertical: false, fraction: 0.5,
                first: .split(vertical: true, fraction: 0.5, first: .pane(ids[0]), second: .pane(ids[1])),
                second: .pane(ids[2])), second: .pane(ids[3]))
        try checkExpansion(model, ids: ids, target: 0, preserved: [1, 3])
    }

    @MainActor
    func testSixInitialPanesUseOneFifthOfVisibleArea() throws {
        let ids = (0..<6).map { _ in UUID() }
        try withCanvas(PaneLayout.arranged(ids, as: .columns)!, ids: ids) { canvas, controller, _ in
            XCTAssertFalse(canvas.hasCustomSizing)
            XCTAssertTrue(canvas.overflows.horizontal)
            for pane in controller.paneViews {
                XCTAssertEqual(pane.frame.width, (canvas.viewport.width - 4) / 5, accuracy: 1)
            }
        }
    }

    @MainActor
    func testAlignedRowsExpandTogetherWithoutSqueezingTheirNeighbors() throws {
        let ids = (0..<4).map { _ in UUID() }
        let model = PaneLayout.split(vertical: false, fraction: 0.5,
            first: .split(vertical: true, fraction: 0.5, first: .pane(ids[0]), second: .pane(ids[1])),
            second: .split(vertical: true, fraction: 0.5, first: .pane(ids[2]), second: .pane(ids[3])))
        try withCanvas(model, ids: ids) { canvas, controller, window in
            let rows = try XCTUnwrap(controller.children.first as? NSSplitViewController)
            let row = try XCTUnwrap(rows.splitViewItems.first?.viewController as? PaneLayoutController)
            let split = try XCTUnwrap(row.children.first as? NSSplitViewController).splitView
            let before = controller.paneViews.map { $0.frame.width }
            split.setPosition(before[0] + 150, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.fit()
            for (index, pane) in controller.paneViews.enumerated() {
                XCTAssertEqual(pane.frame.width, before[index] + (index.isMultiple(of: 2) ? 150 : 0), accuracy: 1)
            }
        }
    }

    @MainActor
    private func checkExpansion(_ model: PaneLayout, ids: [UUID], target: Int, preserved: [Int]? = nil) throws {
        try withCanvas(model, ids: ids) { canvas, controller, window in
            @MainActor func splits(_ node: NSViewController) -> [NSSplitViewController] {
                (node as? NSSplitViewController).map { [$0] + node.children.flatMap(splits) }
                    ?? node.children.flatMap(splits)
            }
            let panes = controller.paneViews
            let split = try XCTUnwrap(splits(controller).first {
                $0.splitView.isVertical && $0.splitViewItems.first?.viewController.view === panes[target]
            }?.splitView)
            @MainActor func frames() -> [NSRect] { panes.map { controller.view.convert($0.bounds, from: $0) } }
            let before = frames()
            let originalCanvas = canvas.canvasSize.width
            let originalWindow = window.frame
            let startWidth = try XCTUnwrap(split.subviews.first).frame.width
            for delta: CGFloat in [40, 80, 120, 120] {
                split.setPosition(startWidth + delta, ofDividerAt: 0)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            for _ in 0..<5 { canvas.fit() }
            let after = frames()
            XCTAssertEqual(after[target].width, before[target].width + 120, accuracy: 1)
            for index in preserved ?? ids.indices.filter({ $0 != target }) {
                XCTAssertEqual(after[index].width, before[index].width, accuracy: 1)
                XCTAssertEqual(after[index].minX, before[index].minX + (index > target ? 120 : 0), accuracy: 1)
            }
            XCTAssertEqual(canvas.canvasSize.width, originalCanvas + 120, accuracy: 1)
            XCTAssertEqual(window.frame, originalWindow)
            XCTAssertTrue(canvas.overflows.horizontal)
        }
    }

    @MainActor
    private func withCanvas(_ model: PaneLayout, ids: [UUID],
                            check: @MainActor (PaneCanvasController, PaneLayoutController, NSWindow) throws -> Void) throws {
        let columns = ids.map { ChatColumn(id: $0) }
        let controller = PaneLayoutController(layout: model,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let canvas = PaneCanvasController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2004, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = canvas
        defer { window.close() }
        window.setContentSize(NSSize(width: 2004, height: 900))
        canvas.setLayout(controller)
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        try check(canvas, controller, window)
    }
}
