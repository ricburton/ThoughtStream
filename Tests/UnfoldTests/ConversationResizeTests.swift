import AppKit
import XCTest
@testable import ThoughtStream

final class ConversationResizeTests: XCTestCase {
    @MainActor
    private func hostedColumn(height: CGFloat = 800) -> (ChatColumn, NSWindow) {
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: height))
        column.view.layoutSubtreeIfNeeded()
        return (column, window)
    }

    @MainActor
    func testDraggingTheDividerGrowsAndShrinksTheConversation() {
        let (column, window) = hostedColumn()
        defer { window.close() }
        column.setConversationFraction(ConversationSplit.defaultFraction)
        column.view.layoutSubtreeIfNeeded()
        let start = column.conversation.frame.height
        XCTAssertEqual(start, 200, accuracy: 1)

        column.resizeConversation(toHeight: start + 240)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.conversation.frame.height, 440, accuracy: 1)

        column.resizeConversation(toHeight: 10)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.conversation.frame.height, ConversationSplit.minimumHeight, accuracy: 1)
    }

    @MainActor
    func testDividerHidesLogsAndKeepsThemHiddenOnResize() throws {
        let previous = UserDefaults.standard.object(forKey: ConversationSplit.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: ConversationSplit.defaultsKey) }
        let (column, window) = hostedColumn()
        defer { window.close() }
        column.resizeConversation(toHeight: 5000)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.stream.view.frame.height, 0, accuracy: 0.5)
        XCTAssertTrue(column.stream.view.isHidden)
        let handle = try XCTUnwrap(column.view.subviews.compactMap { $0 as? ConversationResizeHandle }.first)
        XCTAssertFalse(handle.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(column.view.bounds.contains(handle.frame))

        for height: CGFloat in [1000, 340, 800] {
            window.setContentSize(NSSize(width: 900, height: height))
            column.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(column.stream.view.isHidden)
            XCTAssertEqual(column.stream.view.frame.height, 0, accuracy: 0.5)
            XCTAssertFalse(column.conversation.isHidden)
            XCTAssertFalse(handle.isHiddenOrHasHiddenAncestor)
        }

        let expandedHeight = column.conversation.frame.height
        column.resizeConversation(toHeight: expandedHeight - 100)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(column.stream.view.isHidden)
        XCTAssertEqual(column.stream.view.frame.height, 100, accuracy: 1)
        XCTAssertEqual(column.view.bounds.height, 800, accuracy: 1)

        for remaining: CGFloat in [60, 35, 0, 60, 100] {
            column.resizeConversation(toHeight: expandedHeight - remaining)
            column.view.layoutSubtreeIfNeeded()
            let collapsed = remaining <= ConversationSplit.minimumStreamHeight / 2
            XCTAssertEqual(column.stream.view.isHidden, collapsed)
            XCTAssertEqual(column.stream.view.frame.height,
                           collapsed ? 0 : max(remaining, ConversationSplit.minimumStreamHeight), accuracy: 1)
            XCTAssertEqual(column.view.bounds.height, 800, accuracy: 1)
        }

        column.resizeConversation(toHeight: 400)
        window.setContentSize(NSSize(width: 900, height: 1000))
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.conversation.frame.height, 500, accuracy: 1)

        column.resizeConversation(toHeight: 5000)
        handle.onReset?()
        column.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(column.stream.view.isHidden)
        XCTAssertEqual(column.conversation.frame.height, 250, accuracy: 1)
    }

    @MainActor
    func testStoredCollapsedSplitStartsWithLogsHidden() {
        let previous = UserDefaults.standard.object(forKey: ConversationSplit.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: ConversationSplit.defaultsKey) }
        ConversationSplit.store(1)
        let (column, window) = hostedColumn()
        defer { window.close() }
        XCTAssertTrue(column.stream.view.isHidden)
        XCTAssertEqual(column.stream.view.frame.height, 0, accuracy: 0.5)
        column.setDisplayMode(.justChat)
        column.setDisplayMode(.showLogs)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.stream.view.frame.height, 0, accuracy: 0.5)
        XCTAssertFalse(column.conversation.isHidden)
    }

    func testStoredFractionIsClampedAndDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConversationResizeTests"))
        defer { defaults.removePersistentDomain(forName: "ConversationResizeTests") }
        XCTAssertEqual(ConversationSplit.stored(in: defaults), ConversationSplit.defaultFraction)
        ConversationSplit.store(0.5, in: defaults)
        XCTAssertEqual(ConversationSplit.stored(in: defaults), 0.5, accuracy: 0.0001)
        ConversationSplit.store(3, in: defaults)
        XCTAssertEqual(ConversationSplit.stored(in: defaults), ConversationSplit.maximumFraction, accuracy: 0.0001)
    }
}
