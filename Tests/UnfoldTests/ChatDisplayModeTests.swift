import AppKit
import XCTest
@testable import ThoughtStream

final class ChatDisplayModeTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func columns(_ controller: NSViewController) -> [ChatColumn] {
        (controller as? ChatColumn).map { [$0] } ?? controller.children.flatMap(columns)
    }

    @MainActor
    func testJustChatFillsTallAndShortPanesAndKeepsReceivingConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(project: root, storageRoot: root)
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        defer { session.stop(); window.close(); try? FileManager.default.removeItem(at: root) }
        column.display(session)
        column.prompt.string = "Unsent draft"
        column.setConversationFraction(0.4)
        session.report(.user, "Please explain this clearly.")
        session.report(.tool, "API_LOG_ONLY")
        session.report(.prose, "Here is the explanation.")
        try await Task.sleep(nanoseconds: 100_000_000)
        for height: CGFloat in [850, 340] {
            window.setContentSize(NSSize(width: 500, height: height))
            column.setDensity(PaneDensity.resolve(size: column.view.bounds.size, current: column.density))
            column.setDisplayMode(.justChat)
            column.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(column.stream.view.isHidden)
            XCTAssertFalse(column.conversation.isHidden)
            XCTAssertGreaterThan(column.conversation.bounds.height, height - 240)
            XCTAssertFalse(column.conversation.transcript.string.contains("API_LOG_ONLY"))
            XCTAssertTrue(column.conversation.transcript.string.contains("Here is the explanation."))
            let more = try XCTUnwrap(descendants(column.view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Chat options"
            })
            XCTAssertFalse(more.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(descendants(column.view).compactMap { $0 as? ConversationResizeHandle }.contains { !$0.isHiddenOrHasHiddenAncestor })
            column.setDisplayMode(.showLogs)
            column.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(column.stream.view.isHidden)
            XCTAssertEqual(column.conversationFraction, 0.4, accuracy: 0.001)
            XCTAssertEqual(column.prompt.string, "Unsent draft")
        }
        column.setDisplayMode(.justChat)
        session.report(.tool, "ANOTHER_API_LOG")
        session.report(.prose, "The conversation still updates.")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(column.conversation.transcript.string.contains("The conversation still updates."))
        XCTAssertFalse(column.conversation.transcript.string.contains("ANOTHER_API_LOG"))
        XCTAssertTrue(column.stream.records.contains { $0.text == "ANOTHER_API_LOG" })
    }

    @MainActor
    func testToolbarShortcutNewPanesAndSavedMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ChatDisplayModeTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = Session(project: root, title: "A readable conversation", storageRoot: root)
        session.report(.user, "What changed?")
        session.report(.tool, "API_LOG_ONLY")
        session.report(.prose, "You can show the logs or focus on our conversation.")
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: store, displayPreferences: preferences)
        let window = try XCTUnwrap(workspace.window)
        var created: [UUID] = []
        defer {
            workspace.stopAll(); window.close()
            created.forEach { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent($0.uuidString)) }
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        window.setContentSize(NSSize(width: 1120, height: 800))
        let content = try XCTUnwrap(window.contentView)
        let buttons = descendants(content).compactMap { $0 as? AddPaneButton }
        let settings = try XCTUnwrap(buttons.first { $0.title == "Settings" })
        let rebalance = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Rebalance" })
        let mode = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Chat display mode" })
        content.layoutSubtreeIfNeeded()
        let settingsFrame = content.convert(settings.bounds, from: settings)
        let rebalanceFrame = content.convert(rebalance.bounds, from: rebalance)
        let modeFrame = content.convert(mode.bounds, from: mode)
        // Settings closes the app section; Rebalance and the display mode share the view section.
        XCTAssertEqual(rebalanceFrame.minX - settingsFrame.maxX, WorkspaceHeaderRow.sectionSpacing, accuracy: 0.5)
        XCTAssertEqual(modeFrame.minX - rebalanceFrame.maxX, WorkspaceHeaderRow.spacing, accuracy: 0.5)
        XCTAssertEqual(modeFrame.midY, settingsFrame.midY, accuracy: 0.5)
        XCTAssertEqual(mode.title, "Just chat", "the button names the mode a click switches to")
        XCTAssertEqual(mode.state, .off)
        XCTAssertEqual(mode.shortcutTitle, "⇧⌘L")
        func preview(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_CHAT_MODE_PREVIEW"] else { return }
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        try preview("show-logs")
        mode.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.chatDisplayMode, .justChat)
        XCTAssertEqual(mode.title, "Show logs")
        XCTAssertEqual(mode.state, .off, "switching modes must not tint the button")
        XCTAssertEqual(preferences.string(forKey: ChatDisplayMode.defaultsKey), ChatDisplayMode.justChat.rawValue)
        XCTAssertTrue(columns(try XCTUnwrap(window.contentViewController)).allSatisfy { $0.stream.view.isHidden })
        try preview("just-chat")
        workspace.newChat(nil)
        let panes = columns(try XCTUnwrap(window.contentViewController))
        created = panes.compactMap { $0.session?.id }.filter { $0 != session.id }
        XCTAssertEqual(panes.count, 2)
        XCTAssertTrue(panes.allSatisfy { $0.displayMode == .justChat && !$0.conversation.isHidden })

        let restored = WorkspaceWindow(restoredSessions: [session], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("restore-check.json")), displayPreferences: preferences)
        defer { restored.stopAll(); restored.window?.close() }
        XCTAssertEqual(restored.chatDisplayMode, .justChat)
        let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldHelp = NSApp.helpMenu, oldServices = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows; NSApp.helpMenu = oldHelp; NSApp.servicesMenu = oldServices }
        AppDelegate().installMenu(for: workspace)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "L", charactersIgnoringModifiers: "L", isARepeat: false, keyCode: 37))
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertEqual(workspace.chatDisplayMode, .showLogs)
        XCTAssertTrue(panes.allSatisfy { !$0.stream.view.isHidden })
    }
}
