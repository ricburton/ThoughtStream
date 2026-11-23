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
    func testBreatheFoldsPaneChromeIntoOneRowAndStandardRestoresIt() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        InterfaceStyle.current = .standard
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = ["Parser", "A much longer conversation title that cannot fit", "Notes"].map {
            Session(project: root, title: $0, storageRoot: root)
        }
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 800))
        column.tabIDs = chats.map(\.id)
        column.display(chats[0])
        column.updateTabs(Array(chats.enumerated()), isSplit: true)
        column.view.layoutSubtreeIfNeeded()

        let split = try XCTUnwrap(button("Split pane to the right", in: column.view))
        let stack = try XCTUnwrap(button("Stack pane below", in: column.view))
        let close = try XCTUnwrap(button("Close pane", in: column.view))
        let more = try XCTUnwrap(button("Pane options", in: column.view))
        let follow = try XCTUnwrap(descendants(column.view).compactMap { $0 as? NSButton }.first { $0.title == "Follow live" })
        let stop = try XCTUnwrap(descendants(column.view).compactMap { $0 as? NSButton }.first { $0.title == "Stop" })
        let strip = try XCTUnwrap(descendants(column.view).compactMap { $0 as? ChatTabItem }.first?.enclosingScrollView)
        let standardStreamTop = column.stream.view.frame.maxY
        let standardStrip = strip.convert(strip.bounds, to: column.view)
        XCTAssertTrue(more.isHidden)
        XCTAssertFalse(follow.isHidden)
        XCTAssertFalse(stop.isHidden)

        InterfaceStyle.current = .breathe
        column.applyInterfaceStyle()
        column.view.layoutSubtreeIfNeeded()
        for removed in [split, stack, close, follow, stop] { XCTAssertTrue(removed.isHidden, removed.title) }
        XCTAssertFalse(more.isHidden)
        XCTAssertFalse(column.view.hasAmbiguousLayout)
        // Tabs share the buttons' row, and the feed takes the height that frees.
        let row = more.convert(more.bounds, to: column.view)
        let breatheStrip = strip.convert(strip.bounds, to: column.view)
        XCTAssertEqual(breatheStrip.midY, row.midY, accuracy: 1)
        XCTAssertLessThan(breatheStrip.maxX, row.minX)
        XCTAssertGreaterThan(column.stream.view.frame.maxY, standardStreamTop + 20)
        // Titles retain their first three words, so a crowded row scrolls.
        let tabs = descendants(column.view).compactMap { $0 as? ChatTabItem }
        XCTAssertEqual(tabs.count, 3)
        XCTAssertGreaterThan(tabs.map(\.frame.maxX).max() ?? 0, strip.contentSize.width)
        XCTAssertFalse(try XCTUnwrap(button("Show more tabs to the right", in: strip)).isHidden)
        XCTAssertLessThan(tabs[1].frame.width, Breathe.tabMaximum)
        let selection = try XCTUnwrap(descendants(column.view).first { $0 is BreatheTabSelection })
        XCTAssertFalse(selection.isHidden)
        XCTAssertEqual(selection.frame, tabs[0].frame)
        column.display(chats[2])
        column.updateTabs(Array(chats.enumerated()), isSplit: true)
        column.view.layoutSubtreeIfNeeded()
        // The surface slides to the newly selected tab.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let reselected = descendants(column.view).compactMap { $0 as? ChatTabItem }
        XCTAssertEqual(selection.frame, reselected[2].frame)

        InterfaceStyle.current = .standard
        column.applyInterfaceStyle()
        column.view.layoutSubtreeIfNeeded()
        for restored in [split, stack, close, follow, stop] { XCTAssertFalse(restored.isHidden, restored.title) }
        XCTAssertTrue(more.isHidden)
        XCTAssertTrue(selection.isHidden)
        XCTAssertEqual(column.stream.view.frame.maxY, standardStreamTop, accuracy: 0.5)
        XCTAssertEqual(strip.convert(strip.bounds, to: column.view), standardStrip)
        XCTAssertFalse(column.view.hasAmbiguousLayout)
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
        XCTAssertEqual(columns(workspace).count, 1)

        workspace.splitStream(nil)
        workspace.stackStream(nil)
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let open = columns(workspace)
        XCTAssertEqual(open.count, 3)
        for column in open {
            let host = try XCTUnwrap(column.view.superview as? TabSplitHostView)
            XCTAssertEqual(column.view.frame, host.bounds.insetBy(dx: PaneSurface.inset, dy: PaneSurface.inset))
            XCTAssertEqual(column.view.layer?.cornerRadius, PaneSurface.radius)
            XCTAssertFalse(column.view.hasAmbiguousLayout)
        }
        XCTAssertEqual(open[0].tabIDs, chats.map(\.id))

        // The header keeps Settings immediately before Add Pane in every style.
        let content = try XCTUnwrap(workspace.window?.contentView)
        func addPane() throws -> NSButton {
            let frame = try XCTUnwrap(content.superview)
            return try XCTUnwrap(descendants(frame).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Add Pane" })
        }
        func paneTop() -> CGFloat { content.bounds.maxY - open[0].view.convert(open[0].view.bounds, to: content).maxY }
        let frame = try XCTUnwrap(content.superview)
        let settings = try XCTUnwrap(button("Settings", in: frame))
        XCTAssertTrue(settings.isDescendant(of: content))
        let settingsFrame = settings.convert(settings.bounds, to: frame)
        let addFrame = try addPane().convert(addPane().bounds, to: frame)
        XCTAssertLessThan(settingsFrame.maxX, addFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.bounds.maxX - addFrame.maxX, 24)
        XCTAssertGreaterThanOrEqual(frame.bounds.maxY - addFrame.maxY, 12)
        XCTAssertFalse(descendants(try XCTUnwrap(settings.superview)).contains { $0 is NSProgressIndicator })
        XCTAssertTrue(settings.isBordered)
        XCTAssertEqual(settings.imagePosition, .imageLeading)
        XCTAssertNotNil(settings.image)
        XCTAssertEqual(try addPane().action, #selector(WorkspaceWindow.splitStream(_:)))
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
        XCTAssertEqual(columns(workspace).count, 2)
        XCTAssertEqual(columns(workspace)[0].tabIDs, chats.map(\.id))
    }
}
