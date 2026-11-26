import AppKit
import QuartzCore
import XCTest
@testable import ThoughtStream

final class PaneCloseTransitionTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    func testMiddleChatContractsWhileNeighborsMoveAndDraftsSurvive() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion is disabled by the system")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chats = ["Plan the trip", "Closing this chat", "Build the prototype"].map {
            Session(project: root, title: $0, storageRoot: root)
        }
        let workspace = WorkspaceWindow(restoredSessions: chats,
            stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        window.setContentSize(NSSize(width: 1280, height: 760))
        workspace.arrangePanes(as: .columns)
        let content = try XCTUnwrap(window.contentView)
        @MainActor func columns(_ node: NSViewController) -> [ChatColumn] {
            (node as? ChatColumn).map { [$0] } ?? node.children.flatMap(columns)
        }
        let panes = columns(try XCTUnwrap(window.contentViewController))
        XCTAssertEqual(panes.count, 3)
        panes[0].prompt.string = "Keep the left draft"
        panes[2].prompt.string = "Keep the right draft"
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)

        workspace.closePane(panes[1])
        let transition = try XCTUnwrap(descendants(content).compactMap { $0 as? PaneCloseTransition }.first)
        let pictures = transition.subviews.compactMap { $0 as? PaneTransitionPicture }
        XCTAssertEqual(pictures.count, 3)
        XCTAssertNil(transition.hitTest(.zero))
        XCTAssertEqual(columns(try XCTUnwrap(window.contentViewController)).count, 2)
        let targetLeft = transition.convert(panes[0].view.bounds, from: panes[0].view)
        let targetRight = transition.convert(panes[2].view.bounds, from: panes[2].view)
        let closingStart = pictures[1].frame
        XCTAssertNotNil(pictures[1].layer?.animation(forKey: "paneDismiss"))
        CATransaction.flush()
        try await Task.sleep(nanoseconds: 70_000_000)
        let left = try XCTUnwrap(pictures[0].layer?.presentation()).frame
        let closing = try XCTUnwrap(pictures[1].layer?.presentation()).frame
        let right = try XCTUnwrap(pictures[2].layer?.presentation()).frame
        XCTAssertGreaterThan(closing.width, 0)
        XCTAssertLessThan(closing.width, closingStart.width)
        XCTAssertLessThan(closing.height, closingStart.height)
        XCTAssertLessThan(left.width, targetLeft.width)
        XCTAssertGreaterThan(right.minX, targetRight.minX)
        XCTAssertTrue(transition.isAnimating)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertNil(transition.superview)
        XCTAssertFalse(transition.isAnimating)
        XCTAssertEqual(panes[0].prompt.string, "Keep the left draft")
        XCTAssertEqual(panes[2].prompt.string, "Keep the right draft")
    }

    @MainActor
    func testInterruptedTransitionCanContinueAndCancelWithoutLeavingOverlay() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Motion is disabled by the system")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let ids = (0..<3).map { _ in UUID() }
        let panes = ids.enumerated().map { index, id in
            let pane = NSView(frame: NSRect(x: index * 300, y: 0, width: 300, height: 500))
            content.addSubview(pane)
            return (id, pane)
        }
        XCTAssertNil(PaneCloseTransition.capture(panes, in: content), "Hidden windows need no transition")
        window.orderFront(nil)
        let first = try XCTUnwrap(PaneCloseTransition.capture(panes, in: content))
        content.addSubview(first)
        var completions = 0
        first.animate(closing: ids[1],
            to: [ids[0]: NSRect(x: 0, y: 0, width: 450, height: 500),
                 ids[2]: NSRect(x: 450, y: 0, width: 450, height: 500)]) { completions += 1 }
        CATransaction.flush()
        try await Task.sleep(nanoseconds: 60_000_000)
        let continuing = try XCTUnwrap(PaneCloseTransition.capture([panes[0], panes[2]], in: content, continuing: first))
        let currentFrame = try XCTUnwrap(first.subviews.first?.layer?.presentation()).frame
        XCTAssertEqual(try XCTUnwrap(continuing.subviews.first).frame.minX, currentFrame.minX, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(continuing.subviews.first).frame.width, currentFrame.width, accuracy: 2)
        XCTAssertLessThan(try XCTUnwrap(first.subviews[1].layer?.presentation()).opacity, 1)
        first.cancel()
        first.cancel()
        XCTAssertEqual(completions, 1)
        XCTAssertNil(first.superview)
        content.addSubview(continuing)
        continuing.animate(closing: ids[0],
                            to: [ids[2]: content.bounds]) { completions += 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(continuing.superview)
        XCTAssertEqual(completions, 2)
    }
}
