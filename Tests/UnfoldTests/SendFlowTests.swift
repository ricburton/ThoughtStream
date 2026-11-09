import AppKit
import XCTest
@testable import ThoughtStream

private final class TranscriptEdits: NSObject, NSTextStorageDelegate {
    var ranges: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { ranges.append(editedRange) }
    }
}

final class SendFlowTests: XCTestCase {
    @MainActor
    func testQueueStatusKeepsHistoryViewsAndTranscriptInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = MessageOutbox(url: root.appendingPathComponent("outbox.json"))
        let message = try outbox.enqueue(text: "Next question", attachments: [], settings: .preferred)
        let history = (0..<20).map {
            StreamRecord(kind: "Agent", text: "History \($0). " + String(repeating: "Keep this readable. ", count: 12))
        }
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 850, height: 800))
        column.stream.replace(outbox.decorate(history + message.records))
        column.view.layoutSubtreeIfNeeded()
        let panel = column.conversation
        let storage = try XCTUnwrap(panel.transcript.textStorage)
        let prefix = try XCTUnwrap(panel.transcript.string.range(of: "You\n", options: .backwards))
        let prefixLength = panel.transcript.string[..<prefix.lowerBound].utf16.count
        let edits = TranscriptEdits(); storage.delegate = edits
        panel.scroll.onScrollUp?()
        panel.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(column.stream.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Native conversation and live activity" })
        let activityScroll = try XCTUnwrap(table.enclosingScrollView as? NativeFeedScrollView)
        activityScroll.onScrollUp?()
        activityScroll.contentView.scroll(to: .zero)
        table.layoutSubtreeIfNeeded()
        let oldRow = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        for state: QueuedChat.State in [.submitting, .uncertain, .delivered] {
            try outbox.update(message.id, state: state)
            column.stream.updateQueuePresentation(outbox)
            XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === oldRow,
                          "Delivery status must not recreate unchanged history")
            XCTAssertEqual(panel.scroll.documentVisibleRect.minY, 100, accuracy: 1)
            XCTAssertFalse(panel.followsLatest)
        }
        XCTAssertFalse(edits.ranges.isEmpty)
        XCTAssertTrue(edits.ranges.allSatisfy { $0.location >= prefixLength },
                      "Queue updates must only edit the changed message, never empty the transcript")
        edits.ranges.removeAll()
        column.stream.updateQueuePresentation(outbox)
        XCTAssertTrue(edits.ranges.isEmpty, "An unchanged receipt must not edit the transcript")
    }

    @MainActor
    func testStreamingAfterSendMovesUpWithoutReversingOrLosingFollow() async throws {
        let panel = ConversationView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.close() }
        panel.replace((0..<15).map { StreamRecord(kind: "Agent", text: "Reply \($0).\n" + String(repeating: "An earlier line.\n", count: 3)) })
        panel.layoutSubtreeIfNeeded()
        panel.resumeLiveActivity()
        panel.append(StreamRecord(kind: "You", text: "Please continue."), merging: false)
        var previousY = panel.scroll.documentVisibleRect.minY
        for index in 0..<36 {
            if index.isMultiple(of: 3) {
                panel.append(StreamRecord(kind: "Agent", text: "New information arriving in the conversation.\n", itemID: "reply"), merging: true)
                // Delivery/history refreshes can interleave with streamed words.
                panel.replace(panel.records, preservingPosition: true)
            }
            try await Task.sleep(nanoseconds: 16_666_667)
            let y = panel.scroll.documentVisibleRect.minY
            XCTAssertGreaterThanOrEqual(y + 0.5, previousY, "New information must not pull the viewport backwards")
            XCTAssertTrue(panel.followsLatest)
            previousY = y
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(panel.scroll.documentVisibleRect.maxY, panel.transcript.bounds.maxY, accuracy: 2)
    }
}
