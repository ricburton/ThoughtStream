import AppKit
import XCTest
@testable import ThoughtStream

final class TabsOnlyTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testMergesOpenTabsAndRestoresOriginalPanesAndFocusedChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<3).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let ids = [UUID(), UUID()]
        let layout = PaneLayout.split(vertical: true, fraction: 0.6, first: .pane(ids[0]), second: .pane(ids[1]))
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(drafts: [chats[2].id: "Keep this draft"], selectedProject: root.path,
            projects: [root.path: ProjectViewState(layout: layout, panes: [
                PaneViewState(id: ids[0], session: chats[0].id, tabs: [chats[0].id, chats[1].id], tabOffset: 0),
                PaneViewState(id: ids[1], session: chats[2].id, tabs: [chats[1].id, chats[2].id], tabOffset: 0)
            ], focusedPane: ids[1])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.window?.setContentSize(NSSize(width: 1280, height: 900))
        let frame = workspace.window?.frame
        workspace.setLayoutMode(.tabs)
        XCTAssertEqual(workspace.window?.frame, frame)
        let tabbed = try XCTUnwrap(columns(workspace).first)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(tabbed.tabsOnly)
        XCTAssertFalse(tabbed.view is PaneSurface)
        XCTAssertEqual(tabbed.tabIDs, chats.map(\.id))
        XCTAssertTrue(tabbed.session === chats[2])
        XCTAssertEqual(tabbed.prompt.string, "Keep this draft")
        tabbed.prompt.string = "Edited in tabs"
        tabbed.onCloseChat?(1)
        workspace.setLayoutMode(.panes)
        XCTAssertEqual(columns(workspace).map(\.columnID), ids)
        XCTAssertEqual(columns(workspace).map(\.tabIDs), [[chats[0].id, chats[1].id], [chats[1].id, chats[2].id]])
        XCTAssertEqual(columns(workspace).last?.prompt.string, "Edited in tabs")
        XCTAssertTrue(workspace.window?.firstResponder === columns(workspace).last?.prompt)
        workspace.setLayoutMode(.tabs)
        XCTAssertEqual(columns(workspace).first?.tabIDs, [chats[0].id, chats[2].id])
        XCTAssertTrue(columns(workspace).first?.session === chats[2])
    }

    @MainActor
    func testTabsOpenCloseReopenAndPersistAcrossProjectsAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let chats = [Session(project: a, storageRoot: root), Session(project: a, storageRoot: root), Session(project: b, storageRoot: root)]
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: a.path, layoutMode: .tabs)); store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        XCTAssertEqual(workspace.layoutMode, .tabs)
        workspace.selectNextTab(nil)
        XCTAssertTrue(columns(workspace).first?.session === chats[1])
        columns(workspace)[0].prompt.string = "A draft"
        workspace.closeTab(nil)
        XCTAssertEqual(columns(workspace)[0].tabIDs, [chats[0].id])
        workspace.reopenClosedTab(nil)
        XCTAssertTrue(columns(workspace)[0].session === chats[1])
        XCTAssertEqual(columns(workspace)[0].prompt.string, "A draft")
        workspace.selectProject(b.path)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(columns(workspace)[0].session === chats[2])
        workspace.selectProject(a.path)
        XCTAssertTrue(columns(workspace)[0].session === chats[1])
        workspace.closeTab(nil)
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(restored.layoutMode, .tabs)
        XCTAssertEqual(columns(restored)[0].tabIDs, [chats[0].id])
        restored.closeTab(nil)
        XCTAssertNil(columns(restored)[0].session)
        XCTAssertTrue(columns(restored)[0].tabIDs.isEmpty)
        restored.stopAll()
        XCTAssertEqual(store.load()?.projects?[a.path]?.tabbed?.tabs, [])
        restored.reopenClosedTab(nil)
        XCTAssertTrue(columns(restored)[0].session === chats[0])
    }

    @MainActor
    func testNewTabAndCompactControlsHaveNoSplitBehavior() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, storageRoot: root)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, layoutMode: .tabs)); store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: store)
        var newChat: UUID?
        defer {
            workspace.stopAll(); workspace.window?.close()
            if let newChat { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(newChat.uuidString)) }
        }
        let column = columns(workspace)[0]
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(column.view)
        let buttons = views.compactMap { $0 as? NSButton }
        let add = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "New tab" })
        XCTAssertFalse(buttons.contains { ($0.accessibilityLabel() ?? "").localizedCaseInsensitiveContains("pane") })
        let tab = try XCTUnwrap(buttons.compactMap { $0 as? ChatTabButton }.first)
        XCTAssertNil(tab.dragPayload)
        XCTAssertFalse(tab.toolTip?.contains("split") ?? true)
        XCTAssertEqual(add.convert(add.bounds, to: column.view).midY, tab.convert(tab.bounds, to: column.view).midY, accuracy: 1)
        // Optional offscreen preview: this fixture never opens the main app.
        if let path = ProcessInfo.processInfo.environment["THOUGHTSTREAM_TABS_PREVIEW"] {
            chat.report(.user, "Try a simpler workspace with just tabs.")
            chat.report(.prose, "Open a chat with + and close it with ×. Each project remembers its open tabs and drafts.")
            let content = try XCTUnwrap(workspace.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        add.performClick(nil)
        newChat = column.session?.id
        XCTAssertEqual(column.tabIDs.count, 2)
        XCTAssertNotEqual(newChat, chat.id)
        XCTAssertTrue(workspace.window?.firstResponder === column.prompt)
        let payload = ChatTabDrag(sessionID: chat.id, columnID: column.columnID)
        XCTAssertFalse(workspace.canDropTab(payload, on: .right, in: column))
        XCTAssertFalse(workspace.dropTab(payload, on: .right, in: column))
        workspace.splitStream(nil); workspace.stackStream(nil); workspace.singlePane(nil)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertEqual(column.tabIDs.count, 2)
    }

    @MainActor
    func testViewMenuSelectsModeAndHidesPaneCommandsWithoutDuplicatingAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceWindow(restoredSessions: [Session(project: root, storageRoot: root)],
                                        stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        let previousMenu = NSApp.mainMenu, windows = NSApp.windowsMenu, help = NSApp.helpMenu, services = NSApp.servicesMenu
        defer {
            workspace.stopAll(); workspace.window?.close()
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = windows; NSApp.helpMenu = help; NSApp.servicesMenu = services
        }
        let delegate = AppDelegate(); delegate.installMenu(for: workspace)
        let view = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" })
        let layout = try XCTUnwrap(view.items.first { $0.title == "Layout" }?.submenu)
        let tabs = try XCTUnwrap(layout.items.first { $0.title == "Tabs Only" })
        workspace.chooseWorkspaceLayout(tabs)
        XCTAssertTrue(workspace.validateMenuItem(tabs)); XCTAssertEqual(tabs.state, .on)
        let splits = view.items.filter { $0.action == #selector(WorkspaceWindow.splitStream(_:)) }
        XCTAssertEqual(splits.count, 2)
        XCTAssertTrue(splits.allSatisfy { $0.isHidden && !$0.allowsKeyEquivalentWhenHidden && !workspace.validateMenuItem($0) })
        XCTAssertTrue(view.items.contains { $0.title == "Next Tab" })
        workspace.setLayoutMode(.panes)
        XCTAssertEqual(splits.filter { !$0.isHidden }.count, 1)
        XCTAssertTrue(splits.first { $0.isHidden }?.allowsKeyEquivalentWhenHidden == true)
        XCTAssertTrue(workspace.validateMenuItem(tabs)); XCTAssertEqual(tabs.state, .off)
    }

    func testLegacyStateDefaultsToPanesAndMigrationUsesFocusedStream() throws {
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{\"drafts\":{},\"streams\":{}}".utf8))
        XCTAssertNil(old.layoutMode)
        let chat = UUID(), left = UUID(), right = UUID()
        let state = ProjectViewState(layout: .split(vertical: true, fraction: 0.5, first: .pane(left), second: .pane(right)), panes: [
            PaneViewState(id: left, session: chat, tabs: [chat], tabOffset: 0, streams: [chat: StreamViewState(firstRecord: 2)]),
            PaneViewState(id: right, session: chat, tabs: [chat], tabOffset: 0, streams: [chat: StreamViewState(firstRecord: 12)])
        ], focusedPane: right)
        let migrated = state.tabbedState(fallbackTabs: [])
        XCTAssertEqual(migrated.tabs, [chat])
        XCTAssertEqual(migrated.streams[chat]?.firstRecord, 12)
        let empty = ProjectViewState(tabbed: TabbedViewState(tabs: []))
        XCTAssertTrue(empty.tabbedState(fallbackTabs: [chat]).tabs.isEmpty)
    }
}
