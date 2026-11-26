import AppKit
import XCTest
@testable import ThoughtStream

final class PaneNavigationTests: XCTestCase {
    @MainActor
    func testCanvasLayoutFitSettlesAfterAppKitLayoutPass() {
        let originalStyle = InterfaceStyle.current
        defer { InterfaceStyle.current = originalStyle }
        InterfaceStyle.current = .breathe

        let columns = (0..<6).map { _ in ChatColumn() }
        let layout = PaneLayoutController(layout: PaneLayout.arranged(columns.map(\.columnID), as: .columns)!,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let canvas = PaneCanvasController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1364, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = canvas
        defer { window.close() }
        canvas.setLayout(layout)
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.fit()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let settledRevision = layout.layoutRevision
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        XCTAssertLessThanOrEqual(layout.layoutRevision - settledRevision, 1,
            "Canvas fitting must settle instead of restoring pane fractions during every layout pass")
    }

    @MainActor
    func testOverflowStripTracksScrollingAndReleasesSpaceWhenPanesFit() {
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

        let strip = canvas.horizontalNavigation
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(canvas.viewport.height, canvas.view.bounds.height - strip.frame.height, accuracy: 0.5)
        XCTAssertEqual(strip.scroller.doubleValue, 0, accuracy: 0.001)
        XCTAssertGreaterThan(strip.scroller.knobProportion, 0)
        XCTAssertLessThan(strip.scroller.knobProportion, 1)

        // Swiping over the footer also moves the panes and updates the thumb.
        XCTAssertTrue(canvas.scrollSideways(by: -100_000, over: strip.scroller))
        XCTAssertEqual(strip.scroller.doubleValue, 1, accuracy: 0.001)
        XCTAssertFalse(strip.isHidden, "Navigation remains visible at either end")

        // The native thumb can return to any position, independently of pane centers.
        strip.scroller.doubleValue = 0.5
        _ = strip.scroller.sendAction(strip.scroller.action, to: strip.scroller.target)
        XCTAssertEqual(canvas.visibleRect.minX, (canvas.canvasSize.width - canvas.viewport.width) / 2, accuracy: 0.5)
        let middle = canvas.visibleRect.minX
        XCTAssertTrue(canvas.scrollSideways(by: -100, over: strip.scroller))
        XCTAssertGreaterThan(canvas.visibleRect.minX, middle)
        let advanced = canvas.visibleRect.minX
        XCTAssertTrue(canvas.scrollSideways(by: 100, over: strip.scroller))
        XCTAssertLessThan(canvas.visibleRect.minX, advanced)

        let single = PaneLayoutController(layout: .pane(columns[0].columnID),
            columns: [columns[0].columnID: columns[0]], configureHost: { _, _ in }, resized: {})
        canvas.setLayout(single)
        canvas.fit()
        XCTAssertTrue(strip.isHidden)
        XCTAssertFalse(canvas.overflows.horizontal)
        XCTAssertEqual(canvas.viewport.height, canvas.view.bounds.height, accuracy: 0.5)
        XCTAssertEqual(canvas.visibleRect.minX, 0, accuracy: 0.5)
    }
}
