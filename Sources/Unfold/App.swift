import AppKit

@main
struct ThoughtStreamMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var workspace: WorkspaceWindow?
    private var appUpdater: AppUpdateController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Chats have their own tab bar; system window tabs would duplicate it
        // and add "Merge All Windows" style items to the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        let workspace = WorkspaceWindow()
        self.workspace = workspace
        appUpdater = AppUpdateController { [weak self] in self?.workspace?.hasActiveWork ?? false }
        installMenu(for: workspace)
        workspace.showWindow(nil)
        ConnectivityMonitor.shared.start()
        if !CommandLine.arguments.contains("--background") { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        ConnectivityMonitor.shared.stop()
        workspace?.stopAll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func chooseInterfaceStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = InterfaceStyle(rawValue: raw) else { return }
        InterfaceStyle.current = style
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseInterfaceStyle(_:)) {
            item.state = (item.representedObject as? String) == InterfaceStyle.current.rawValue ? .on : .off
        }
        return true
    }

    func installMenu(for workspace: WorkspaceWindow) {
        let root = NSMenu()
        let appItem = NSMenuItem(); root.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About ThoughtStream", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdateController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = appUpdater
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(WorkspaceWindow.showSettings(_:)), keyEquivalent: ",")
        settings.target = workspace
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApplication.shared.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ThoughtStream", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit ThoughtStream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        typealias Entry = (title: String, action: Selector?, key: String, modifiers: NSEvent.ModifierFlags)
        func entry(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> Entry { (title, action, key, modifiers) }
        let separator: Entry = ("", nil, "", [])
        /// Workspace commands target the workspace; nil-target items use the responder chain.
        @discardableResult
        func group(_ name: String, _ entries: [Entry], target: AnyObject? = nil) -> NSMenu {
            let parent = NSMenuItem(); root.addItem(parent); let menu = NSMenu(title: name); parent.submenu = menu
            for entry in entries {
                guard let action = entry.action else { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: entry.key)
                item.keyEquivalentModifierMask = entry.modifiers; item.target = target; menu.addItem(item)
            }
            return menu
        }
        /// A second shortcut for an existing command, e.g. ⌘T for New Chat.
        func alias(_ menu: NSMenu, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            guard let original = menu.items.first(where: { $0.action == action }) else { return }
            let item = NSMenuItem(title: original.title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = original.target
            item.identifier = NSUserInterfaceItemIdentifier("shortcutAlias")
            item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true
            menu.insertItem(item, at: menu.index(of: original) + 1)
        }

        let file = group("File", [
            entry("New Chat", #selector(WorkspaceWindow.newChat(_:)), "n"),
            entry("Open Project…", #selector(WorkspaceWindow.openProject(_:)), "o"),
            separator,
            entry("Close Tab", #selector(WorkspaceWindow.closeTab(_:)), "w"),
            entry("Reopen Closed Tab", #selector(WorkspaceWindow.reopenClosedTab(_:)), "t", [.command, .shift]),
            separator,
            entry("Fork Session", #selector(WorkspaceWindow.forkSession(_:))),
            entry("Export Protocol…", #selector(WorkspaceWindow.exportLog(_:)), "e", [.command, .shift])
        ], target: workspace)
        alias(file, #selector(WorkspaceWindow.newChat(_:)), "t")

        let edit = group("Edit", [
            entry("Undo", Selector(("undo:")), "z"), entry("Redo", Selector(("redo:")), "z", [.command, .shift]),
            separator,
            entry("Cut", #selector(NSText.cut(_:)), "x"), entry("Copy", #selector(NSText.copy(_:)), "c"),
            entry("Paste", #selector(NSText.paste(_:)), "v"),
            entry("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            entry("Delete", #selector(NSText.delete(_:))),
            entry("Select All", #selector(NSText.selectAll(_:)), "a"),
            separator
        ])
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find"); findItem.submenu = findMenu
        for (title, action, key) in [("Find…", #selector(WorkspaceWindow.find(_:)), "f"), ("Find Next", #selector(WorkspaceWindow.findNext(_:)), "g")] {
            findMenu.addItem(withTitle: title, action: action, keyEquivalent: key).target = workspace
        }

        let view = group("View", [
            entry("Previous Chat or Pane", #selector(WorkspaceWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
            entry("Next Chat or Pane", #selector(WorkspaceWindow.selectNextTab(_:)), "]", [.command, .shift]),
            separator,
            entry("Split", #selector(WorkspaceWindow.splitStream(_:)), "p"),
            entry("Stack", #selector(WorkspaceWindow.stackStream(_:)), "\\", [.command, .shift]),
            entry("Focus Previous Pane", #selector(WorkspaceWindow.focusPreviousPane(_:)), "[", [.command, .option]),
            entry("Focus Next Pane", #selector(WorkspaceWindow.focusNextPane(_:)), "]", [.command, .option]),
            entry("Close Pane", #selector(WorkspaceWindow.closeFocusedPane(_:))),
            entry("Single Pane", #selector(WorkspaceWindow.singlePane(_:))),
            separator,
            entry("Actual Size", #selector(WorkspaceWindow.resetText(_:)), "0"),
            entry("Larger Text", #selector(WorkspaceWindow.increaseText(_:)), "+"),
            entry("Smaller Text", #selector(WorkspaceWindow.decreaseText(_:)), "-"),
            separator,
            entry("Sample Feed", #selector(WorkspaceWindow.showSample(_:)))
        ], target: workspace)
        // Keep pane-only commands together so Tabs Only can remove that section.
        if let splitIndex = view.items.firstIndex(where: { $0.action == #selector(WorkspaceWindow.splitStream(_:)) }), splitIndex > 0 {
            view.items[splitIndex - 1].identifier = NSUserInterfaceItemIdentifier("paneCommandsSeparator")
        }
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Layout")
        layoutItem.submenu = layoutMenu
        for mode in WorkspaceLayoutMode.allCases {
            let item = layoutMenu.addItem(withTitle: mode.title, action: #selector(WorkspaceWindow.chooseWorkspaceLayout(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue; item.target = workspace
        }
        view.insertItem(layoutItem, at: 0)
        view.insertItem(.separator(), at: 1)
        // AppKit matches the shifted character on layouts where ⇧[ / ⇧] emit braces.
        alias(view, #selector(WorkspaceWindow.selectPreviousTab(_:)), "{", [.command, .shift])
        alias(view, #selector(WorkspaceWindow.selectNextTab(_:)), "}", [.command, .shift])
        alias(view, #selector(WorkspaceWindow.splitStream(_:)), "\\")
        // ⌘+ needs Shift on most layouts; ⌘= is the conventional unshifted key.
        alias(view, #selector(WorkspaceWindow.increaseText(_:)), "=")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let session = group("Session", [
            entry("Send or Steer", #selector(WorkspaceWindow.send(_:))),
            entry("Interrupt", #selector(WorkspaceWindow.interrupt(_:)), ".")
        ], target: workspace)
        alias(session, #selector(WorkspaceWindow.interrupt(_:)), "\u{1b}")

        // Whole-window looks, beside Window and Help.
        let styleItem = NSMenuItem(); root.addItem(styleItem)
        let styleMenu = NSMenu(title: "Style"); styleItem.submenu = styleMenu
        for style in InterfaceStyle.allCases {
            let item = styleMenu.addItem(withTitle: style.title, action: #selector(chooseInterfaceStyle(_:)), keyEquivalent: style.keyEquivalent)
            item.keyEquivalentModifierMask = [.command, .control]
            item.representedObject = style.rawValue; item.target = self
        }

        let window = group("Window", [
            entry("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            entry("Zoom", #selector(NSWindow.performZoom(_:))),
            separator,
            entry("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        ])
        NSApplication.shared.windowsMenu = window
        // An empty Help menu still provides the system's menu search field.
        NSApplication.shared.helpMenu = group("Help", [])
        NSApplication.shared.mainMenu = root
        workspace.refreshLayoutMenu()
    }
}
