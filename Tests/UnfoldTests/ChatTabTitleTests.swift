import AppKit
import XCTest
@testable import ThoughtStream

final class ChatTabTitleTests: XCTestCase {
    func testProviderDecorationsAreRemoved() {
        for title in ["Codex · Fix scrolling", "Fix scrolling · Codex", "Codex: Fix scrolling",
                      "Codex — Fix scrolling", "Fix scrolling - Codex", "Codex | Fix scrolling | Codex",
                      "  CODEX • Fix scrolling  "] {
            XCTAssertEqual(ChatTabTitle.display(title), "Fix scrolling", title)
        }
    }

    func testMeaningfulTitlesKeepTheirContent() {
        for title in ["Check Cerebras token speed in Codex", "Build a simpler Codex chat app",
                      "Codex settings", "Codex-generated titles", "New chat", "Previous chat", "Image chat",
                      "Fix scrolling · fork"] {
            XCTAssertEqual(ChatTabTitle.display(title), title)
        }
    }

    func testEmptyAndProviderOnlyTitlesUseOneFallback() {
        for title in ["", " \n ", "Codex", "CODEX", "Codex ·", "Codex · Codex"] {
            XCTAssertEqual(ChatTabTitle.display(title), "New chat", title)
        }
    }

    @MainActor
    func testTabsUseDisplayTitleForLabelsAndKeepStoredTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, title: "Codex · Fix scrolling", storageRoot: root)
        session.turn = "running"
        let column = ChatColumn()
        column.display(session)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let allButtons = buttons(in: column.view)
        let tab = try XCTUnwrap(allButtons.first { $0 is ChatTitleButton })
        XCTAssertEqual(tab.title, "Fix scrolling")
        XCTAssertTrue((tab as? ChatTitleButton)?.isRunning == true)
        XCTAssertTrue(tab.toolTip?.hasPrefix("Fix scrolling") == true)
        XCTAssertNotNil(tab.menu?.item(withTitle: "Close Chat"))
        XCTAssertEqual(session.title, "Codex · Fix scrolling")
        session.stop()
    }
}
