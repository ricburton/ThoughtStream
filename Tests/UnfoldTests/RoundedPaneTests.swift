import AppKit
import XCTest
@testable import ThoughtStream

final class RoundedPaneTests: XCTestCase {
    @MainActor
    func testNestedPanesInsetAndRestoreWithoutReplacingContent() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        InterfaceStyle.current = .standard
        let columns = (0..<3).map { _ in ChatColumn() }
        let ids = columns.map(\.columnID)
        let layout = PaneLayout.split(vertical: true, fraction: 0.5, first: .pane(ids[0]),
            second: .split(vertical: false, fraction: 0.5, first: .pane(ids[1]), second: .pane(ids[2])))
        let controller = PaneLayoutController(layout: layout,
            columns: Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) }),
            configureHost: { _, _ in }, resized: {})
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1400, height: 1100))
        controller.restoreFractions()
        columns[0].prompt.string = "Keep this draft while changing styles."
        let prompt = columns[0].prompt

        for style in [InterfaceStyle.roundedPanes, .matrix, .standard, .roundedPanes] {
            InterfaceStyle.current = style
            controller.applyInterfaceStyle()
            columns.forEach { $0.applyInterfaceStyle() }
            controller.view.layoutSubtreeIfNeeded()
            let inset: CGFloat = style == .roundedPanes ? 8 : 0
            for column in columns {
                let host = try XCTUnwrap(column.view.superview as? TabSplitHostView)
                XCTAssertEqual(column.view.frame.minX, inset, accuracy: 0.5)
                XCTAssertEqual(column.view.frame.minY, inset, accuracy: 0.5)
                XCTAssertEqual(column.view.frame.width, host.bounds.width - 2 * inset, accuracy: 0.5)
                XCTAssertEqual(column.view.frame.height, host.bounds.height - 2 * inset, accuracy: 0.5)
                XCTAssertEqual(column.view.layer?.cornerRadius, style == .roundedPanes ? 16 : 0)
                XCTAssertEqual(column.view.layer?.masksToBounds, style == .roundedPanes)
                XCTAssertFalse(column.view.hasAmbiguousLayout)
            }
            XCTAssertTrue(columns[0].prompt === prompt)
            XCTAssertEqual(prompt.string, "Keep this draft while changing styles.")
            XCTAssertEqual(controller.snapshot.ids, ids)
        }

        // Optional artifact from the actual offscreen AppKit hierarchy.
        if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_PANE_PREVIEW"] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                columns.forEach { $0.applyInterfaceStyle() }
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rounded-panes-\(name).png"))
            }
        }
    }
}
