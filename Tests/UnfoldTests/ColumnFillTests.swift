import AppKit
import XCTest
@testable import ThoughtStream

final class ColumnFillTests: XCTestCase {
    @MainActor
    private func controllers(_ root: NSViewController) -> [NSViewController] {
        [root] + root.children.flatMap(controllers)
    }

    @MainActor
    func testFreshColumnsAndClosingExpandedCanvasFillAvailableWidth() throws {
        let originalStyle = InterfaceStyle.current
        defer { InterfaceStyle.current = originalStyle }
        for style in [InterfaceStyle.standard, .roundedPanes] {
            InterfaceStyle.current = style
            for width: CGFloat in [860, 1450] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let sessions = (0..<4).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
                let workspace = WorkspaceWindow(restoredSessions: sessions,
                    stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
                let window = try XCTUnwrap(workspace.window)
                defer { workspace.stopAll(); window.close() }
                window.setContentSize(NSSize(width: width, height: 800))
                let content = try XCTUnwrap(window.contentViewController)
                let canvas = try XCTUnwrap(controllers(content).compactMap { $0 as? PaneCanvasController }.first)
                func checkFill(_ count: Int) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    canvas.fit()
                    let panes = controllers(content).compactMap { $0 as? ChatColumn }
                    XCTAssertEqual(panes.count, count)
                    XCTAssertFalse(canvas.overflows.horizontal)
                    XCTAssertEqual(canvas.canvasSize.width, canvas.viewport.width, accuracy: 1)
                    let inset = InterfaceStyle.hasRoundedPanes ? 2 * PaneSurface.inset : 0
                    let share = (canvas.viewport.width - CGFloat(count - 1)) / CGFloat(count) - inset
                    for pane in panes { XCTAssertEqual(pane.view.frame.width, share, accuracy: 1) }
                    XCTAssertEqual(window.contentView?.bounds.width, width)
                }
                checkFill(4)
                // Simulate a previous divider expansion, then close a chat.
                canvas.minimumCanvasSize.width = 3000
                canvas.hasCustomSizing = true
                canvas.fit()
                XCTAssertTrue(canvas.overflows.horizontal)
                for count in stride(from: 3, through: 1, by: -1) {
                    let panes = controllers(content).compactMap { $0 as? ChatColumn }
                    workspace.closePane(panes[panes.count / 2])
                    checkFill(count)
                    XCTAssertEqual(canvas.minimumCanvasSize.width, 0)
                }
            }
        }
    }

    @MainActor
    func testStackedChatsCountAsColumnsAndLargeSetsStillScroll() throws {
        let columns = (0..<6).map { _ in ChatColumn() }
        let ids = columns.map(\.columnID)
        let canvas = PaneCanvasController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = canvas
        window.setContentSize(NSSize(width: 1200, height: 900))
        defer { window.close() }
        let store = Dictionary(uniqueKeysWithValues: columns.map { ($0.columnID, $0) })
        let six = PaneLayoutController(layout: PaneLayout.arranged(ids, as: .columns)!, columns: store,
                                       configureHost: { _, _ in }, resized: {})
        canvas.setLayout(six)
        canvas.balanceToFit()
        XCTAssertTrue(canvas.overflows.horizontal)
        let grid = PaneLayout.split(vertical: false, fraction: 0.5,
            first: PaneLayout.arranged(Array(ids.prefix(3)), as: .columns)!,
            second: PaneLayout.arranged(Array(ids.suffix(3)), as: .columns)!)
        let three = PaneLayoutController(layout: grid, columns: store,
                                         configureHost: { _, _ in }, resized: {})
        canvas.minimumCanvasSize.width = 3000
        canvas.hasCustomSizing = true
        canvas.setLayout(three)
        canvas.balanceToFit()
        XCTAssertEqual(three.columnCount, 3)
        XCTAssertFalse(canvas.overflows.horizontal)
        for host in three.paneViews {
            XCTAssertEqual(host.frame.width, (canvas.viewport.width - 2) / 3, accuracy: 1)
        }
    }
}
