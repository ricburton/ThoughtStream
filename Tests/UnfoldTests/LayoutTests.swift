import AppKit
import XCTest
@testable import ThoughtStream

final class LayoutTests: XCTestCase {
    @MainActor
    func testWelcomeAndComposerFitNormalAndCompactWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
        let session = Session(project: directory, storageRoot: directory)
        let controller = WorkspaceWindow(restoredSessions: [], stateStore: store)
        let window = try XCTUnwrap(controller.window)
        defer { controller.stopAll(); window.close(); try? FileManager.default.removeItem(at: directory) }
        for size in [NSSize(width: 1120, height: 800), NSSize(width: 860, height: 600)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let root = window.contentView else { XCTFail("Missing content"); return }
            func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
            let all = descend(root)
            let welcome = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.stringValue == "See the work unfold." })
            let welcomeRect = welcome.convert(welcome.bounds, to: root)
            XCTAssertGreaterThan(welcomeRect.minX, 200)
            XCTAssertLessThan(welcomeRect.maxX, root.bounds.width)
            XCTAssertLessThan(welcomeRect.maxY, root.bounds.height)
            let pickers = all.compactMap { $0 as? NSPopUpButton }.filter { ["Model", "Reasoning effort", "Speed"].contains($0.accessibilityLabel() ?? "") }
            XCTAssertEqual(pickers.count, 3)
            for picker in pickers {
                let rect = picker.convert(picker.bounds, to: root)
                XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
                XCTAssertGreaterThan(rect.width, 60)
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThan(rect.maxX, 280)
                XCTAssertLessThan(rect.maxY, 120)
            }
        }
        let chat = WorkspaceWindow(restoredSessions: [session], stateStore: store)
        let chatWindow = try XCTUnwrap(chat.window)
        defer { chat.stopAll(); chatWindow.close() }
        for size in [NSSize(width: 1120, height: 800), NSSize(width: 860, height: 600)] {
            chatWindow.setContentSize(size)
            chatWindow.contentView?.layoutSubtreeIfNeeded()
            let root = try XCTUnwrap(chatWindow.contentView)
            func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
            let composer = try XCTUnwrap(descend(root).compactMap { $0 as? ComposerTextView }.first)
            let rect = composer.convert(composer.bounds, to: root)
            XCTAssertGreaterThan(rect.width, 400)
            XCTAssertGreaterThan(rect.height, 50)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width + 1)
        }
    }
    @MainActor
    func testLongSwiftFileHeightMatchesRenderedGlyphs() throws {
        let source = String(repeating: "    let message = \"A Swift line with words that wrap across a narrow pane\"\n", count: 400)
        let style = NSMutableParagraphStyle(); style.lineSpacing = 2
        let text = NSAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .paragraphStyle: style
        ])
        XCTAssertGreaterThan(text.length, 16_384)
        for width: CGFloat in [240, 600, 1000] {
            let view = NativeFeedTextView(text)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 100_000)
            let container = try XCTUnwrap(view.textContainer)
            let layout = try XCTUnwrap(view.layoutManager)
            layout.ensureLayout(for: container)
            XCTAssertEqual(NativeFeedLayout.textHeight(text, width: width),
                           ceil(layout.usedRect(for: container).height) + 4, accuracy: 1)
        }
    }

}
