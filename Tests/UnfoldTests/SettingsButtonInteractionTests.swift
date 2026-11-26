import AppKit
import XCTest
@testable import ThoughtStream

final class SettingsButtonInteractionTests: XCTestCase {
    @MainActor
    func testButtonAndCommandCommaOpenTheSameSettingsWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceWindow(restoredSessions: [], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { workspace.stopAll(); workspace.window?.close() }
        let content = try XCTUnwrap(workspace.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? AddPaneButton }.first { $0.accessibilityLabel() == "Settings" })
        XCTAssertFalse(button.isIconOnly)
        XCTAssertEqual(button.title, "Settings")
        XCTAssertEqual(button.shortcutTitle, "⌘,")
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.bounds.width, button.intrinsicContentSize.width, accuracy: 0.5)
        XCTAssertLessThan(button.bounds.width, 136)
        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/thoughtstream-settings-button.png"))
        let point = content.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        XCTAssertTrue(content.hitTest(point) === button)
        button.performClick(nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Settings" })
        defer { panel.close() }
        XCTAssertTrue(panel.isVisible)
        panel.orderOut(nil)
        let oldMenu = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldHelp = NSApp.helpMenu, oldServices = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindows; NSApp.helpMenu = oldHelp; NSApp.servicesMenu = oldServices }
        let delegate = AppDelegate()
        delegate.installMenu(for: workspace)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: workspace.window?.windowNumber ?? 0, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Settings" }.count, 1)
    }
}
