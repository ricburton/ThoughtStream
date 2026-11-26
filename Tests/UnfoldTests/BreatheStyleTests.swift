import AppKit
import XCTest
@testable import ThoughtStream

final class BreatheStyleTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor
    private func button(_ label: String, in view: NSView) -> NSButton? {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }
    }
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    func testLongTitlesGiveWayBeforeShortOnes() {
        // Everything fits: nothing changes.
        XCTAssertEqual(Breathe.tabWidths([90, 200, 120], available: 600, spacing: 2), [90, 200, 120])
        // Only the tab that is too long is shortened.
        let fitted = Breathe.tabWidths([90, 220, 120], available: 380, spacing: 2)
        XCTAssertEqual(fitted[0], 90)
        XCTAssertEqual(fitted[2], 120)
        XCTAssertLessThan(fitted[1], 220)
        XCTAssertLessThanOrEqual(fitted.reduce(0, +) + 4, 380)
        XCTAssertGreaterThan(fitted.reduce(0, +) + 4, 376, "The row is used, not left half empty")
        // Too many to fit: each keeps its minimum and the strip scrolls.
        XCTAssertEqual(Breathe.tabWidths(Array(repeating: 160, count: 8), available: 300, spacing: 2),
                       Array(repeating: 76, count: 8))
        XCTAssertEqual(Breathe.tabFrame(at: 2, widths: [90, 100, 120], spacing: 2, height: 38),
                       NSRect(x: 194, y: 0, width: 120, height: 38))
    }

    @MainActor
    func testStylesKeepSingleTitleAboveCompactChatControls() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = Session(project: root, title: "A long conversation title that wraps across the header", storageRoot: root)
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 800))
        column.display(chat)
        for style in [InterfaceStyle.standard, .breathe, .standard] {
            InterfaceStyle.current = style
            column.applyInterfaceStyle(); column.view.layoutSubtreeIfNeeded()
            let more = try XCTUnwrap(button("Chat options", in: column.view))
            let row = more.convert(more.bounds, to: column.view)
            let title = column.chatTitle.convert(column.chatTitle.bounds, to: column.view)
            XCTAssertGreaterThanOrEqual(title.minY, row.maxY)
            XCTAssertEqual(descendants(column.view).compactMap { $0 as? ChatTitleButton }.count, 1)
            XCTAssertNil(column.chatTitle.enclosingScrollView)
            XCTAssertFalse(descendants(column.view).contains { $0 is BreatheTabSelection })
            XCTAssertFalse(column.view.hasAmbiguousLayout)
        }
    }

    @MainActor
    func testLatestPillStandsInForFollowLive() async throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        InterfaceStyle.current = .breathe
        let pane = StreamPane()
        let window = NSWindow(contentViewController: pane)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 760, height: 520))
        pane.replace((0..<40).map { StreamRecord(kind: "Agent", text: "Paragraph \($0). " + String(repeating: "More words follow. ", count: 12)) })
        pane.view.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(descendants(pane.view).first { $0 is FeedLatestPill } as? FeedLatestPill)
        XCTAssertTrue(pane.followsLive)
        XCTAssertFalse(pill.isShown)

        // Reading earlier activity pauses following and offers the way back.
        var earlier = pane.viewState
        earlier.firstRecord = 3; earlier.offset = 0; earlier.follows = false
        pane.restoreViewState(earlier)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(pane.followsLive)
        XCTAssertTrue(pill.isShown)
        XCTAssertFalse(pill.isHidden)

        pill.performClick(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(pane.followsLive)
        XCTAssertFalse(pill.isShown)
        let feed = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Native conversation and live activity" })
        XCTAssertEqual(try XCTUnwrap(feed.enclosingScrollView).documentVisibleRect.maxY, feed.bounds.maxY, accuracy: 2)

        // The pill belongs to Breathe alone.
        pane.pauseLiveActivity()
        InterfaceStyle.current = .standard
        pane.applyInterfaceStyle()
        XCTAssertFalse(pill.isShown)
    }

    @MainActor
    func testPanesOpenAndCloseInBreatheKeepingEveryChat() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        InterfaceStyle.current = .breathe
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = ["Fix the parser", "Release notes", "Ideas"].map { Session(project: root, title: $0, storageRoot: root) }
        for chat in chats { chat.importSearchHistory(Sample.records) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let pane = UUID()
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path: ProjectViewState(layout: .pane(pane),
            panes: [PaneViewState(id: pane, session: chats[0].id, tabs: chats.map(\.id), tabOffset: 0)], focusedPane: pane)]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: chats, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.window?.setContentSize(NSSize(width: 1440, height: 900))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(columns(workspace).count, 3)

        workspace.splitStream(nil)
        workspace.stackStream(nil)
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let open = columns(workspace)
        let created = open.compactMap { $0.session?.id }.filter { !chats.map(\.id).contains($0) }
        defer { for id in created { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(id.uuidString)) } }
        XCTAssertEqual(open.count, 5)
        for column in open {
            let host = try XCTUnwrap(column.view.superview as? TabSplitHostView)
            XCTAssertEqual(column.view.frame, host.bounds.insetBy(dx: PaneSurface.inset, dy: PaneSurface.inset))
            XCTAssertEqual(column.view.layer?.cornerRadius, PaneSurface.radius)
            XCTAssertFalse(column.view.hasAmbiguousLayout)
        }
        XCTAssertEqual(Set(open.compactMap { $0.session?.id }).intersection(chats.map(\.id)), Set(chats.map(\.id)))

        // The header uses the same shortcut button treatment for all three actions.
        let content = try XCTUnwrap(workspace.window?.contentView)
        func addPane() throws -> NSButton {
            let frame = try XCTUnwrap(content.superview)
            return try XCTUnwrap(descendants(frame).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "New Chat" })
        }
        func paneTop() -> CGFloat { content.bounds.maxY - open[0].view.convert(open[0].view.bounds, to: content).maxY }
        let frame = try XCTUnwrap(content.superview)
        let settings = try XCTUnwrap(button("Settings", in: frame))
        XCTAssertTrue(settings.isDescendant(of: content))
        let settingsFrame = settings.convert(settings.bounds, to: frame)
        let addFrame = try addPane().convert(addPane().bounds, to: frame)
        XCTAssertLessThan(settingsFrame.maxX, addFrame.minX)
        XCTAssertEqual(frame.bounds.maxX - addFrame.maxX, 12, accuracy: 1)
        XCTAssertGreaterThanOrEqual(frame.bounds.maxY - addFrame.maxY, 12)
        XCTAssertFalse(descendants(try XCTUnwrap(settings.superview)).contains { $0 is NSProgressIndicator })
        let settingsAction = try XCTUnwrap(settings as? AddPaneButton)
        let newChat = try XCTUnwrap(button("New Chat", in: frame) as? AddPaneButton)
        let addAction = try XCTUnwrap(try addPane() as? AddPaneButton)
        XCTAssertEqual(settingsAction.symbolName, "gearshape")
        XCTAssertEqual(settingsAction.shortcutTitle, "⌘,")
        XCTAssertEqual(newChat.shortcutTitle, "⌘N")
        XCTAssertEqual(addAction.shortcutTitle, "⌘N")
        XCTAssertFalse(settingsAction.isIconOnly)
        XCTAssertEqual(settingsAction.title, "Settings")
        XCTAssertGreaterThanOrEqual(settingsAction.bounds.width, 136)
        XCTAssertEqual(settingsAction.bounds.height, newChat.bounds.height)
        XCTAssertEqual(settingsAction.bounds.height, addAction.bounds.height)
        XCTAssertEqual(settingsAction.action, #selector(WorkspaceWindow.showSettings(_:)))
        XCTAssertEqual(try addPane().action, #selector(WorkspaceWindow.newChat(_:)))
        XCTAssertTrue(try addPane().isDescendant(of: content))
        XCTAssertEqual(workspace.window?.titlebarAccessoryViewControllers.count, 0)
        let breatheTop = paneTop()
        InterfaceStyle.current = .standard
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(try addPane().isDescendant(of: content))
        XCTAssertTrue(settings.isDescendant(of: content))
        XCTAssertEqual(workspace.window?.titlebarAccessoryViewControllers.count, 0)
        let standardButton = try addPane()
        let standardButtonFrame = standardButton.convert(standardButton.bounds, to: content)
        XCTAssertGreaterThan(paneTop(), content.bounds.maxY - standardButtonFrame.minY)
        InterfaceStyle.current = .breathe
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneTop(), breatheTop, accuracy: 0.5)

        if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_PANE_PREVIEW"],
           let content = workspace.window?.contentView {
            // The window follows the application's appearance in every style but Matrix.
            let application = NSApplication.shared
            let systemAppearance = application.appearance
            defer { application.appearance = systemAppearance }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for style in [InterfaceStyle.breathe, .standard] {
                    application.appearance = NSAppearance(named: appearance)
                    InterfaceStyle.current = style
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    content.layoutSubtreeIfNeeded()
                    // The window frame view, so the title bar is in the picture.
                    let frameView = content.superview ?? content
                    let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(style.rawValue)-\(name).png"))
                }
            }
            InterfaceStyle.current = .breathe
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        workspace.closeFocusedPane(nil)
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(columns(workspace).count, 4)
        XCTAssertTrue(chats.allSatisfy { chat in columns(workspace).contains { $0.session === chat } })
    }
}
