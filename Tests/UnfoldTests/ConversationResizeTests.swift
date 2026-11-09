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
    func testDividerKeepsRoomForTheStreamAndKeepsProportionOnResize() {
        let (column, window) = hostedColumn()
        defer { window.close() }
        column.resizeConversation(toHeight: 5000)
        column.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(column.stream.view.frame.height, ConversationSplit.minimumStreamHeight - 1)

        column.resizeConversation(toHeight: 400)
        window.setContentSize(NSSize(width: 900, height: 1000))
        column.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(column.conversation.frame.height, 500, accuracy: 1)
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
