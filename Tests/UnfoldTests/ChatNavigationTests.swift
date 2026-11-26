import AppKit
import XCTest
@testable import ThoughtStream

final class ChatNavigationTests: XCTestCase {
    @MainActor
    private func withWorkspace(tabs: [[Int]], _ check: (WorkspaceWindow, [ChatColumn], [Session]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<3).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let panes = tabs.map { indices in
            PaneViewState(id: UUID(), session: indices.first.map { chats[$0].id },
                          tabs: indices.map { chats[$0].id }, tabOffset: 0)
        }
        let layout = panes.dropFirst().reduce(PaneLayout.pane(panes[0].id)) {
            .split(vertical: false, fraction: 0.5, first: $0, second: .pane($1.id))
        }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(layout: layout, panes: panes, focusedPane: panes[0].id)]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: Array(chats.reversed()), stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        try check(workspace, workspace.window?.contentViewController.map(columns) ?? [], chats)
    }


    @MainActor
    func testLegacyTabOrderBecomesChatOrderAndNavigationPreservesDrafts() throws {
        try withWorkspace(tabs: [[2, 0, 1]]) { workspace, regions, chats in
            XCTAssertEqual(regions.count, 3)
            XCTAssertEqual(regions.compactMap { $0.session?.id }, [chats[2].id, chats[0].id, chats[1].id])
            regions[0].prompt.string = "Keep this draft"
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[1].prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[0].prompt)
            XCTAssertEqual(regions[0].prompt.string, "Keep this draft")
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[2].prompt)
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[0].prompt)
        }
    }

    @MainActor
    func testDuplicateLegacyTabsCollapseAndNavigationWrapsBothWays() throws {
        try withWorkspace(tabs: [[0, 1], [0], [2]]) { workspace, regions, chats in
            XCTAssertEqual(regions.count, 3)
            regions[0].prompt.string = "Left draft"
            for index in [1, 2, 0] {
                workspace.selectNextTab(nil)
                XCTAssertTrue(workspace.window?.firstResponder === regions[index].prompt)
            }
            for index in [2, 1, 0] {
                workspace.selectPreviousTab(nil)
                XCTAssertTrue(workspace.window?.firstResponder === regions[index].prompt)
            }
            XCTAssertEqual(regions[0].prompt.string, "Left draft")
            XCTAssertEqual(Set(regions.compactMap { $0.session?.id }), Set(chats.map(\.id)))
        }
    }
    @MainActor
    func testShiftBracketKeyEquivalentsDispatchNavigationFromComposer() throws {
        try withWorkspace(tabs: [[0], [1]]) { workspace, panes, _ in
            let previousMenu = NSApp.mainMenu
            let previousWindowsMenu = NSApp.windowsMenu
            let previousHelpMenu = NSApp.helpMenu
            let previousServicesMenu = NSApp.servicesMenu
            defer {
                NSApp.mainMenu = previousMenu
                NSApp.windowsMenu = previousWindowsMenu
                NSApp.helpMenu = previousHelpMenu
                NSApp.servicesMenu = previousServicesMenu
            }
            let delegate = AppDelegate()
            delegate.installMenu(for: workspace)
            let menu = try XCTUnwrap(NSApp.mainMenu)
            for (characters, keyCode, destination) in [("}", UInt16(30), 1), ("{", UInt16(33), 0),
                                                       ("]", UInt16(30), 1), ("[", UInt16(33), 0)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .shift], timestamp: 0,
                    windowNumber: workspace.window?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode))
                XCTAssertTrue(menu.performKeyEquivalent(with: event))
                XCTAssertTrue(workspace.window?.firstResponder === panes[destination].prompt)
            }
        }
    }


    @MainActor
    func testLegacyEmptyRegionIsRemovedWhenOtherChatsAreOpen() throws {
        try withWorkspace(tabs: [[0], [], [1]]) { workspace, regions, _ in
            XCTAssertEqual(regions.count, 2)
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[1].prompt)
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === regions[0].prompt)
        }
    }
    @MainActor
    func testToolbarButtonsAndCommandBracketsFocusChats() throws {
        try withWorkspace(tabs: [[0], [1]]) { workspace, panes, _ in
            let content = try XCTUnwrap(workspace.window?.contentView)
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(content).compactMap { $0 as? AddPaneButton }
            let left = try XCTUnwrap(buttons.first { $0.title == "Focus Left" })
            let right = try XCTUnwrap(buttons.first { $0.title == "Focus Right" })
            let settings = try XCTUnwrap(buttons.first { $0.title == "Settings" })
            let mode = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Chat display mode" })
            let split = try XCTUnwrap(buttons.first { $0.title == "Split below" })
            let newChat = try XCTUnwrap(buttons.first { $0.title == "New Chat" })
            let commandBar = try XCTUnwrap(buttons.first { $0.title == "Command Bar" })
            let rebalance = try XCTUnwrap(buttons.first { $0.title == "Rebalance" })
            let sidebarButtons = descendants(content).compactMap { $0 as? NSButton }
            let projectUp = try XCTUnwrap(sidebarButtons.first { $0.accessibilityLabel() == "Project Up" })
            let projectDown = try XCTUnwrap(sidebarButtons.first { $0.accessibilityLabel() == "Project Down" })
            let header = try XCTUnwrap(commandBar.superview as? WorkspaceHeaderRow)
            XCTAssertEqual(left.shortcutTitle, "⌘[")
            XCTAssertEqual(right.shortcutTitle, "⌘]")
            for width: CGFloat in [860, 1120, 1440, 2000] {
                workspace.window?.setContentSize(NSSize(width: width, height: 800))
                content.layoutSubtreeIfNeeded()
                // App, view, navigate, create: a wider gap separates each purpose.
                let sections = [[commandBar, settings], [rebalance, mode], [left, right], [split, newChat]]
                let ordered = sections.flatMap { $0 }
                let sectionStarts = Set(sections.dropFirst().map { ObjectIdentifier($0[0]) })
                let frames = ordered.map { content.convert($0.bounds, from: $0) }
                for (index, (previous, next)) in zip(frames, frames.dropFirst()).enumerated() {
                    if abs(previous.midY - next.midY) < 0.5 {
                        let gap = sectionStarts.contains(ObjectIdentifier(ordered[index + 1]))
                            ? WorkspaceHeaderRow.sectionSpacing : WorkspaceHeaderRow.spacing
                        XCTAssertEqual(next.minX - previous.maxX, gap, accuracy: 0.5)
                    } else {
                        XCTAssertLessThan(next.maxY, previous.minY)
                    }
                }
                // Project navigation lives in the sidebar's Projects heading.
                XCTAssertFalse(projectUp.superview === header || projectDown.superview === header)
                XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 0.5)
                for rect in frames {
                    XCTAssertTrue(content.bounds.contains(rect))
                }
                for button in ordered {
                    XCTAssertTrue(button.superview === header)
                    XCTAssertFalse(button.isIconOnly)
                    XCTAssertEqual(button.bounds.width, ceil(button.intrinsicContentSize.width), accuracy: 0.5)
                    XCTAssertTrue(header.bounds.contains(button.frame))
                }
            }
            panes[0].prompt.string = "Keep this draft"
            right.performClick(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
            left.performClick(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[0].prompt)

            let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu
            let oldHelp = NSApp.helpMenu, oldServices = NSApp.servicesMenu
            defer {
                NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows
                NSApp.helpMenu = oldHelp; NSApp.servicesMenu = oldServices
            }
            let delegate = AppDelegate()
            delegate.installMenu(for: workspace)
            for (key, code, destination) in [("]", UInt16(30), 1), ("[", UInt16(33), 0)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: 0,
                    windowNumber: workspace.window?.windowNumber ?? 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
                XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
                XCTAssertTrue(workspace.window?.firstResponder === panes[destination].prompt)
            }
            XCTAssertEqual(panes[0].prompt.string, "Keep this draft")
        }
    }

    @MainActor
    func testOneChatIsANoOp() throws {
        try withWorkspace(tabs: [[0]]) { workspace, panes, chats in
            workspace.selectNextTab(nil)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(panes[0].session === chats[0])
            XCTAssertTrue(workspace.window?.firstResponder === panes[0].prompt)
        }
    }
}
