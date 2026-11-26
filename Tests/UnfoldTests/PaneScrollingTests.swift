import AppKit
import XCTest
@testable import ThoughtStream

final class PaneScrollingTests: XCTestCase {
    func testZeroMovementStartWaitsForDirectionAndKeepsMomentum() {
        var gesture = PaneScrollGesture()
        XCTAssertNil(gesture.distance(x: 0, y: 0, phase: .mayBegin, momentum: [], shift: false, precise: true))
        XCTAssertNil(gesture.distance(x: 0, y: 0, phase: .began, momentum: [], shift: false, precise: true))
        XCTAssertEqual(gesture.distance(x: -18, y: 1, phase: .changed, momentum: [], shift: false, precise: true), -18)
        XCTAssertEqual(gesture.distance(x: -3, y: 8, phase: .changed, momentum: [], shift: false, precise: true), -3)
        XCTAssertNil(gesture.distance(x: 0, y: 0, phase: .ended, momentum: [], shift: false, precise: true))
        XCTAssertEqual(gesture.distance(x: -7, y: 2, phase: [], momentum: .began, shift: false, precise: true), -7)
        XCTAssertEqual(gesture.distance(x: -2, y: 0, phase: [], momentum: .ended, shift: false, precise: true), -2)
        XCTAssertNil(gesture.distance(x: 1, y: 8, phase: .began, momentum: [], shift: false, precise: true))
        XCTAssertNil(gesture.distance(x: 20, y: 1, phase: .changed, momentum: [], shift: false, precise: true))
    }

    func testShiftWheelAcceptsBothNativeAndUnmappedDeltasWithoutDoubling() {
        var gesture = PaneScrollGesture()
        XCTAssertEqual(gesture.distance(x: 0, y: -3, phase: [], momentum: [], shift: true, precise: false), -36)
        XCTAssertEqual(gesture.distance(x: 3, y: 0, phase: [], momentum: [], shift: true, precise: false), 36)
        XCTAssertEqual(gesture.distance(x: 3, y: 3, phase: [], momentum: [], shift: true, precise: false), 36)
        XCTAssertNil(gesture.distance(x: 0, y: -3, phase: [], momentum: [], shift: false, precise: false))
        XCTAssertEqual(gesture.distance(x: -4, y: 0, phase: [], momentum: [], shift: false, precise: false), -48)
    }

    @MainActor
    func testSixPanesScrollBothWaysAndNestedContentHandsOffAtEdges() throws {
        let columns = (0..<6).map { _ in ChatColumn() }
        let layout = PaneLayoutController(layout: PaneLayout.arranged(columns.map(\.columnID), as: .columns)!,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let canvas = PaneCanvasController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2600, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = canvas
        defer { window.close() }
        window.setContentSize(NSSize(width: 2600, height: 700))
        canvas.setLayout(layout)
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        XCTAssertTrue(canvas.overflows.horizontal)

        for column in columns {
            for surface in [column.view, column.stream.view, column.conversation.scroll, column.prompt] {
                let before = canvas.visibleRect.origin
                XCTAssertTrue(canvas.scrollSideways(by: -50, over: surface))
                XCTAssertEqual(canvas.visibleRect.minX, before.x + 50, accuracy: 0.5)
                XCTAssertEqual(canvas.visibleRect.minY, before.y)
                XCTAssertTrue(canvas.scrollSideways(by: 50, over: surface))
                XCTAssertEqual(canvas.visibleRect.minX, before.x, accuracy: 0.5)
            }
        }
        XCTAssertFalse(canvas.scrollSideways(by: -50, over: NSView()), "Unrelated views cannot move the canvas")

        let inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        inner.documentView = document
        columns[0].view.addSubview(inner)
        XCTAssertFalse(canvas.scrollSideways(by: -50, over: document), "Wide local content scrolls first")
        inner.contentView.scroll(to: NSPoint(x: 200, y: 0))
        XCTAssertTrue(canvas.scrollSideways(by: -50, over: document), "At the right edge, reach the next panes")
        XCTAssertEqual(canvas.visibleRect.minX, 50, accuracy: 0.5)
        XCTAssertFalse(canvas.scrollSideways(by: 50, over: document), "Reversing direction scrolls local content first")
        inner.contentView.scroll(to: .zero)
        XCTAssertTrue(canvas.scrollSideways(by: 50, over: document), "At the left edge, reach previous panes")
        XCTAssertEqual(canvas.visibleRect.minX, 0, accuracy: 0.5)
    }
}
