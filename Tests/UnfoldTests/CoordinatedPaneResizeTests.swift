import AppKit
import XCTest
@testable import ThoughtStream

final class CoordinatedPaneResizeTests: XCTestCase {
    @MainActor
    private final class Fixture {
        final class ResizeCounter { var count = 0 }
        let resizeCounter = ResizeCounter()
        let columns: [ChatColumn]
        let controller: PaneLayoutController
        let window: NSWindow
        init(ids: [UUID], layout: PaneLayout, size: NSSize) {
            let counter = resizeCounter
            columns = ids.map { ChatColumn(id: $0) }
            controller = PaneLayoutController(layout: layout,
                columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
                configureHost: { _, _ in }, resized: { counter.count += 1 })
            window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(size)
            controller.restoreFractions()
            controller.balance()
        }
        var splits: [NSSplitView] {
            func collect(_ node: NSViewController) -> [NSSplitView] {
                let split = (node as? NSSplitViewController).flatMap {
                    $0.splitViewItems.allSatisfy { $0.viewController is PaneLayoutController } ? $0.splitView : nil
                }
                return (split.map { [$0] } ?? []) + node.children.flatMap(collect)
            }
            return collect(controller)
        }
        func sizes(vertical: Bool) -> [CGFloat] {
            columns.map { vertical ? $0.view.superview!.bounds.width : $0.view.superview!.bounds.height }
        }
        func resize(_ size: NSSize) {
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
        }
        func close() { window.close() }
        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_PANE_PREVIEW"] else { return }
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func chain(_ ids: ArraySlice<UUID>, vertical: Bool) -> PaneLayout {
        guard ids.count > 1 else { return .pane(ids.first!) }
        return .split(vertical: vertical, fraction: 0.5, first: .pane(ids.first!), second: chain(ids.dropFirst(), vertical: vertical))
    }
    private func check(_ actual: [CGFloat], _ expected: [CGFloat], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 1, file: file, line: line) }
    }

    /// Exercise the real mouseDown tracking loop without activating a window or
    /// sending input to the main app. Each queued drag is processed synchronously.
    @MainActor
    private func drag(_ split: NSSplitView, fixture: Fixture, deltas: [CGFloat]) throws {
        let first = try XCTUnwrap(split.subviews.first)
        let start: NSPoint
        if split.isVertical { start = NSPoint(x: first.frame.maxX + 0.5, y: split.bounds.midY) }
        else { start = NSPoint(x: split.bounds.midX, y: first.frame.maxY + 0.5) }
        let location = split.convert(start, to: nil)
        func event(_ type: NSEvent.EventType, delta: CGFloat) throws -> NSEvent {
            let point = NSPoint(x: location.x + (split.isVertical ? delta : 0),
                               y: location.y + (split.isVertical ? 0 : -delta))
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let changesBefore = fixture.resizeCounter.count
        for delta in deltas { NSApp.postEvent(try event(.leftMouseDragged, delta: delta), atStart: false) }
        NSApp.postEvent(try event(.leftMouseUp, delta: deltas.last ?? 0), atStart: false)
        split.mouseDown(with: try event(.leftMouseDown, delta: 0))
        fixture.controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(fixture.resizeCounter.count - changesBefore, deltas.count,
                                    "Layout must update during dragging, not only on mouse-up")
    }

    @MainActor
    func testNestedMouseDragBalancesAllLanesInBothAxesAndKeepsContent() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        for style in [InterfaceStyle.standard, .roundedPanes] {
            InterfaceStyle.current = style
            for vertical in [true, false] {
                let ids = (0..<4).map { _ in UUID() }
                let fixture = Fixture(ids: ids, layout: chain(ids[...], vertical: vertical), size: NSSize(width: 2003, height: 2003))
                defer { fixture.close() }
                let column = fixture.columns[1]
                column.prompt.string = "Preserve draft and selection"
                column.prompt.setSelectedRange(NSRange(location: 9, length: 5))
                let fraction = column.conversationFraction
                let stream = column.stream
                check(fixture.sizes(vertical: vertical), [500, 500, 500, 500])
                // This is the deepest split: without coordination only panes 3
                // and 4 would resize. The first three must share 1,590 points.
                try drag(fixture.splits.last!, fixture: fixture, deltas: [20, 60, 90])
                check(fixture.sizes(vertical: vertical), [530, 530, 530, 410])
                XCTAssertTrue(column.stream === stream)
                XCTAssertEqual(column.prompt.string, "Preserve draft and selection")
                XCTAssertEqual(column.prompt.selectedRange(), NSRange(location: 9, length: 5))
                XCTAssertEqual(column.conversationFraction, fraction)
                XCTAssertEqual(fixture.controller.snapshot.ids, ids)
                // Resize the window: maintain the user's distribution, not the
                // binary tree's arbitrary nesting or a single stretchy pane.
                fixture.resize(NSSize(width: 2403, height: 2403))
                check(fixture.sizes(vertical: vertical), [636, 636, 636, 492])
                fixture.resize(NSSize(width: 1803, height: 1803))
                fixture.resize(NSSize(width: 2403, height: 2403))
                check(fixture.sizes(vertical: vertical), [636, 636, 636, 492])
                // All boundaries clamp at the content minimum plus style inset.
                let fitting = column.view.fittingSize
                let minimum = (vertical ? max(260, ceil(fitting.width)) : max(300, ceil(fitting.height)))
                    + (style == .roundedPanes ? 16 : 0)
                fixture.splits[0].setPosition(-1000, ofDividerAt: 0)
                XCTAssertEqual(fixture.sizes(vertical: vertical)[0], minimum, accuracy: 1)
                fixture.splits.last!.setPosition(10000, ofDividerAt: 0)
                XCTAssertEqual(fixture.sizes(vertical: vertical).last!, minimum, accuracy: 1)
            }
        }
    }

    @MainActor
    func testMatchingRowsStayAlignedAndInternalConversationSplitIsUntouched() throws {
        let ids = (0..<6).map { _ in UUID() }
        let layout = PaneLayout.split(vertical: false, fraction: 0.5,
            first: chain(ids[0..<3], vertical: true), second: chain(ids[3..<6], vertical: true))
        let fixture = Fixture(ids: ids, layout: layout, size: NSSize(width: 1502, height: 1001))
        defer { fixture.close() }
        try fixture.capture("coordinated-before")
        let rowSplit = try XCTUnwrap(fixture.splits.first { $0.isVertical })
        try drag(rowSplit, fixture: fixture, deltas: [-50, -100, -150])
        check(fixture.sizes(vertical: true), [350, 575, 575, 350, 575, 575])
        fixture.splits[0].setPosition(400, ofDividerAt: 0)
        check(fixture.sizes(vertical: false), [400, 400, 400, 600, 600, 600])
        check(fixture.sizes(vertical: true), [350, 575, 575, 350, 575, 575])
        try fixture.capture("coordinated-after")
        fixture.columns[0].setConversationFraction(0.3)
        XCTAssertEqual(fixture.columns[0].conversationFraction, 0.3, accuracy: 0.001)
        check(fixture.sizes(vertical: true), [350, 575, 575, 350, 575, 575])
        fixture.controller.balance()
        check(fixture.sizes(vertical: true), Array(repeating: 500, count: 6))
        check(fixture.sizes(vertical: false), Array(repeating: 500, count: 6))
    }

    @MainActor
    func testBalancedTreeAndPersistedFractionsPreserveDistribution() throws {
        let ids = (0..<4).map { _ in UUID() }
        let layout = PaneLayout.split(vertical: true, fraction: 0.5,
            first: chain(ids[0..<2], vertical: true), second: chain(ids[2..<4], vertical: true))
        let fixture = Fixture(ids: ids, layout: layout, size: NSSize(width: 1603, height: 900))
        defer { fixture.close() }
        fixture.splits[0].setPosition(701, ofDividerAt: 0)
        check(fixture.sizes(vertical: true), [350, 350, 450, 450])
        // Restore in a fresh controller to verify persisted fractions independently.
        let columns = ids.map { ChatColumn(id: $0) }
        let controller = PaneLayoutController(layout: fixture.controller.snapshot,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1603, height: 900)); controller.restoreFractions()
        check(columns.map { $0.view.superview!.bounds.width }, [350, 350, 450, 450])
    }

    func testMinimumAllocationAndRecovery() {
        check(PaneSizing.shares(total: 1200, weights: [1, 3, 3], minima: [260, 260, 260]), [260, 470, 470])
        check(PaneSizing.shares(total: 900, weights: [1, 1, 1], minima: [500, 100, 100]), [500, 200, 200])
        check(PaneSizing.shares(total: 300, weights: [1, 1], minima: [260, 260]), [150, 150])
    }
}
