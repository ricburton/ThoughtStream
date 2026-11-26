import AppKit
import XCTest
@testable import ThoughtStream

final class ChatRegionMigrationTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    func testLegacyGroupsExpandWithoutDuplicatingChatsAndPreserveFocusedStream() throws {
        let a = UUID(), b = UUID(), c = UUID(), left = UUID(), right = UUID()
        let state = ProjectViewState(layout: .split(vertical: false, fraction: 0.6, first: .pane(left), second: .pane(right)), panes: [
            PaneViewState(id: left, session: a, tabs: [a, b, c], tabOffset: 30, streams: [a: StreamViewState(firstRecord: 2)]),
            PaneViewState(id: right, session: c, tabs: [a, c], tabOffset: 0, streams: [c: StreamViewState(firstRecord: 12)])
        ], focusedPane: right)
        let result = state.chatRegionLayout(validIDs: [a, b, c], fallbackIDs: [])
        XCTAssertEqual(result.regions.compactMap(\.session), [a, b, c])
        XCTAssertEqual(result.regions.first?.id, left)
        XCTAssertEqual(result.regions.last?.id, right)
        XCTAssertEqual(result.focused, right)
        XCTAssertEqual(result.regions.last?.stream?.firstRecord, 12)
        guard case .split(let vertical, let fraction, _, _) = result.layout else { return XCTFail("Lost layout") }
        XCTAssertFalse(vertical); XCTAssertEqual(fraction, 0.6)
    }

    func testDeepSavedColumnLayoutRestoresShallowlyWithTheSameWidthsAndFocus() throws {
        let ids = (0..<193).map { _ in UUID() }
        let widths = ids.indices.map { Double(300 + $0) }
        var extent = widths[0]
        var tree = PaneLayout.pane(ids[0])
        for i in ids.indices.dropFirst() {
            tree = .split(vertical: true, fraction: extent / (extent + widths[i]),
                          first: tree, second: .pane(ids[i]))
            extent += widths[i] + 1
        }
        let regions = ids.map { ChatRegionState(id: $0, session: $0) }
        let state = ProjectViewState(regions: regions, layout: tree,
            paneCanvasSize: NSSize(width: extent, height: 800), focusedPane: ids[110])
        let restored = state.chatRegionLayout(validIDs: Set(ids), fallbackIDs: [])
        var measured: [Double] = []
        func measure(_ node: PaneLayout, width: Double, depth: Int) {
            switch node {
            case .pane:
                XCTAssertLessThanOrEqual(depth, 8)
                measured.append(width)
            case let .split(vertical, fraction, first, second):
                XCTAssertTrue(vertical)
                measure(first, width: (width - 1) * fraction, depth: depth + 1)
                measure(second, width: (width - 1) * (1 - fraction), depth: depth + 1)
            }
        }
        let layout = try XCTUnwrap(restored.layout)
        measure(layout, width: extent, depth: 0)
        XCTAssertEqual(layout.ids, ids)
        XCTAssertEqual(restored.focused, ids[110])
        for (actual, expected) in zip(measured, widths) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
    }

    @MainActor
    func testOffscreenRestoredTranscriptLoadsOnRevealAndKeepsItsReadingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<12).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let regions = chats.map { ChatRegionState(id: UUID(), session: $0.id, stream: StreamViewState(fontSize: 18)) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: ProjectViewState(
            regions: regions, layout: .arranged(regions.map(\.id), as: .columns), focusedPane: regions[0].id)]))
        store.flush()
        chats[11].report(.user, "Saved transcript")
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        let last = try XCTUnwrap(panes.last)
        XCTAssertFalse(panes[0].transcriptDeferred)
        XCTAssertTrue(last.transcriptDeferred)
        XCTAssertTrue(last.stream.records.isEmpty)
        let untouched = panes[8]
        workspace.select(11)
        XCTAssertFalse(last.transcriptDeferred)
        XCTAssertTrue(last.stream.records.contains { $0.text == "Saved transcript" })
        XCTAssertEqual(last.stream.viewState.fontSize, 18)
        workspace.stopAll()
        let saved = try XCTUnwrap(store.load()?.projects?[root.path]?.regions)
        XCTAssertEqual(saved.count, regions.count)
        XCTAssertEqual(saved.first { $0.id == untouched.columnID }?.stream?.fontSize, 18)
    }

    func testFocusedDuplicateWinsAndInvalidChatsAreDiscarded() {
        let chat = UUID(), missing = UUID(), left = UUID(), right = UUID()
        let state = ProjectViewState(layout: .split(vertical: true, fraction: 0.5, first: .pane(left), second: .pane(right)), panes: [
            PaneViewState(id: left, session: chat, tabs: [chat, missing], tabOffset: 0),
            PaneViewState(id: right, session: chat, tabs: [chat], tabOffset: 0, streams: [chat: StreamViewState(firstRecord: 12)])
        ], focusedPane: right)
        let result = state.chatRegionLayout(validIDs: [chat], fallbackIDs: [])
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertEqual(result.regions.first?.id, right)
        XCTAssertEqual(result.regions.first?.stream?.firstRecord, 12)
        XCTAssertEqual(result.layout, .pane(right))
    }

    @MainActor
    func testTabsOnlyWorkspaceMigratesOnceAndPersistsIndependentChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = (0..<3).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(drafts: [chats[1].id: "Keep this draft"], selectedProject: root.path,
            projects: [root.path: ProjectViewState(tabbed: TabbedViewState(selectedChat: chats[1].id, tabs: chats.map(\.id)))], layoutMode: .tabs))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let regions = columns(workspace)
        XCTAssertEqual(regions.compactMap { $0.session?.id }, chats.map(\.id))
        XCTAssertTrue(workspace.window?.firstResponder === regions[1].prompt)
        XCTAssertEqual(regions[1].prompt.string, "Keep this draft")
        regions[1].prompt.string = "Updated draft"
        workspace.stopAll()
        let saved = try XCTUnwrap(store.load())
        XCTAssertNil(saved.layoutMode)
        XCTAssertNil(saved.projects?[root.path]?.tabbed)
        XCTAssertNil(saved.projects?[root.path]?.panes)
        XCTAssertEqual(saved.projects?[root.path]?.regions?.count, 3)
        let restored = WorkspaceWindow(restoredSessions: chats.reversed(), stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(columns(restored).map(\.columnID), regions.map(\.columnID))
        XCTAssertEqual(columns(restored)[1].prompt.string, "Updated draft")
    }

    @MainActor
    func testNewChatCreatesRegionAndOpeningExistingChatOnlyFocusesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        var created: UUID?
        defer {
            workspace.stopAll(); workspace.window?.close()
            if let created { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(created.uuidString)) }
        }
        let first = try XCTUnwrap(columns(workspace).first)
        first.prompt.string = "Original draft"
        workspace.newChat(nil)
        let regions = columns(workspace)
        XCTAssertEqual(regions.count, 2)
        created = regions.last?.session?.id
        XCTAssertNotEqual(created, chat.id)
        XCTAssertTrue(regions[0] === first)
        XCTAssertEqual(first.prompt.string, "Original draft")
        workspace.select(0, in: regions[1])
        XCTAssertEqual(columns(workspace).count, 2)
        XCTAssertTrue(first.session === chat)
        XCTAssertTrue(first.isActivePane)
        XCTAssertEqual(first.prompt.string, "Original draft")
    }

    @MainActor
    func testNavigationUsesChatsProjectsModelsAndNoPaneOrTabCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [chat], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        let previousMenu = NSApp.mainMenu, windows = NSApp.windowsMenu, help = NSApp.helpMenu, services = NSApp.servicesMenu
        defer {
            workspace.stopAll(); workspace.window?.close()
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = windows; NSApp.helpMenu = help; NSApp.servicesMenu = services
        }
        AppDelegate().installMenu(for: workspace)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
        let menuItems = items(try XCTUnwrap(NSApp.mainMenu))
        let obsolete = menuItems.filter { $0.title.range(of: #"\b(panes?|tabs?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
        XCTAssertTrue(obsolete.isEmpty, obsolete.map(\.title).joined(separator: ", "))
        XCTAssertTrue(menuItems.contains { $0.title == "Split Right" })
        XCTAssertTrue(menuItems.contains { $0.title == "Split Below" })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(workspace.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let fields = views.compactMap { $0 as? NSTextField }
        let headings = try ["Chats", "Projects", "Models"].map { title in
            try XCTUnwrap(fields.first { $0.stringValue == title })
        }
        let positions = headings.map { $0.convert($0.bounds, to: content).midY }
        XCTAssertGreaterThan(positions[0], positions[1]); XCTAssertGreaterThan(positions[1], positions[2])
        XCTAssertFalse(views.compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "Add Pane" })
        XCTAssertEqual(views.compactMap { $0 as? ChatTitleButton }.count, 1)
    }

    @MainActor
    func testSplitAndMoveCommandsAndRenderWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalStyle = InterfaceStyle.current
        defer { InterfaceStyle.current = originalStyle }
        InterfaceStyle.current = .breathe
        let chats = ["One chat in each region", "Review the layout", "Keep the conversation going"].map {
            Session(project: root.appendingPathComponent("ThoughtStream"), title: $0, storageRoot: root)
        }
        for chat in chats {
            chat.report(.user, "Keep this conversation visible while I work on the others.")
            chat.report(.prose, "Each chat now has its own place. Drag the title to rearrange it, or use the menu to split above, below, or to the right.")
        }
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        var created: UUID?
        defer {
            workspace.stopAll(); workspace.window?.close()
            if let created { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(created.uuidString)) }
        }
        let window = try XCTUnwrap(workspace.window)
        window.setContentSize(NSSize(width: 1360, height: 960))
        let original = columns(workspace)
        workspace.select(1)
        workspace.moveChatLeft(nil)
        XCTAssertTrue(columns(workspace).first === original[1])
        workspace.moveChatRight(nil)
        XCTAssertTrue(columns(workspace)[1] === original[1])
        workspace.splitAbove(nil)
        let extra = try XCTUnwrap(columns(workspace).first { region in !original.contains(region) })
        created = extra.session?.id
        XCTAssertEqual(columns(workspace).count, 4)
        XCTAssertNotNil(created)
        workspace.closePane(extra)
        XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: chats[2].id, columnID: original[2].columnID), on: .bottom, in: original[1]))
        workspace.select(0)
        for region in columns(workspace) {
            region.stream.status.stringValue = "Ready"
            region.prompt.string = region.session === chats[0] ? "One conversation. One place." : ""
        }
        guard let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_CHAT_REGION_PREVIEW"] else { return }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let frame = content.superview ?? content
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("chat-regions-\(name).png"))
        }
    }

}
