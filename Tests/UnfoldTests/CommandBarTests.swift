import AppKit
import XCTest
@testable import ThoughtStream

final class CommandBarTests: XCTestCase {
    @MainActor
    func testFilteringNavigationExecutionAndFocusRestoration() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let composer = NSTextField(frame: NSRect(x: 20, y: 20, width: 400, height: 40))
        composer.stringValue = "Keep this draft"
        owner.contentView?.addSubview(composer)
        owner.makeFirstResponder(composer)
        let previous = owner.firstResponder
        let bar = CommandBar()
        defer { bar.dismiss(); owner.close() }
        var selected = ""
        let items = [
            CommandBarItem(id: "new", title: "New Chat", detail: "Action", symbol: "plus", keywords: "conversation") { selected = "new" },
            CommandBarItem(id: "project", title: "Café robotics", detail: "Project · work", symbol: "folder") { selected = "project" }
        ]
        bar.show(in: owner, items: items) { selected = $0 }
        XCTAssertTrue(bar.isVisible)
        XCTAssertTrue(bar.panel.parent === owner)
        XCTAssertEqual(bar.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNotNil(bar.field.currentEditor())
        bar.moveSelection(by: -1)
        XCTAssertEqual(bar.table.selectedRow, 1)
        bar.moveSelection(by: 1)
        XCTAssertEqual(bar.table.selectedRow, 0)
        bar.field.stringValue = "work cafe"
        bar.updateResults()
        XCTAssertEqual(bar.results.map(\.id), ["project", "history"])
        bar.activateSelection()
        XCTAssertEqual(selected, "project")
        XCTAssertFalse(bar.isVisible)
        XCTAssertNil(bar.panel.parent)
        XCTAssertTrue(owner.firstResponder === previous)
        XCTAssertEqual(composer.stringValue, "Keep this draft")
        bar.show(in: owner, items: items) { selected = $0 }
        bar.field.stringValue = "no title matches this"
        bar.updateResults()
        XCTAssertEqual(bar.results.map(\.id), ["history"])
        bar.activateSelection()
        XCTAssertEqual(selected, "no title matches this")
    }

    @MainActor
    func testEscapeClosesFromSearchFieldAndClearsQueryOnReopen() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 860, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let bar = CommandBar()
        defer { bar.dismiss(); owner.close() }
        bar.show(in: owner, items: []) { _ in XCTFail("Escape should never search") }
        bar.field.stringValue = "unfinished"
        let editor = try XCTUnwrap(bar.field.currentEditor() as? NSTextView)
        XCTAssertTrue(bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(bar.isVisible)
        bar.show(in: owner, items: []) { _ in }
        XCTAssertEqual(bar.field.stringValue, "")
        owner.close()
        XCTAssertFalse(bar.isVisible)
    }

    @MainActor
    func testButtonAndCommandSlashToggleSameDarkPanelAndRunWorkspaceAction() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceWindow(restoredSessions: [], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { workspace.stopAll(); workspace.window?.close() }
        let content = try XCTUnwrap(workspace.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? AddPaneButton }.first { $0.accessibilityLabel() == "Command Bar" })
        XCTAssertEqual(button.shortcutTitle, "⌘/")
        XCTAssertTrue(button.superview is WorkspaceHeaderRow)
        workspace.window?.setContentSize(NSSize(width: 860, height: 600))
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(button.bounds.width, button.intrinsicContentSize.width)
        let sidebar = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarSplitView }.first)
        let originalFraction = sidebar.chatFraction
        sidebar.setPosition(0, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        let chats = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Chats" })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(chats.enclosingScrollView).bounds.height, 80)
        sidebar.setPosition((sidebar.bounds.height - sidebar.dividerThickness) * originalFraction, ofDividerAt: 0)
        button.performClick(nil)
        XCTAssertTrue(workspace.commandBar.isVisible)
        let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldHelp = NSApp.helpMenu, oldServices = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows; NSApp.helpMenu = oldHelp; NSApp.servicesMenu = oldServices }
        let delegate = AppDelegate(); delegate.installMenu(for: workspace)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: workspace.window?.windowNumber ?? 0, context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertFalse(workspace.commandBar.isVisible)
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertTrue(workspace.commandBar.isVisible)
        XCTAssertFalse(workspace.commandBar.results.contains { $0.id == "focusNextPane:" })
        let bar = workspace.commandBar
        bar.panel.contentView?.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_COMMAND_PREVIEW"], let view = bar.panel.contentView {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                workspace.window?.appearance = NSAppearance(named: name)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("command-bar-\(name.rawValue).png"))
            }
        }
        let previousMode = workspace.chatDisplayMode
        bar.field.stringValue = previousMode == .showLogs ? "just chat" : "show logs"
        bar.updateResults()
        bar.activateSelection()
        XCTAssertNotEqual(workspace.chatDisplayMode, previousMode)
        XCTAssertFalse(bar.isVisible)
    }
}
