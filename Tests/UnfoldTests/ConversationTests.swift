import AppKit
import XCTest
@testable import ThoughtStream

final class ConversationTests: XCTestCase {
    @MainActor
    func testNewUserMessageResumesConversationAfterReadingOlderReplies() async throws {
        let column = ChatColumn(); column.loadViewIfNeeded()
        let window = NSWindow(contentViewController: column)
        window.setContentSize(NSSize(width: 850, height: 800))
        defer { window.close() }
        column.stream.replace((0..<30).map {
            StreamRecord(kind: "Agent", text: "Older reply \($0). " + String(repeating: "Conversation history. ", count: 20))
        })
        column.view.layoutSubtreeIfNeeded()
        let panel = column.conversation
        panel.scroll.onScrollUp?()
        panel.scroll.contentView.scroll(to: .zero)
        panel.transcript.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertFalse(panel.followsLatest)

        column.stream.append(StreamRecord(kind: "You", text: "Here is my next message."))
        _ = column.stream.recordsSnapshot()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(panel.transcript.string.contains("Here is my next message."))
        XCTAssertTrue(panel.followsLatest)
        XCTAssertEqual(panel.transcript.selectedRange().length, 0)
        XCTAssertEqual(panel.scroll.documentVisibleRect.maxY, panel.transcript.bounds.maxY, accuracy: 2)

        column.stream.append(StreamRecord(kind: "Agent", text: "And here is the response."))
        _ = column.stream.recordsSnapshot()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(panel.followsLatest)
        XCTAssertEqual(panel.scroll.documentVisibleRect.maxY, panel.transcript.bounds.maxY, accuracy: 2)
    }

    @MainActor
    func testConversationKeepsRepliesTogetherAndReplacesHistory() {
        let column = ChatColumn(); column.loadViewIfNeeded()
        column.stream.replace([
            StreamRecord(kind: "You", text: "What changed?"),
            StreamRecord(kind: "Command", text: "git diff"),
            StreamRecord(kind: "Reasoning summary", text: "Check the patch"),
            StreamRecord(kind: "Agent", text: "The conversation now has its own panel.", itemID: "reply")
        ])
        XCTAssertEqual(column.conversation.records.count, 2)
        XCTAssertFalse(column.conversation.transcript.string.contains("You\n"))
        XCTAssertFalse(column.conversation.transcript.string.contains("Assistant\n"))
        XCTAssertFalse(column.conversation.transcript.string.contains("Check the patch"))
        XCTAssertFalse(column.conversation.transcript.string.contains("git diff"))
        column.stream.append(StreamRecord(kind: "Output", text: "tool output"))
        column.stream.append(StreamRecord(kind: "Agent", text: " You can scroll it independently.", itemID: "reply"), delta: true)
        _ = column.stream.recordsSnapshot()
        XCTAssertEqual(column.conversation.records.count, 2)
        XCTAssertTrue(column.conversation.transcript.string.contains("panel. You can scroll"))
        column.stream.replace([
            StreamRecord(kind: "Agent", text: "A streamed", itemID: "restored"),
            StreamRecord(kind: "Tool", text: "interleaved work"),
            StreamRecord(kind: "Agent", text: " reply", itemID: "restored")
        ])
        XCTAssertEqual(column.conversation.records.count, 1)
        XCTAssertTrue(column.conversation.transcript.string.contains("A streamed reply"))
        column.stream.replace([StreamRecord(kind: "You", text: "A different chat")])
        XCTAssertFalse(column.conversation.transcript.string.contains("What changed?"))
        XCTAssertTrue(column.conversation.transcript.string.contains("A different chat"))
    }

    @MainActor
    func testReasoningStaysInActivityStreamAndOutOfConversation() throws {
        let column = ChatColumn(); column.loadViewIfNeeded()
        column.stream.append(StreamRecord(kind: StreamKind.reasoning.rawValue, text: "Check ", itemID: "reasoning"), delta: true)
        column.stream.append(StreamRecord(kind: StreamKind.command.rawValue, text: "private tool details"))
        column.stream.append(StreamRecord(kind: StreamKind.reasoning.rawValue, text: "the result.", itemID: "reasoning"), delta: true)
        column.stream.append(StreamRecord(kind: StreamKind.prose.rawValue, text: "Done.", itemID: "answer"), delta: true)
        let activity = column.stream.recordsSnapshot()
        let panel = column.conversation
        XCTAssertEqual(panel.records.map(\.text), ["Done."])
        XCTAssertFalse(panel.transcript.string.contains("Check the result."))
        XCTAssertEqual(activity.filter { $0.kind == StreamKind.reasoning.rawValue }.map(\.text).joined(), "Check the result.")
        XCTAssertFalse(panel.transcript.string.contains("private tool details"))
        panel.finalizeResponse(StreamRecord(kind: StreamKind.prose.rawValue, text: "Verified.", itemID: "answer"))
        XCTAssertEqual(panel.records.map(\.text), ["Verified."])
        XCTAssertEqual(panel.transcript.string.trimmingCharacters(in: .whitespacesAndNewlines), "Verified.")
    }

    @MainActor
    func testConversationLayoutAndIndependentScrolling() throws {
        let column = ChatColumn(); column.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = column
        window.title = "Conversation layout preview"
        defer { window.close() }
        column.stream.replace([
            StreamRecord(kind: "You", text: "Can you make the conversation easier to follow while keeping the detailed activity above?"),
            StreamRecord(kind: "Command", text: "$ swift test\nBuild complete. All checks passed."),
            StreamRecord(kind: "Reasoning summary", text: "Keep the explanation beside the reply so the conversation stays easy to follow."),
            StreamRecord(kind: "Agent", text: "Yes. Your messages and my replies now stay together above the composer.\n\nThe panel scrolls independently, so you can read our conversation while inspecting commands, output, and activity in the stream above.")
        ])
        for size in [NSSize(width: 850, height: 800), NSSize(width: 420, height: 600)] {
            window.setContentSize(size); column.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let panel = column.conversation
            XCTAssertEqual(panel.frame.width, size.width, accuracy: 1)
            XCTAssertEqual(panel.frame.height, size.height / 4, accuracy: 1)
            XCTAssertGreaterThan(column.stream.view.frame.height, panel.frame.height)
            XCTAssertEqual(panel.frame.minX, column.stream.view.frame.minX, accuracy: 1)
            XCTAssertGreaterThan(panel.scroll.contentSize.width, 350)
            XCTAssertGreaterThan(panel.transcript.bounds.height, 0)
            if size.width == 850 {
                let bitmap = try XCTUnwrap(column.view.bitmapImageRepForCachingDisplay(in: column.view.bounds))
                column.view.cacheDisplay(in: column.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/thoughtstream-conversation-layout.png"))
            }
        }
        column.conversation.scroll.onScrollUp?()
        XCTAssertFalse(column.conversation.followsLatest)
        column.stream.append(StreamRecord(kind: "Agent", text: "A new reply"))
        _ = column.stream.recordsSnapshot()
        XCTAssertFalse(column.conversation.followsLatest)
    }
}
