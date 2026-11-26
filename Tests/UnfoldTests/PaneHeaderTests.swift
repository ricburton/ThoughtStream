import AppKit
import XCTest
@testable import ThoughtStream

final class PaneHeaderTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testTitleSitsAboveStatusBranchAndActionsAtEveryPaneWidth() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let title = "Keep each project's conversation layout when switching projects"
        let chat = Session(project: root, title: title, storageRoot: root)
        for style in [InterfaceStyle.standard, .breathe] {
            InterfaceStyle.current = style
            do {
                let column = ChatColumn()
                let window = NSWindow(contentViewController: column)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                column.display(chat)
                column.updateHeader()
                column.stream.status.stringValue = "Previous conversation loaded"
                column.stream.repository.stringValue = "main"
                column.stream.repository.isHidden = false
                for width: CGFloat in [170, 260, 380, 620] {
                    window.setContentSize(NSSize(width: width, height: 700))
                    column.view.layoutSubtreeIfNeeded()
                    let views = descendants(column.view)
                    let tab = try XCTUnwrap(views.compactMap { $0 as? ChatTitleButton }.first)
                    XCTAssertNil(views.compactMap { $0 as? NSButton }.first {
                        $0.accessibilityLabel() == "New chat"
                    })
                    let more = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
                        $0.accessibilityLabel() == "Chat options"
                    })
                    let close = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
                        $0.accessibilityLabel() == "Close chat"
                    })
                    let closeFrame = close.convert(close.bounds, to: column.view)
                    let titleFrame = tab.convert(tab.bounds, to: column.view)
                    let moreFrame = more.convert(more.bounds, to: column.view)
                    let statusFrame = column.stream.status.convert(column.stream.status.bounds, to: column.view)
                    let branchFrame = column.stream.repository.convert(column.stream.repository.bounds, to: column.view)
                    XCTAssertEqual(column.view.bounds.width, width, accuracy: 1)
                    XCTAssertEqual(tab.title, title)
                    XCTAssertTrue(tab.toolTip?.hasPrefix(title) == true)
                    XCTAssertNil(tab.enclosingScrollView)
                    XCTAssertGreaterThan(tab.bounds.width, width - 80)
                    let statusAlignment = column.stream.status.alignmentRect(forFrame: column.stream.status.frame)
                    let statusLeading = try XCTUnwrap(column.stream.status.superview).convert(statusAlignment, to: column.view).minX
                    XCTAssertEqual(titleFrame.minX, statusLeading, accuracy: 0.5)
                    XCTAssertEqual(titleFrame.minX, width - closeFrame.maxX, accuracy: 0.5)
                    XCTAssertEqual(closeFrame.minX - titleFrame.maxX, 8, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(titleFrame.minY, moreFrame.maxY)
                    XCTAssertEqual(statusFrame.midY, moreFrame.midY, accuracy: 2)
                    XCTAssertEqual(branchFrame.midY, moreFrame.midY, accuracy: 2)
                    XCTAssertLessThanOrEqual(statusFrame.maxX, branchFrame.minX)
                    XCTAssertLessThanOrEqual(branchFrame.maxX, moreFrame.minX)
                    XCTAssertTrue(column.view.bounds.contains(moreFrame))
                    XCTAssertTrue(column.view.bounds.contains(closeFrame))
                    let closeAlignment = try XCTUnwrap(close.superview).convert(close.alignmentRect(forFrame: close.frame), to: column.view)
                    let titleAlignment = try XCTUnwrap(tab.superview).convert(tab.alignmentRect(forFrame: tab.frame), to: column.view)
                    XCTAssertEqual(titleAlignment.maxY - closeAlignment.maxY, 1, accuracy: 0.5)
                    XCTAssertGreaterThan(closeFrame.minY, moreFrame.maxY)
                    XCTAssertGreaterThanOrEqual(closeFrame.width, 30)
                    XCTAssertGreaterThanOrEqual(closeFrame.height, 30)
                    XCTAssertFalse(close.isHiddenOrHasHiddenAncestor)
                    XCTAssertFalse(more.isHiddenOrHasHiddenAncestor)
                    if width == 380 {
                        let wrappedHeight = tab.bounds.height
                        chat.title = "Short title"
                        column.updateHeader()
                        column.view.layoutSubtreeIfNeeded()
                        XCTAssertLessThan(tab.bounds.height, wrappedHeight, "Short titles should not leave a blank second line")
                        chat.title = title
                        column.updateHeader()
                        column.view.layoutSubtreeIfNeeded()
                        XCTAssertEqual(tab.bounds.height, wrappedHeight, accuracy: 0.5)
                    }
                    if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_HEADER_PREVIEW"] {
                        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                            window.appearance = NSAppearance(named: appearance)
                            column.view.layoutSubtreeIfNeeded()
                            let rect = NSRect(x: 0, y: column.view.bounds.maxY - 100, width: width, height: 100)
                            let bitmap = try XCTUnwrap(column.view.bitmapImageRepForCachingDisplay(in: rect))
                            column.view.cacheDisplay(in: rect, to: bitmap)
                            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("header-\(style.rawValue)-\(Int(width))-\(name).png"))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testOverflowMenuKeepsChatAndPaneActionsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, storageRoot: root)
        let column = ChatColumn()
        column.display(chat)
        column.updateHeader()
        column.updateSplitAvailability(split: true, stack: true)
        var split = false, stack = false, closePane = false
        column.onSplit = { split = true }
        column.onSplitBelow = { stack = true }
        column.onClosePane = { closePane = true }
        let menu = column.makePaneMenu()
        for title in ["Split Right", "Split Below", "Close Chat"] {
            let item = try XCTUnwrap(menu.item(withTitle: title))
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertTrue(split); XCTAssertTrue(stack); XCTAssertTrue(closePane)
        closePane = false
        let close = try XCTUnwrap(descendants(column.view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Close chat"
        })
        close.performClick(nil)
        XCTAssertTrue(closePane, "The close button uses the same action as Close Chat in the menu")
        for title in ["New Chat", "Find in Activity…", "Follow Live Activity", "Larger Text", "Smaller Text", "Actual Size"] {
            XCTAssertNotNil(menu.item(withTitle: title))
        }
        column.updateSplitAvailability(split: false, stack: false)
        XCTAssertFalse(try XCTUnwrap(column.makePaneMenu().item(withTitle: "Split Right")).isEnabled)
    }
}
