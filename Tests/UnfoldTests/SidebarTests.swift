import AppKit
import XCTest
@testable import ThoughtStream

final class SidebarTests: XCTestCase {
    @MainActor
    func testProjectsFollowWorkingChatsThenRecentConversationActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        func chat(_ name: String, time: TimeInterval?) -> Session {
            let session = Session(project: root.appendingPathComponent(name), title: name, storageRoot: root)
            if let time {
                session.importSearchHistory([StreamRecord(kind: "You", text: name, time: Date(timeIntervalSince1970: time))])
            }
            return session
        }
        let older = chat("Older", time: 100), newest = chat("Newest", time: 300)
        let empty = chat("Empty", time: nil), working = chat("Working", time: 200)
        working.turn = "running"
        let workspace = WorkspaceWindow(restoredSessions: [older, newest, empty, working], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close(); try? FileManager.default.removeItem(at: root) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(workspace.window?.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Projects" })
        func names() -> [String] {
            (0..<table.numberOfRows).compactMap {
                (workspace.tableView(table, viewFor: nil, row: $0) as? SidebarProjectCell)?.textField?.stringValue
            }
        }
        XCTAssertEqual(names(), ["Working", "Newest", "Older", "Empty"])
        workspace.selectProject(working.project.path)
        workspace.selectProject(newest.project.path)
        older.report(.system, "Connected again")
        older.onStatus?("Ready")
        XCTAssertEqual(names(), ["Working", "Newest", "Older", "Empty"], "Connection bookkeeping must not reorder projects")
        older.report(.user, "Working on this project again")
        older.onStatus?("Ready")
        XCTAssertEqual(names(), ["Working", "Older", "Newest", "Empty"])
        XCTAssertEqual((workspace.tableView(table, viewFor: nil, row: table.selectedRow) as? SidebarProjectCell)?.textField?.stringValue, "Newest")
        working.turn = nil
        working.onStatus?("Ready")
        XCTAssertEqual(names(), ["Older", "Newest", "Working", "Empty"])
    }

    @MainActor
    func testLiveConversationsKeepTheirOrderUntilANewChatStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let planning = Session(project: root.appendingPathComponent("Design"), title: "Plan the layout", storageRoot: root)
        planning.report(.user, "Plan the layout")
        let working = Session(project: root.appendingPathComponent("Build"), title: "Build the app", storageRoot: root)
        working.turn = "test-running-turn"
        let draft = Session(project: planning.project, title: "New conversation", storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [planning, working, draft], stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        window.setContentSize(NSSize(width: 860, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(window.contentView)
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        let tables = descend(content).compactMap { $0 as? NSTableView }
        let live = try XCTUnwrap(tables.first { $0.accessibilityLabel() == "Live conversations" })
        let projects = try XCTUnwrap(tables.first { $0.accessibilityLabel() == "Projects" })
        XCTAssertEqual(live.numberOfRows, 2)
        XCTAssertEqual(projects.numberOfRows, 2)
        let first = try XCTUnwrap(workspace.tableView(live, viewFor: nil, row: 0) as? SidebarConversationCell)
        XCTAssertEqual(first.textField?.stringValue, "Plan the layout")
        func titles(_ owner: WorkspaceWindow, _ table: NSTableView) -> [String] {
            (0..<table.numberOfRows).compactMap {
                (owner.tableView(table, viewFor: nil, row: $0) as? SidebarConversationCell)?.textField?.stringValue
            }
        }
        let originalOrder = ["Plan the layout", "Build the app"]
        planning.turn = "another-running-turn"
        planning.report(.prose, "A new streamed response")
        planning.onStatus?("Working")
        XCTAssertEqual(titles(workspace, live), originalOrder)
        planning.turn = nil
        planning.onStatus?("Ready")
        XCTAssertEqual(titles(workspace, live), originalOrder)
        let liveRect = try XCTUnwrap(live.enclosingScrollView).convert(live.enclosingScrollView!.bounds, to: content)
        let projectsRect = try XCTUnwrap(projects.enclosingScrollView).convert(projects.enclosingScrollView!.bounds, to: content)
        XCTAssertGreaterThanOrEqual(liveRect.minY, projectsRect.maxY)
        XCTAssertGreaterThanOrEqual(liveRect.height, 80)
        XCTAssertGreaterThan(projectsRect.minY, 80)
        live.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(live.action), to: live.target, from: live))
        XCTAssertEqual(window.title, "Build the app")
        XCTAssertEqual(live.selectedRow, 1)
        XCTAssertTrue(working.turn != nil)
        working.turn = nil
        working.report(.prose, "The latest response")
        working.onStatus?("Ready")
        XCTAssertEqual(titles(workspace, live), originalOrder)
        draft.report(.user, "Start a new conversation")
        working.onStatus?("Ready")
        let newOrder = ["New conversation"] + originalOrder
        XCTAssertEqual(titles(workspace, live), newOrder)
        XCTAssertEqual(live.selectedRow, 2, "Selection follows the chat when a new chat appears")
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: [working, planning, draft], stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        let restoredContent = try XCTUnwrap(restored.window?.contentView)
        let restoredLive = try XCTUnwrap(descend(restoredContent).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Live conversations" })
        XCTAssertEqual(titles(restored, restoredLive), newOrder)
    }

    @MainActor
    func testManyProjectsLeaveRoomForLiveConversationsInCompactWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let sessions = (0..<12).map { Session(project: root.appendingPathComponent("Project \($0)"), storageRoot: root) }
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        window.setContentSize(NSSize(width: 860, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(window.contentView)
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        let live = try XCTUnwrap(descend(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Live conversations" })
        let scroll = try XCTUnwrap(live.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(scroll.bounds.height, 80)
        XCTAssertLessThanOrEqual(scroll.convert(scroll.bounds, to: content).maxY, content.bounds.maxY)
    }

    @MainActor
    func testSidebarDefaultsToTwoThirdsChatsAndRemembersResizing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceWindow(restoredSessions: [], stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        let content = try XCTUnwrap(window.contentView)
        let split = try XCTUnwrap(descend(content).compactMap { $0 as? SidebarSplitView }.first)
        for height: CGFloat in [800, 600] {
            window.setContentSize(NSSize(width: 1120, height: height))
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(split.subviews[0].frame.height / (split.bounds.height - split.dividerThickness), 2.0 / 3.0, accuracy: 0.01)
        }
        split.setPosition((split.bounds.height - split.dividerThickness) * 0.45, ofDividerAt: 0)
        XCTAssertEqual(split.chatFraction, 0.45, accuracy: 0.01)
        window.setContentSize(NSSize(width: 1120, height: 800))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews[0].frame.height / (split.bounds.height - split.dividerThickness), 0.45, accuracy: 0.01)
        workspace.stopAll()
        XCTAssertEqual(try XCTUnwrap(store.load()?.sidebarChatFraction), 0.45, accuracy: 0.01)
        let restored = WorkspaceWindow(restoredSessions: [], stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        let restoredContent = try XCTUnwrap(restored.window?.contentView)
        restoredContent.layoutSubtreeIfNeeded()
        let restoredSplit = try XCTUnwrap(descend(restoredContent).compactMap { $0 as? SidebarSplitView }.first)
        XCTAssertEqual(restoredSplit.subviews[0].frame.height / (restoredSplit.bounds.height - restoredSplit.dividerThickness), 0.45, accuracy: 0.01)
    }
}
