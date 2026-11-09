import AppKit
import XCTest
@testable import ThoughtStream

final class StreamingPresentationTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    func testGrowingCodeKeepsTextViewSelectionAndCopyCurrent() throws {
        let source = "let greeting = \"Hello 👋\"\n"
        func blocks(_ value: String) -> [NativeFeedBlock] {
            var renderer = NativeFeedRenderer(size: 16, analyses: [:])
            return renderer.render(StreamRecord(kind: "Code", text: value, language: "swift"))
        }
        let row = NativeFeedRow(blocks: blocks(source), width: 400, images: [:], openHTML: { _ in }, openImage: { _ in })
        let code = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeCodeView }.first)
        let text = try XCTUnwrap(descendants(code).compactMap { $0 as? NativeFeedTextView }.first)
        text.setSelectedRange(NSRange(location: 4, length: 8))
        let updated = source + "let next = greeting + \" 🌍\"\n"
        let height = row.update(blocks: blocks(updated), width: 400, images: [:], reveal: nil, accent: nil)
        XCTAssertTrue(descendants(row).contains { $0 === code })
        XCTAssertTrue(descendants(row).contains { $0 === text })
        XCTAssertEqual(text.selectedRange(), NSRange(location: 4, length: 8))
        XCTAssertTrue(text.string.contains("🌍"))
        XCTAssertEqual(code.source, updated)
        XCTAssertEqual(height, row.contentHeight)
        let copy = try XCTUnwrap(descendants(code).compactMap { $0 as? CopyFeedbackButton }.first)
        XCTAssertEqual(copy.textToCopy, updated)
    }

    @MainActor
    func testAppendingCodeBlockPreservesEarlierParagraph() throws {
        func blocks(_ value: String) -> [NativeFeedBlock] {
            var renderer = NativeFeedRenderer(size: 16, analyses: [:])
            return renderer.render(StreamRecord(kind: "Agent", text: value))
        }
        let row = NativeFeedRow(blocks: blocks("Here is the example."), width: 500, images: [:], openHTML: { _ in }, openImage: { _ in })
        let prose = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeFeedTextView }.first)
        row.update(blocks: blocks("Here is the example.\n\n```swift\nlet x = 1\n```"), width: 500, images: [:], reveal: nil, accent: nil)
        XCTAssertTrue(descendants(row).contains { $0 === prose })
        XCTAssertEqual(descendants(row).compactMap { $0 as? NativeCodeView }.count, 1)
    }

    @MainActor
    func testOverviewUpdatesPreserveExistingCardsAndReadingPosition() throws {
        let overview = FeedHighlightsView(frame: NSRect(x: 0, y: 0, width: 230, height: 400))
        let window = NSWindow(contentRect: overview.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = overview
        defer { window.close() }
        overview.setFollowingLatest(false)
        var entries = (0..<30).map { FeedHighlight(record: $0, kind: "Changes", title: "File \($0)", summary: "Adding code", needle: "+let a", freshCode: true) }
        overview.update(entries); overview.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(overview).compactMap { $0 as? NSTableView }.first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 10).minY + 7))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 10, makeIfNecessary: true))
        let position = scroll.contentView.bounds.minY
        let id = entries[10].id
        entries[10].summary = "Adding more code"; entries[10].needle = "+let anotherVariable"
        entries.append(FeedHighlight(record: 30, kind: "JSON", title: "Object", summary: "New data"))
        overview.update(entries); overview.layoutSubtreeIfNeeded()
        XCTAssertEqual(entries[10].id, id, "A growing first line must not change a code card's identity")
        XCTAssertTrue(table.view(atColumn: 0, row: 10, makeIfNecessary: false) === cell)
        XCTAssertEqual(scroll.contentView.bounds.minY, position, accuracy: 1)
        XCTAssertEqual(table.numberOfRows, 31)
    }

    @MainActor
    func testStreamPacketsPreserveRawRowAndViewportWhileReading() async throws {
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false; window.setContentSize(NSSize(width: 900, height: 600))
        defer { window.close() }
        let source = (0..<120).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        pane.replace([StreamRecord(kind: "Code", text: source, language: "swift", itemID: "stream")])
        pane.view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Native conversation and live activity" })
        let scroll = try XCTUnwrap(table.enclosingScrollView as? NativeFeedScrollView)
        scroll.onScrollUp?()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 450))
        let row = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let text = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeFeedTextView }.first)
        let position = scroll.contentView.bounds.minY
        for index in 120..<124 {
            pane.append(StreamRecord(kind: "Code", text: "let value\(index) = \(index)\n", language: "swift", itemID: "stream"), delta: true)
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === row)
            XCTAssertTrue(descendants(row).contains { $0 === text })
            XCTAssertEqual(scroll.contentView.bounds.minY, position, accuracy: 2)
        }
        XCTAssertTrue(text.string.contains("value123"))
        XCTAssertFalse(pane.viewState.follows)
    }
}
