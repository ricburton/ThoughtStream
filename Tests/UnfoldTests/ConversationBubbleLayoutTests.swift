import AppKit
import XCTest
@testable import ThoughtStream

final class ConversationBubbleLayoutTests: XCTestCase {
    @MainActor
    func testSurfacesKeepSharedEdgesAndBalancedMarginsWhileWrapping() throws {
        let panel = ConversationView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.close() }
        let messages = [
            StreamRecord(kind: "You", text: "Give each message enough room to breathe, including when this pane gets narrower."),
            StreamRecord(kind: "Agent", text: "## A little more space\n\nA longer reply should wrap comfortably and keep its surface clear of the next message.\n\nAccents and emoji still fit: café, Ångström, 👋🏽."),
            StreamRecord(kind: "You", text: "Looks good."),
            StreamRecord(kind: "Agent", text: "Ready.")
        ]
        for width: CGFloat in [720, 320, 1_100] {
            window.setContentSize(NSSize(width: width, height: 240))
            panel.layoutSubtreeIfNeeded()
            panel.replace(messages)
            panel.layoutSubtreeIfNeeded()
            let storage = try XCTUnwrap(panel.transcript.textStorage)
            let layout = try XCTUnwrap(panel.transcript.layoutManager as? ConversationLayoutManager)
            let container = try XCTUnwrap(panel.transcript.textContainer)
            var surfaces: [NSRect] = []
            storage.enumerateAttribute(.conversationBubble, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value is ConversationBubble,
                      let surface = layout.bubbleRect(forCharacterRange: range, in: container) else { return }
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let text = layout.boundingRect(forGlyphRange: glyphs, in: container)
                XCTAssertTrue(surface.insetBy(dx: -1, dy: -1).contains(text), "The surface must contain the wrapped text")
                XCTAssertGreaterThanOrEqual(surface.minX, 0)
                XCTAssertLessThanOrEqual(surface.maxX, container.containerSize.width + 1)
                surfaces.append(surface.offsetBy(dx: panel.transcript.textContainerOrigin.x, dy: panel.transcript.textContainerOrigin.y))
            }
            XCTAssertEqual(surfaces.count, messages.count)
            guard surfaces.count == messages.count else { continue }
            XCTAssertEqual(surfaces[0].maxX, surfaces[2].maxX, accuracy: 1, "Outgoing messages share a trailing edge")
            XCTAssertEqual(surfaces[1].minX, surfaces[3].minX, accuracy: 1, "Replies share a leading edge")
            for pair in zip(surfaces, surfaces.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1.minY - pair.0.maxY, 12, "Turns must remain visually separate")
            }
            XCTAssertGreaterThan(panel.transcript.bounds.height, panel.scroll.contentSize.height)
            let topMargin = surfaces[0].minY
            let bottomMargin = panel.transcript.bounds.maxY - surfaces[3].maxY
            XCTAssertEqual(topMargin, bottomMargin, accuracy: 1, "Trailing spacer lines must not inflate the bottom margin")
            XCTAssertTrue(panel.transcript.isSelectable)
        }
    }
}
