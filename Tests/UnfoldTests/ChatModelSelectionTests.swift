import AppKit
import XCTest
@testable import ThoughtStream

final class ChatModelSelectionTests: XCTestCase {
    private let astra = InferenceSettings(model: "gpt-6-astra", effort: "medium", tier: "default")
    private let sol = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "default")

    @MainActor
    func testTabPaneAndCatalogChangesFollowTheSelectedChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Session(project: root, storageRoot: root)
        let second = Session(project: root, storageRoot: root)
        first.setInferenceSettings(astra)
        second.setInferenceSettings(sol)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(primary: first.id, secondary: second.id,
                primaryTabs: [first.id, second.id], secondaryTabs: [first.id, second.id])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [first, second], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        let panes = columns(try XCTUnwrap(workspace.window?.contentViewController))
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(workspace.chosenSettings, astra)
        panes[1].onFocus?()
        XCTAssertEqual(workspace.chosenSettings, sol)
        panes[0].onFocus?()
        XCTAssertEqual(workspace.chosenSettings, astra)
        panes[0].onSelectChat?(1)
        XCTAssertEqual(workspace.chosenSettings, sol)
        panes[0].onSelectChat?(0)
        XCTAssertEqual(workspace.chosenSettings, astra)

        // A late model-list response from another chat must preserve this chat.
        second.onModels?([["model": sol.model, "displayName": "Sol"]])
        XCTAssertEqual(workspace.chosenSettings, astra, "Unavailable models stay explicitly selected")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let picker = try XCTUnwrap(descendants(try XCTUnwrap(workspace.window?.contentView))
            .compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Model" })
        let defaults = InferenceSettings.load()
        defer { defaults.save() }
        picker.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        XCTAssertEqual(first.inferenceSettings.model, sol.model)
        panes[0].onSelectChat?(1)
        panes[0].onSelectChat?(0)
        XCTAssertEqual(workspace.chosenSettings.model, sol.model)
        XCTAssertEqual(second.inferenceSettings, sol)
        let restored = Session(project: root, id: first.id, storageRoot: root)
        XCTAssertEqual(restored.inferenceSettings, first.inferenceSettings)
    }

    @MainActor
    func testProviderFocusAndEmptyPaneUseTheirOwnDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = Session(project: root, storageRoot: root)
        codex.setInferenceSettings(astra)
        let claude = Session(project: root, storageRoot: root, provider: .claude)
        let opus = InferenceSettings(model: "opus", effort: "high", tier: "fast")
        claude.setInferenceSettings(opus)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [root.path:
            ProjectViewState(primary: codex.id, secondary: claude.id,
                primaryTabs: [codex.id], secondaryTabs: [claude.id])]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [codex, claude], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        func columns(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(columns)
        }
        let panes = columns(try XCTUnwrap(workspace.window?.contentViewController))
        panes[1].onFocus?()
        XCTAssertEqual(workspace.chosenSettings, opus)
        panes[0].onFocus?()
        XCTAssertEqual(workspace.chosenSettings, astra)
        panes[1].display(nil)
        panes[1].onFocus?()
        XCTAssertNil(panes[1].session)
        XCTAssertEqual(workspace.chosenSettings.model, InferenceSettings.load(provider: AgentProvider.selected).model)
    }

    @MainActor
    func testLegacyModelRecoverySkipsResumeAndSurvivesReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID(), folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events: [[String: Any]] = [
            ["_direction": "outgoing", "method": "thread/start", "params": sol.threadParameters],
            ["_direction": "outgoing", "method": "turn/start", "params": astra.turnParameters],
            ["method": "item/agentMessage/delta", "params": ["delta": String(repeating: "x", count: 140_000)]],
            ["_direction": "outgoing", "method": "thread/resume", "params": sol.threadParameters]
        ]
        var log = Data()
        for event in events { log.append(try JSONSerialization.data(withJSONObject: event)); log.append(10) }
        log.append(Data("{\"model\":\"torn".utf8))
        try log.write(to: folder.appendingPathComponent("protocol.jsonl"))
        let session = Session(project: root, id: id, storageRoot: root)
        XCTAssertEqual(session.inferenceSettings, astra)
        // Once saved, metadata takes precedence over the old protocol.
        session.setInferenceSettings(sol)
        let restored = Session(project: root, id: id, storageRoot: root)
        XCTAssertEqual(restored.inferenceSettings, sol)
    }

    func testLegacyClaudeModelRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let event: [String: Any] = ["_provider": "claude", "payload": ["type": "system", "subtype": "init", "model": "claude-opus-4-8"]]
        try JSONSerialization.data(withJSONObject: event).write(to: url)
        XCTAssertEqual(SessionInferenceHistory.latest(in: url, provider: .claude)?.model, "claude-opus-4-8")
        XCTAssertNil(SessionInferenceHistory.latest(in: url, provider: .codex))
    }
}
