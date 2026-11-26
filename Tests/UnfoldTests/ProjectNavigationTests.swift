import AppKit
import XCTest
@testable import ThoughtStream

final class ProjectNavigationTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testButtonsAndShortcutsFollowRecencySkipHistoryAndPreserveDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let chats = (0..<3).map { index in
            let chat = Session(project: root.appendingPathComponent("Project \(index)"), title: "Chat \(index)", storageRoot: root)
            chat.importSearchHistory([StreamRecord(kind: "You", text: "Work \(index)", time: Date(timeIntervalSince1970: Double(index + 1)))])
            return chat
        }
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
        let window = try XCTUnwrap(workspace.window)
        let content = try XCTUnwrap(window.contentView)
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        let up = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Project Up" })
        let down = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Project Down" })
        XCTAssertEqual(up.toolTip, "Project Up (⌘⇧↑)")
        XCTAssertEqual(down.toolTip, "Project Down (⌘⇧↓)")
        XCTAssertTrue(up.isEnabled && down.isEnabled)
        let open = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Open Project…" })
        let newChat = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "New chat" })
        let heading = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Projects" })
        let table = try XCTUnwrap(workspace.projectHistoryTable.enclosingScrollView)
        XCTAssertFalse(up.superview is WorkspaceHeaderRow)
        XCTAssertTrue(up.superview === down.superview && up.superview === open.superview)
        XCTAssertTrue(heading.superview === open.superview)
        // The sidebar is narrowest in the smallest window; the heading must still fit.
        for size in [NSSize(width: 860, height: 600), NSSize(width: 1440, height: 900)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            let frames = [open, up, down].map { $0.convert($0.bounds, to: content) }
            let headingFrame = heading.convert(heading.bounds, to: content)
            let tableFrame = table.convert(table.bounds, to: content)
            let newChatFrame = newChat.convert(newChat.bounds, to: content)
            XCTAssertGreaterThanOrEqual(tableFrame.height, 28)
            // Projects, then Open Project, Project Up and Project Down: one row above the list.
            XCTAssertLessThanOrEqual(headingFrame.maxX, frames[0].minX)
            XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX + 0.5)
            XCTAssertLessThanOrEqual(frames[1].maxX, frames[2].minX + 0.5)
            XCTAssertEqual(frames[2].maxX, newChatFrame.maxX, accuracy: 0.5)
            for (button, frame) in zip([open, up, down], frames) {
                // The same quiet glyph as New chat at the top of the sidebar.
                XCTAssertFalse(button is AddPaneButton)
                XCTAssertFalse(button.isBordered)
                XCTAssertEqual(button.imagePosition, .imageOnly)
                XCTAssertEqual(button.contentTintColor, newChat.contentTintColor)
                // Glyphs differ in drawn size; their layout boxes match.
                XCTAssertEqual(button.alignmentRect(forFrame: button.frame).size, newChat.alignmentRect(forFrame: newChat.frame).size)
                XCTAssertEqual(frame.midY, headingFrame.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(frame.minY, tableFrame.maxY)
                XCTAssertTrue(content.bounds.contains(frame))
            }
        }
        workspace.selectProject(chats[2].project.path)
        workspace.toggleProjectHistory(chats[2].project.path)
        XCTAssertEqual(workspace.projectHistoryTable.numberOfRows, 4)
        let composer = try XCTUnwrap(window.firstResponder as? ComposerTextView)
        composer.string = "Keep this project draft"
        down.performClick(nil)
        XCTAssertEqual(window.title, "Chat 1")
        down.performClick(nil)
        XCTAssertEqual(window.title, "Chat 0")
        down.performClick(nil)
        XCTAssertEqual(window.title, "Chat 2")
        XCTAssertEqual((window.firstResponder as? ComposerTextView)?.string, "Keep this project draft")
        up.performClick(nil)
        XCTAssertEqual(window.title, "Chat 0")

        let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu
        let oldHelp = NSApp.helpMenu, oldServices = NSApp.servicesMenu
        defer {
            NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows
            NSApp.helpMenu = oldHelp; NSApp.servicesMenu = oldServices
        }
        let delegate = AppDelegate()
        delegate.installMenu(for: workspace)
        for (key, code, title) in [(NSUpArrowFunctionKey, UInt16(126), "Chat 1"),
                                    (NSDownArrowFunctionKey, UInt16(125), "Chat 0")] {
            let character = String(UnicodeScalar(key)!)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
            XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
            XCTAssertEqual(window.title, title)
        }
    }

    @MainActor
    func testNavigationIsDisabledWithFewerThanTwoProjects() throws {
        for count in 0...1 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let chats = (0..<count).map { _ in Session(project: root, storageRoot: root) }
            let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
            defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
            let content = try XCTUnwrap(workspace.window?.contentView)
            let buttons = descendants(content).compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Project ") == true }
            XCTAssertEqual(buttons.count, 2)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
            XCTAssertFalse(workspace.validateMenuItem(NSMenuItem(title: "Project Up",
                action: #selector(WorkspaceWindow.selectPreviousProject(_:)), keyEquivalent: "")))
            workspace.selectPreviousProject(nil)
            workspace.selectNextProject(nil)
        }
    }
}
