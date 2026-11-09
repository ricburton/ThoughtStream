import AppKit
import XCTest
@testable import ThoughtStream

final class LiveResizeTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testFeedReflowsInPlaceAndKeepsReadingAnchorAndSelection() throws {
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 600))
        pane.replace([StreamRecord(kind: "Agent", text: (0..<150).map {
            "Line \($0): " + String(repeating: "Words that must wrap gently across the pane. ", count: 3)
        }.joined(separator: "\n"))])
        pane.view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Native conversation and live activity" })
        let scroll = try XCTUnwrap(table.enclosingScrollView as? NativeFeedScrollView)
        scroll.onScrollUp?()
        let row = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeFeedRow)
        let text = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeFeedTextView }.first)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        pane.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        text.setSelectedRange(NSRange(location: 400, length: 20))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let anchor = try XCTUnwrap(FeedTextScrollAnchor(document: table, viewport: scroll.documentVisibleRect))
        for width: CGFloat in [850, 700, 550, 720, 1000] {
            window.setContentSize(NSSize(width: width, height: 600))
            pane.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === row,
                          "Resizing must not discard the visible row")
            XCTAssertEqual(text.selectedRange(), NSRange(location: 400, length: 20))
            XCTAssertEqual(table.rect(ofRow: 0).height, row.contentHeight, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(anchor.position(in: table)), scroll.documentVisibleRect.minY, accuracy: 2)
            let container = try XCTUnwrap(text.textContainer)
            let layout = try XCTUnwrap(text.layoutManager)
            layout.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).height, text.bounds.height + 1,
                                     "Wrapped glyphs must stay inside the resized text view")
        }
        XCTAssertFalse(pane.viewState.follows)
    }

    @MainActor
    func testSplitDividerReflowsCodeWithoutReplacingItsTextView() throws {
        let pane = StreamPane()
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.addSplitViewItem(NSSplitViewItem(viewController: pane))
        let neighbor = NSViewController(); neighbor.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(viewController: neighbor))
        let window = NSWindow(contentViewController: split)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1400, height: 650))
        pane.replace([StreamRecord(kind: "Agent", text: "A code example.\n\n```swift\n" +
            String(repeating: "let message = \"A long line of code that wraps inside the pane while its divider moves\"\n", count: 100) + "```")])
        split.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let table = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Native conversation and live activity" })
        let scroll = try XCTUnwrap(table.enclosingScrollView as? NativeFeedScrollView)
        scroll.onScrollUp?()
        let row = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeFeedRow)
        let code = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeFeedTextView }.last)
        scroll.onUserScroll?()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let anchor = try XCTUnwrap(FeedTextScrollAnchor(document: table, viewport: scroll.documentVisibleRect))
        for position: CGFloat in [600, 800, 550, 900] {
            split.splitView.setPosition(position, ofDividerAt: 0)
            split.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === row)
            XCTAssertTrue(descendants(row).contains { $0 === code })
            XCTAssertEqual(try XCTUnwrap(anchor.position(in: table)), scroll.documentVisibleRect.minY, accuracy: 2)
            let layout = try XCTUnwrap(code.layoutManager), container = try XCTUnwrap(code.textContainer)
            layout.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).height, code.bounds.height + 1)
        }
    }

    @MainActor
    func testFollowLatestRemainsAtBottomWhileResizing() throws {
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 600))
        pane.replace((0..<80).map { StreamRecord(kind: "Agent", text: "Message \($0) " + String(repeating: "wrapping text ", count: 60)) })
        pane.view.layoutSubtreeIfNeeded()
        pane.resumeLiveActivity()
        for size in [NSSize(width: 1000, height: 600), NSSize(width: 600, height: 500), NSSize(width: 950, height: 700)] {
            window.setContentSize(size)
            pane.view.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }
                .first { $0.accessibilityLabel() == "Native conversation and live activity" })
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            XCTAssertEqual(scroll.documentVisibleRect.maxY, table.rect(ofRow: 79).maxY, accuracy: 2)
            XCTAssertTrue(pane.viewState.follows)
        }
    }

    @MainActor
    func testConversationKeepsCharacterAnchorWhenRewrapping() throws {
        let conversation = ConversationView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = conversation
        defer { window.close() }
        conversation.replace([StreamRecord(kind: "Agent", text: String(repeating: "Text that wraps across several lines. ", count: 500))])
        conversation.layoutSubtreeIfNeeded()
        conversation.scroll.onScrollUp?()
        conversation.scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        let anchor = try XCTUnwrap(FeedTextScrollAnchor(document: conversation.transcript,
                                                      viewport: conversation.scroll.documentVisibleRect))
        for width: CGFloat in [600, 450, 750] {
            window.setContentSize(NSSize(width: width, height: 450))
            conversation.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(anchor.position(in: conversation.transcript)),
                           conversation.scroll.documentVisibleRect.minY, accuracy: 2)
            XCTAssertFalse(conversation.followsLatest)
        }
        conversation.resumeLiveActivity()
        window.setContentSize(NSSize(width: 500, height: 500))
        conversation.layoutSubtreeIfNeeded()
        XCTAssertEqual(conversation.scroll.documentVisibleRect.maxY, conversation.transcript.bounds.maxY, accuracy: 2)
    }
}
