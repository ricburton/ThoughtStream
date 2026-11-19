import AppKit
import XCTest
@testable import ThoughtStream

/// Panes are unlimited. They compact to an adaptive minimum, then the pane
/// area scrolls; nothing ever refuses a split or grows the window.
final class PaneLimitsTests: XCTestCase {
    func testAnyNumberOfColumnsAndRowsCanBeSplit() {
        for vertical in [true, false] {
            var layout = PaneLayout.pane(UUID())
            for _ in 1..<40 {
                let target = layout.ids.last!
                XCTAssertTrue(layout.permitsSplit(of: target))
                layout = layout.replacing(target, with: .split(vertical: vertical, fraction: 0.5,
                                                               first: .pane(target), second: .pane(UUID())))
            }
            XCTAssertEqual(vertical ? layout.dimensions.columns : layout.dimensions.rows, 40)
            XCTAssertTrue(layout.permitsSplit(of: layout.ids.last!))
            XCTAssertFalse(layout.permitsSplit(of: UUID()), "Only a pane in this layout can be split")
        }
    }

    func testMinimumBreathesWithTheDisplayAndStopsAtTheCompactFloor() {
        // A big display shares its width between ten columns and its height between five rows.
        let large = PaneLayout.adaptiveMinimum(viewport: NSSize(width: 3409, height: 1404))
        XCTAssertEqual(large.width, 340)
        XCTAssertEqual(large.height, 280)
        // A cramped one stops at the compact floor instead of an unreadable sliver.
        let small = PaneLayout.adaptiveMinimum(viewport: NSSize(width: 1100, height: 700))
        XCTAssertEqual(small, PaneLayout.compactPaneSize)
        XCTAssertLessThan(PaneLayout.compactPaneSize.width, PaneLayout.minimumPaneSize.width)
        // Rounded panes spend their inset from the same share.
        XCTAssertEqual(PaneLayout.adaptiveMinimum(viewport: NSSize(width: 3409, height: 1404), paneInset: 8).width, 324)
        XCTAssertEqual(PaneLayout.adaptiveMinimum(viewport: .zero), PaneLayout.compactPaneSize)
    }

    func testTenColumnsFitAndTheEleventhScrolls() {
        let viewport = NSSize(width: 2600, height: 1200)
        let minimum = PaneLayout.adaptiveMinimum(viewport: viewport)
        func columns(_ count: Int) -> PaneLayout { PaneLayout.arranged((0..<count).map { _ in UUID() }, as: .columns)! }
        XCTAssertLessThanOrEqual(columns(10).minimumSize(paneInset: 0, paneMinimum: minimum).width, viewport.width)
        XCTAssertGreaterThan(columns(11).minimumSize(paneInset: 0, paneMinimum: minimum).width, viewport.width)
        XCTAssertLessThanOrEqual(columns(11).minimumSize(paneInset: 0, paneMinimum: minimum).height, viewport.height)
    }

    func testArrangementsKeepEveryPaneInOrder() {
        let ids = (0..<23).map { _ in UUID() }
        for arrangement in PaneArrangement.allCases {
            let layout = PaneLayout.arranged(ids, as: arrangement, viewport: NSSize(width: 1800, height: 1000))
            XCTAssertEqual(layout?.ids, ids, arrangement.rawValue)
        }
        XCTAssertEqual(PaneLayout.arranged(ids, as: .columns)?.dimensions.columns, 23)
        XCTAssertEqual(PaneLayout.arranged(ids, as: .columns)?.dimensions.rows, 1)
        XCTAssertEqual(PaneLayout.arranged(ids, as: .rows)?.dimensions.rows, 23)
        XCTAssertNil(PaneLayout.arranged([], as: .grid))
        XCTAssertEqual(PaneLayout.arranged([ids[0]], as: .grid), .pane(ids[0]))
    }

    func testGridShapeFollowsTheDisplay() {
        // A wide display lays six panes out wider than a tall one does.
        let wide = PaneLayout.gridColumns(count: 6, viewport: NSSize(width: 2400, height: 900))
        let tall = PaneLayout.gridColumns(count: 6, viewport: NSSize(width: 900, height: 1600))
        XCTAssertGreaterThan(wide, tall)
        XCTAssertEqual(PaneLayout.gridColumns(count: 1, viewport: NSSize(width: 1000, height: 800)), 1)
        // Even an absurd number of panes stays a grid, not one endless row.
        let many = PaneLayout.gridColumns(count: 200, viewport: NSSize(width: 1800, height: 1000))
        XCTAssertGreaterThan(many, 4)
        XCTAssertLessThan(many, 60)
        XCTAssertEqual(PaneLayout.gridColumns(count: 9, viewport: .zero), 3)
    }

    func testDensityCompactsBelowTheComfortableWidthWithHysteresis() {
        XCTAssertEqual(PaneDensity.resolve(size: NSSize(width: 900, height: 800)), .regular)
        let snug = PaneDensity.resolve(size: NSSize(width: 300, height: 800))
        XCTAssertEqual(snug.width, .snug)
        XCTAssertEqual(snug.textScale, 1, "Chrome compacts before text does")
        XCTAssertTrue(snug.hasCompactChrome)
        let tiny = PaneDensity.resolve(size: NSSize(width: 172, height: 800))
        XCTAssertEqual(tiny.width, .tiny)
        XCTAssertLessThan(tiny.textScale, PaneDensity.resolve(size: NSSize(width: 240, height: 800), current: tiny).textScale)
        // Hovering on a boundary does not flip back and forth.
        let compact = PaneDensity(width: .compact)
        XCTAssertEqual(PaneDensity.resolve(size: NSSize(width: 264, height: 800), current: compact).width, .compact)
        XCTAssertEqual(PaneDensity.resolve(size: NSSize(width: 276, height: 800), current: compact).width, .snug)
        XCTAssertEqual(PaneDensity.resolve(size: NSSize(width: 256, height: 800), current: PaneDensity(width: .snug)).width, .snug)
        // Short panes drop the conversation; they get it back with some slack.
        XCTAssertTrue(PaneDensity.resolve(size: NSSize(width: 600, height: 300)).isShort)
        XCTAssertFalse(PaneDensity.resolve(size: NSSize(width: 600, height: 375)).isShort)
        XCTAssertTrue(PaneDensity.resolve(size: NSSize(width: 600, height: 385), current: PaneDensity(isShort: true)).isShort)
        XCTAssertFalse(PaneDensity.resolve(size: NSSize(width: 600, height: 400), current: PaneDensity(isShort: true)).isShort)
    }

    func testRevealMovesTheLeastAndAlignsOversizedPanes() {
        let visible = NSRect(x: 400, y: 0, width: 1000, height: 600)
        XCTAssertEqual(PaneCanvasController.origin(revealing: NSRect(x: 500, y: 0, width: 300, height: 600), visible: visible), visible.origin)
        XCTAssertEqual(PaneCanvasController.origin(revealing: NSRect(x: 1300, y: 0, width: 300, height: 600), visible: visible).x, 600)
        XCTAssertEqual(PaneCanvasController.origin(revealing: NSRect(x: 100, y: 0, width: 300, height: 600), visible: visible).x, 100)
        XCTAssertEqual(PaneCanvasController.origin(revealing: NSRect(x: 900, y: 0, width: 1400, height: 600), visible: visible).x, 900)
    }

    @MainActor
    func testCanvasScrollsInsteadOfGrowingTheWindow() throws {
        let ids = (0..<14).map { _ in UUID() }
        let columns = Dictionary(uniqueKeysWithValues: ids.map { ($0, ChatColumn(id: $0)) })
        let layout = PaneLayoutController(layout: PaneLayout.arranged(ids, as: .columns)!, columns: columns,
                                          configureHost: { _, _ in }, resized: {})
        let canvas = PaneCanvasController()
        // Borderless, so the test can make it wider than any attached display.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = canvas
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1400, height: 700))
        canvas.setLayout(layout)
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        XCTAssertEqual(canvas.viewport.width, 1400, accuracy: 1)
        XCTAssertTrue(canvas.overflows.horizontal)
        XCTAssertFalse(canvas.overflows.vertical)
        let minimum = PaneLayout.adaptiveMinimum(viewport: canvas.viewport)
        XCTAssertEqual(canvas.canvasSize.width, 14 * minimum.width + 13, accuracy: 2)
        for view in layout.paneViews {
            XCTAssertEqual(view.frame.width, minimum.width, accuracy: 1, "Every pane gets exactly the adaptive minimum: none squeezed, none pushed wider by its contents")
        }
        // Compact chrome fits the narrow pane without breaking its layout.
        let narrow = try XCTUnwrap(columns[ids[0]])
        narrow.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(narrow.density.hasCompactChrome)
        // The last pane is off-screen until it is revealed.
        let last = try XCTUnwrap(layout.paneViews.last)
        XCTAssertLessThan(canvas.visibleRect.maxX, canvas.canvasSize.width - 100)
        canvas.reveal(last, animated: false)
        XCTAssertEqual(canvas.visibleRect.maxX, canvas.canvasSize.width, accuracy: 1)
        // A bigger window lets every pane breathe: wider panes, regular chrome and text.
        window.setContentSize(NSSize(width: 4200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        let roomy = PaneLayout.adaptiveMinimum(viewport: canvas.viewport)
        XCTAssertGreaterThan(roomy.width, 400)
        for view in layout.paneViews { XCTAssertEqual(view.frame.width, roomy.width, accuracy: 1) }
        narrow.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(narrow.density, .regular)
        XCTAssertTrue(canvas.overflows.horizontal, "Fourteen columns still scroll: ten share the pane area")
        // Ten columns fit without scrolling.
        let ten = Array(ids.prefix(10))
        for column in columns.values { column.view.removeFromSuperview(); column.removeFromParent() }
        canvas.setLayout(PaneLayoutController(layout: PaneLayout.arranged(ten, as: .columns)!, columns: columns,
                                              configureHost: { _, _ in }, resized: {}))
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        XCTAssertFalse(canvas.overflows.horizontal)
        XCTAssertEqual(canvas.visibleRect.minX, 0)
    }

    @MainActor
    func testRepeatedSplittingNeverStopsAndLeavesTheWindowAlone() throws {
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
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        let minimum = window.minSize
        for _ in 0..<8 { workspace.stackStream(nil) }
        for _ in 0..<12 { workspace.splitStream(nil) }
        let current = panes(controller)
        created = current.compactMap(\.session).filter { $0 !== original }
        XCTAssertEqual(current.count, 21, "Every split adds a pane: far past the old limit of six rows")
        XCTAssertEqual(window.minSize, minimum, "Panes never force the window larger")
        XCTAssertEqual(window.minSize, NSSize(width: 860, height: 600))
        let last = try XCTUnwrap(current.last)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let stack = try XCTUnwrap(views(last.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Stack pane below" })
        XCTAssertTrue(stack.isEnabled)
        let menu = NSMenuItem(title: "Stack", action: #selector(WorkspaceWindow.stackStream(_:)), keyEquivalent: "")
        XCTAssertTrue(workspace.validateMenuItem(menu))
        let first = try XCTUnwrap(current.first)
        XCTAssertTrue(workspace.canDropTab(ChatTabDrag(sessionID: original.id, columnID: first.columnID), on: .bottom, in: last))
        // Tidying keeps every pane and its chat.
        let before = Set(current.map(\.columnID))
        workspace.arrangePanes(as: .grid)
        let tidy = panes(controller)
        XCTAssertEqual(Set(tidy.map(\.columnID)), before)
        XCTAssertEqual(tidy.compactMap(\.session).count, current.count)
        workspace.closeFocusedPane(nil)
        XCTAssertEqual(panes(controller).count, current.count - 1)
    }
}
