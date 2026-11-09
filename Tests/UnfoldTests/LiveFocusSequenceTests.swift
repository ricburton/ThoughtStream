import AppKit
import XCTest
@testable import ThoughtStream

final class LiveFocusSequenceTests: XCTestCase {
    func testFirstReasoningThenFirstCodeThenNextUniqueObjects() throws {
        var sequence = FeedLiveFocusSequence()
        let records = [
            StreamRecord(kind: "Command", text: "inspect project", itemID: "command"),
            StreamRecord(kind: "Reasoning summary", text: "Plan the change", itemID: "reasoning"),
            StreamRecord(kind: "Output", text: "Supporting output", itemID: "output"),
            StreamRecord(kind: "Code", text: "let first = 1", language: "swift", itemID: "code")
        ] + (4..<10).map { StreamRecord(kind: "Agent", text: "Distinct reply \($0)", itemID: "reply-\($0)") }
        for (row, record) in records.enumerated() {
            for entry in FeedLiveFocusSequence.objects(FeedHighlightIndex.entries(for: record, at: row)) {
                sequence.offer(entry, record: record)
            }
        }
        XCTAssertEqual(sequence.next()?.highlight.kind, "Reasoning")
        XCTAssertEqual(sequence.next()?.highlight.record, 3)
        for row in 4..<10 { XCTAssertEqual(sequence.next()?.highlight.record, row) }
        XCTAssertNil(sequence.next())
    }

    func testInterleavedFragmentsAndMovedFinalAnswerKeepTheirIdentity() throws {
        var sequence = FeedLiveFocusSequence()
        let record = StreamRecord(kind: "Reasoning summary", text: "First fragment", itemID: "reasoning")
        let entry = try XCTUnwrap(FeedHighlightIndex.entries(for: record, at: 0).first)
        sequence.offer(entry, record: record)
        XCTAssertNotNil(sequence.next())
        var later = record; later.text += " and another fragment"
        let moved = try XCTUnwrap(FeedHighlightIndex.entries(for: later, at: 4).first)
        sequence.offer(moved, record: later)
        XCTAssertNil(sequence.next(), "An updated or moved runtime object must not replay")
        let code = StreamRecord(kind: "Code", text: "let next = 2", itemID: "code")
        sequence.offer(try XCTUnwrap(FeedHighlightIndex.entries(for: code, at: 5).first), record: code)
        XCTAssertEqual(sequence.next()?.highlight.record, 5)
    }

    func testCodeOnlyRunsAndTransportFiltering() throws {
        var sequence = FeedLiveFocusSequence()
        let record = StreamRecord(kind: "Agent", text: "Implementation:\n```swift\nlet value = 1\n```", itemID: "reply")
        let objects = FeedLiveFocusSequence.objects(FeedHighlightIndex.entries(for: record, at: 0))
        XCTAssertEqual(objects.count, 1, "The reply wrapper must not duplicate its code object")
        for object in objects { sequence.offer(object, record: record) }
        XCTAssertTrue(try XCTUnwrap(sequence.next()).highlight.freshCode)
        XCTAssertNil(sequence.next())
        XCTAssertTrue(FeedLiveFocusSequence.objects(FeedHighlightIndex.entries(for: StreamRecord(kind: "You", text: "request"), at: 1)).isEmpty)
        XCTAssertTrue(FeedLiveFocusSequence.objects(FeedHighlightIndex.entries(for: StreamRecord(kind: "Session", text: "Runtime connected"), at: 2)).isEmpty)
    }

    @MainActor
    func testObjectsAndStreamAdvanceWhileReasoningContinuesStreaming() async throws {
        let pane = StreamPane()
        pane.liveFocusDuration = { _ in 0.8 }
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        defer { window.close() }
        pane.append(StreamRecord(kind: "Reasoning summary", text: String(repeating: "Plan the change carefully. ", count: 40), itemID: "reasoning"), delta: true)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(pane.focusedLiveObject?.kind, "Reasoning")
        pane.append(StreamRecord(kind: "Code", text: (0..<35).map { "let value\($0) = \($0)" }.joined(separator: "\n"), language: "swift", itemID: "code"))
        pane.append(StreamRecord(kind: "Output", text: "Build passed.\n" + String(repeating: "Validation output\n", count: 40), itemID: "result"))
        for _ in 0..<4 {
            pane.append(StreamRecord(kind: "Reasoning summary", text: "More live reasoning. ", itemID: "reasoning"), delta: true)
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        XCTAssertTrue(pane.focusedLiveObject?.freshCode == true, "Token arrivals must not extend the reasoning pause")
        XCTAssertTrue(pane.viewState.follows)
        XCTAssertTrue(pane.recordsSnapshot().contains { $0.text.contains("More live reasoning.") })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let overview = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel()?.hasPrefix("Overview:") == true })
        XCTAssertEqual(overview.selectedRow, 1, "Objects must focus the same code as Thought Stream")
        if let image = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
            pane.view.cacheDisplay(in: pane.view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/thoughtstream-live-sequence.png"))
        }
        let deadline = Date().addingTimeInterval(3)
        while pane.focusedLiveObject?.kind != "Output", Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(pane.focusedLiveObject?.kind, "Output")
        XCTAssertEqual(overview.selectedRow, 2)
        let follow = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "Follow live" })
        follow.performClick(nil)
        pane.append(StreamRecord(kind: "Code", text: "let manualOverrideWins = true", itemID: "later"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(pane.focusedLiveObject)
        XCTAssertFalse(pane.viewState.follows)
    }
}
