import AppKit
import XCTest
@testable import ThoughtStream

final class CopyFeedbackTests: XCTestCase {
    @MainActor
    func testCodeAndRawJSONHeadersFitPaddedCopyButtons() throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = NSAttributedString(string: "{\"ok\": true}", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let views: [(NSView, NativeFeedBlock)] = [
            (NativeCodeView(text: text, source: text.string, label: "JSON"), .code(text, source: text.string, label: "JSON")),
            (NativeFeedHeading(title: "Tool", time: "12:00", tone: .muted, size: 14, rawSource: text.string), .header("Tool", "12:00", .muted, 14, rawSource: text.string))
        ]
        for (view, block) in views {
            let frame = NSRect(x: 0, y: 0, width: 320, height: NativeFeedLayout.height(block, width: 320, images: [:]))
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            let copy = try XCTUnwrap(descendants(view).compactMap { $0 as? CopyFeedbackButton }.first)
            XCTAssertTrue(view.bounds.contains(copy.convert(copy.bounds, to: view)), "\(type(of: view)): \(view.bounds), copy \(copy.convert(copy.bounds, to: view))")
            XCTAssertGreaterThanOrEqual(copy.bounds.height, 28)
        }
    }

    @MainActor
    func testSuccessFollowsClipboardWriteAndPreservesLabelSize() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let payload = "print(\"hello\")\n"
        weak var observedButton: CopyFeedbackButton?
        let button = CopyFeedbackButton(text: payload, write: { text in
            XCTAssertEqual(observedButton?.isShowingSuccess, false)
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }, reduceMotion: { false })
        observedButton = button
        let size = button.intrinsicContentSize
        XCTAssertTrue(button.performCopy())
        XCTAssertEqual(pasteboard.string(forType: .string), payload)
        XCTAssertTrue(button.isShowingSuccess)
        XCTAssertEqual(button.contentTintColor, FeedPalette.green)
        XCTAssertEqual(button.layer?.borderWidth, 1)
        XCTAssertNotNil(check(in: button).contents)
        XCTAssertEqual(button.title, "Copy")
        XCTAssertEqual(button.intrinsicContentSize, size)
        XCTAssertNotNil(check(in: button).animation(forKey: "copy-success"))
    }

    @MainActor
    func testCheckmarkFitsImmediatelyBeforeCopyLabel() throws {
        for title in ["Copy", "Copy raw JSON"] {
            let button = CopyFeedbackButton(title: title, text: "source", write: { _ in true })
            XCTAssertEqual(button.image?.size, NSSize(width: 14, height: 14))
            XCTAssertGreaterThanOrEqual(button.intrinsicContentSize.height, 28)
            button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
            button.layoutSubtreeIfNeeded()
            let cell = try XCTUnwrap(button.cell)
            let icon = cell.imageRect(forBounds: button.bounds)
            let label = cell.titleRect(forBounds: button.bounds)
            XCTAssertGreaterThan(icon.width, 0)
            XCTAssertGreaterThan(label.width, 0)
            XCTAssertLessThanOrEqual(icon.maxX, label.minX)
            XCTAssertEqual(check(in: button).position.x, icon.midX, accuracy: 0.1)
            XCTAssertTrue(button.bounds.contains(check(in: button).frame))
            XCTAssertEqual(button.accessibilityLabel(), title)
        }
    }

    @MainActor
    func testFailureClearsPreviousSuccessAndDisabledButtonDoesNotWrite() {
        var succeeds = true
        var writes = 0
        let button = CopyFeedbackButton(text: "source", write: { _ in
            writes += 1
            return succeeds
        }, reduceMotion: { false })
        XCTAssertTrue(button.performCopy())
        succeeds = false
        XCTAssertFalse(button.performCopy())
        XCTAssertFalse(button.isShowingSuccess)
        XCTAssertEqual(check(in: button).opacity, 0)
        XCTAssertNil(check(in: button).animation(forKey: "copy-success"))
        button.isEnabled = false
        XCTAssertFalse(button.performCopy())
        XCTAssertEqual(writes, 2)
    }

    @MainActor
    func testReducedMotionUsesStaticCheckAndRespondsToPreferenceChange() {
        var reduced = false
        let button = CopyFeedbackButton(text: "source", write: { _ in true }, reduceMotion: { reduced })
        XCTAssertTrue(button.performCopy())
        XCTAssertNotNil(check(in: button).animation(forKey: "copy-success"))
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertNil(check(in: button).animation(forKey: "copy-success"))
        XCTAssertEqual(check(in: button).opacity, 1)
        XCTAssertTrue(button.performCopy())
        XCTAssertTrue(button.isShowingSuccess)
        XCTAssertEqual(check(in: button).opacity, 1)
        XCTAssertNil(check(in: button).animation(forKey: "copy-success"))
    }

    @MainActor
    func testRepeatedSuccessRestartsOneAnimationAndDetachmentClearsFeedback() {
        let button = CopyFeedbackButton(text: "source", write: { _ in true }, reduceMotion: { false })
        XCTAssertTrue(button.performCopy())
        XCTAssertTrue(button.performCopy())
        XCTAssertEqual(check(in: button).animationKeys(), ["copy-success"])
        button.viewDidMoveToWindow()
        XCTAssertFalse(button.isShowingSuccess)
        XCTAssertEqual(check(in: button).opacity, 0)
        XCTAssertNil(check(in: button).animation(forKey: "copy-success"))
    }

    @MainActor
    func testFeedbackExpiresAndKeepsHoverResponsive() async throws {
        let button = CopyFeedbackButton(text: "source", write: { _ in true }, reduceMotion: { false })
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        button.mouseEntered(with: event)
        XCTAssertEqual(button.contentTintColor, FeedPalette.blue)
        XCTAssertNotNil(button.layer?.animation(forKey: "copy-hover"))
        XCTAssertTrue(button.performCopy())
        button.mouseExited(with: event)
        XCTAssertEqual(button.contentTintColor, FeedPalette.green)
        XCTAssertTrue(button.isShowingSuccess)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(button.isShowingSuccess)
        XCTAssertEqual(button.contentTintColor, FeedPalette.muted)
        XCTAssertEqual(button.image?.size, NSSize(width: 14, height: 14))
        XCTAssertEqual(check(in: button).opacity, 0)
    }

    @MainActor
    private func check(in button: CopyFeedbackButton) -> CALayer {
        button.layer!.sublayers!.first { $0.name == "copy-success" }!
    }
}
