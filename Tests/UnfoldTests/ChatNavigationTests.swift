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
    func testSinglePaneUsesTabOrderAndPreservesDraftsWhileWrapping() throws {
        try withWorkspace(tabs: [[2, 0, 1]]) { workspace, panes, chats in
            let pane = try XCTUnwrap(panes.first)
            pane.prompt.string = "Keep this draft"
            workspace.selectNextTab(nil)
            XCTAssertTrue(pane.session === chats[0])
            XCTAssertTrue(workspace.window?.firstResponder === pane.prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(pane.session === chats[2])
            XCTAssertEqual(pane.prompt.string, "Keep this draft")
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(pane.session === chats[1])
            workspace.selectNextTab(nil)
            XCTAssertTrue(pane.session === chats[2])
        }
    }

    @MainActor
    func testCrossesStackedPanesWithDuplicateChatsAndWrapsBothWays() throws {
        try withWorkspace(tabs: [[0, 1], [0], [2]]) { workspace, panes, chats in
            workspace.selectNextTab(nil)
            XCTAssertTrue(panes[0].session === chats[1])
            panes[0].prompt.string = "Left draft"
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
            XCTAssertTrue(panes[1].session === chats[0])
            XCTAssertEqual(panes[0].prompt.string, "Left draft")
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[2].prompt)
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[0].prompt)
            XCTAssertTrue(panes[0].session === chats[0])
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[2].prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[0].prompt)
            XCTAssertTrue(panes[0].session === chats[1])
            XCTAssertEqual(panes[0].prompt.string, "Left draft")
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
    func testEmptyPaneRemainsReachableInBothDirections() throws {
        try withWorkspace(tabs: [[0], [], [1]]) { workspace, panes, _ in
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
            XCTAssertNil(panes[1].session)
            workspace.selectNextTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[2].prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[1].prompt)
            workspace.selectPreviousTab(nil)
            XCTAssertTrue(workspace.window?.firstResponder === panes[0].prompt)
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
