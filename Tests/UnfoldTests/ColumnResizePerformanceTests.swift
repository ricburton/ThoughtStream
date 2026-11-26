import AppKit
import XCTest
@testable import ThoughtStream

/// Uses actual text views and split geometry, without starting a runtime or the app.
final class ColumnResizePerformanceTests: XCTestCase {
    @MainActor
    func testExpandingLoadedColumnKeepsOtherColumnsAndSelectionsStable() throws {
        let originalStyle = InterfaceStyle.current
        InterfaceStyle.current = .standard
        defer { InterfaceStyle.current = originalStyle }
        let columns = (0..<4).map { _ in ChatColumn() }
        let ids = columns.map(\.columnID)
        let controller = PaneLayoutController(layout: PaneLayout.arranged(ids, as: .columns)!,
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
        canvas.view.layoutSubtreeIfNeeded()
        let records = (0..<30).map { index in
            StreamRecord(kind: index.isMultiple(of: 3) ? "You" : "Agent",
                         text: "Message \(index). " + String(repeating: "Keep the reader's place while this text wraps to the new column width. ", count: 18))
        }
        for column in columns {
            column.setDisplayMode(.showLogs)
            column.conversation.replace(records)
            column.stream.replace(records)
            column.prompt.string = "A draft that must survive resizing."
            column.prompt.setSelectedRange(NSRange(location: 2, length: 5))
        }
        canvas.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        func splits(_ node: NSViewController) -> [NSSplitViewController] {
            (node as? NSSplitViewController).map { [$0] + node.children.flatMap(splits) } ?? node.children.flatMap(splits)
        }
        let firstHost = try XCTUnwrap(columns[0].view.superview)
        let divider = try XCTUnwrap(splits(controller).first {
            $0.splitView.isVertical && $0.splitViewItems.first?.viewController.view === firstHost
        }?.splitView)
        let initial = columns.map { $0.view.bounds.size }
        let transcripts = columns.map { $0.conversation.transcript }
        var neighborFrameChanges = 0
        let frameObservers = transcripts.dropFirst().map { transcript in
            transcript.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: transcript, queue: nil) { _ in
                MainActor.assumeIsolated { neighborFrameChanges += 1 }
            }
        }
        defer { frameObservers.forEach(NotificationCenter.default.removeObserver) }
        let startWidth = firstHost.bounds.width
        let steps = Int(ProcessInfo.processInfo.environment["THOUGHTSTREAM_RESIZE_STEPS"] ?? "12") ?? 12
        let initialRevision = controller.layoutRevision
        var times: [Double] = []
        for step in 1...max(1, steps) {
            let start = ProcessInfo.processInfo.systemUptime
            divider.setPosition(startWidth + CGFloat(step) * 2, ofDividerAt: 0)
            canvas.view.layoutSubtreeIfNeeded()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let ordered = times.sorted()
        print(String(format: "COLUMN_RESIZE steps=%d median_ms=%.3f p95_ms=%.3f total_ms=%.3f neighbor_frame_changes=%d layout_passes=%llu", times.count,
                     ordered[ordered.count / 2], ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))], times.reduce(0, +), neighborFrameChanges, controller.layoutRevision - initialRevision))
        // Appearing horizontal navigation can change all viewport heights once.
        // Later steps must not reflow neighbors whose column widths are unchanged.
        XCTAssertLessThanOrEqual(neighborFrameChanges, 12)
        XCTAssertLessThanOrEqual(controller.layoutRevision - initialRevision, UInt64(max(1, steps) + 1),
                                 "Canvas growth must not arrange the whole tree twice per drag event")
        XCTAssertEqual(columns[0].view.bounds.width, initial[0].width + CGFloat(max(1, steps)) * 2, accuracy: 1)
        for index in columns.indices {
            XCTAssertTrue(columns[index].conversation.transcript === transcripts[index])
            XCTAssertEqual(columns[index].prompt.string, "A draft that must survive resizing.")
            XCTAssertEqual(columns[index].prompt.selectedRange(), NSRange(location: 2, length: 5))
            if index > 0 { XCTAssertEqual(columns[index].view.bounds.width, initial[index].width, accuracy: 1) }
        }

        let conversation = columns[0].conversation
        conversation.scroll.onScrollUp?()
        conversation.scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        conversation.transcript.setSelectedRange(NSRange(location: 400, length: 20))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let anchor = try XCTUnwrap(FeedTextScrollAnchor(document: conversation.transcript,
                                                       viewport: conversation.scroll.documentVisibleRect))
        for position in [startWidth + 80, startWidth - 30, startWidth + 120] {
            divider.setPosition(position, ofDividerAt: 0)
            canvas.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(conversation.transcript.selectedRange(), NSRange(location: 400, length: 20))
            XCTAssertEqual(try XCTUnwrap(anchor.position(in: conversation.transcript)),
                           conversation.scroll.documentVisibleRect.minY, accuracy: 2)
        }
    }
}
