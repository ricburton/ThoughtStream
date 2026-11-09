import AppKit
import XCTest
@testable import ThoughtStream

final class NavigatorFocusTests: XCTestCase {
    @MainActor
    func testNewSubmissionResumesTrackerPastPendingHistoryRestoration() async throws {
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.setContentSize(NSSize(width: 900, height: 650))
        defer { window.close() }
        pane.replace((0..<20).map { StreamRecord(kind: "Agent", text: "Older reply \($0)") })
        window.contentView?.layoutSubtreeIfNeeded()
        pane.restoreViewState(StreamViewState(firstRecord: 0, follows: false))
        // Sending immediately must also cancel the queued old scroll position.
        pane.resumeLiveActivity()
        pane.append(StreamRecord(kind: "You", text: "A new request"))
        pane.append(StreamRecord(kind: "Agent", text: "The latest response"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(pane.viewState.follows)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let overview = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel()?.hasPrefix("Overview:") == true })
        XCTAssertEqual(overview.selectedRow, overview.numberOfRows - 1)
        // A new tab must discard both the selection and the old scroll target.
        pane.replace([])
        XCTAssertTrue(pane.viewState.follows)
        XCTAssertEqual(overview.numberOfRows, 0)
        XCTAssertEqual(overview.selectedRow, -1)
        pane.append(StreamRecord(kind: "Agent", text: "First activity in the new chat"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(overview.numberOfRows, 1)
        XCTAssertEqual(overview.selectedRow, 0)
    }

    func testChangesDescribeAndTargetAnAddedLine() throws {
        let source = """
        /tmp/Greeting.swift
        --- /dev/null
        +++ b/Greeting.swift
        @@ -0,0 +1,3 @@
        +struct Greeting {
        +    let message = "Hello"
        +}
        """
        let entry = try XCTUnwrap(FeedHighlightIndex.entries(for: StreamRecord(kind: "File change", text: source), at: 4).first)
        XCTAssertEqual(entry.title, "Greeting.swift")
        XCTAssertTrue(entry.summary.contains("3 added"))
        XCTAssertTrue(entry.summary.contains("struct Greeting"))
        XCTAssertEqual(entry.needle, "+struct Greeting {")
        XCTAssertTrue(entry.freshCode)
    }

    func testJSONAndReadbackDoNotTakeCodeFocus() {
        for record in [StreamRecord(kind: "Tool", text: "{\"status\":\"complete\",\"count\":3}"),
                       StreamRecord(kind: "Output", text: "struct Existing {}", language: "swift"),
                       StreamRecord(kind: "File change", text: "--- a/Old.swift\n+++ /dev/null\n-struct Old {}") ] {
            XCTAssertFalse(FeedHighlightIndex.entries(for: record, at: 0).contains(where: \.freshCode))
        }
        let entry = FeedHighlightIndex.entries(for: StreamRecord(kind: "Tool", text: "{\"status\":\"complete\",\"count\":3}"), at: 0).first
        XCTAssertTrue(entry?.summary.contains("status: complete") == true)
    }

    @MainActor
    func testFinalAnswerRetainsNavigableImplementation() throws {
        let record = StreamRecord(kind: "Agent", text: "Here is the greeting.\n```swift\nstruct Greeting {}\n```", isFinalResponse: true)
        let entries = FeedHighlightIndex.entries(for: record, at: 0)
        XCTAssertEqual(entries.first?.title, "Final answer")
        XCTAssertTrue(entries.contains { $0.freshCode && $0.title.contains("Greeting") })
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        XCTAssertTrue(renderer.render(record).contains { if case .code(_, let source, _) = $0 { return source.contains("Greeting") }; return false })
    }

    @MainActor
    func testLiveCodeLingersThroughOutputThenResumesAndManualOverrideWins() async throws {
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.orderFront(nil)
        defer { window.close() }
        pane.replace([StreamRecord(kind: "Agent", text: "Preparing a small example."),
                      StreamRecord(kind: "Agent", text: "Drafting the implementation.", itemID: "answer")])
        window.contentView?.layoutSubtreeIfNeeded()
        let patch = "Greeting.swift\n--- /dev/null\n+++ b/Greeting.swift\n@@ -0,0 +1,40 @@\n" + (0..<40).map { "+let greeting\($0) = \"Hello\"" }.joined(separator: "\n")
        pane.append(StreamRecord(kind: "File change", text: patch, language: "diff"))
        try await Task.sleep(nanoseconds: 500_000_000)
        pane.append(StreamRecord(kind: "Tool", text: "{\"status\":\"saved\",\"detail\":\"" + String(repeating: "extra status ", count: 600) + "\"}"))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(pane.viewState.follows)
        XCTAssertEqual(pane.viewState.firstRecord, 2, "New code should stay visible while JSON arrives")
        pane.finalizeResponse(StreamRecord(kind: "Agent", text: "Created Greeting.swift.", itemID: "answer"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pane.viewState.firstRecord, 1, "Finishing the answer must preserve the code focus as rows move")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(pane.view)
        let overview = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel()?.hasPrefix("Overview:") == true })
        XCTAssertGreaterThanOrEqual(overview.enclosingScrollView?.bounds.width ?? 0, 190)
        if let image = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
            pane.view.cacheDisplay(in: pane.view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/thoughtstream-navigator-focus.png"))
        }
        try await Task.sleep(nanoseconds: 8_900_000_000)
        XCTAssertEqual(pane.viewState.firstRecord, 2, "Following resumes after the nine-second reading pause")

        pane.append(StreamRecord(kind: "File change", text: patch, language: "diff"))
        try await Task.sleep(nanoseconds: 400_000_000)
        let follow = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Follow live" })
        follow.performClick(nil)
        let stopped = pane.viewState
        pane.append(StreamRecord(kind: "Output", text: String(repeating: "Later output\n", count: 100)))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(pane.viewState.follows)
        XCTAssertEqual(pane.viewState.firstRecord, stopped.firstRecord)
    }
}
