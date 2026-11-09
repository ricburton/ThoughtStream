import AppKit
import XCTest
@testable import ThoughtStream

@MainActor
final class ModelCatalogTests: XCTestCase {
    func testDiscoveryAndCustomModelsSurviveRelaunchAndStayProviderScoped() throws {
        let suite = "ModelCatalogTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults)
        XCTAssertTrue(catalog.models(for: .claude).contains { $0["model"] as? String == "claude-fable-5-2" })
        try catalog.add(id: " claude-future-9[1m] ", name: "Future Claude", for: .claude)
        try catalog.add(id: "custom-codex", name: "Custom Codex", for: .codex)
        catalog.update([["model": "claude-discovered-10", "displayName": "Discovered Claude", "supportedReasoningEfforts": [["reasoningEffort": "max"]]]], for: .claude)
        // A failed/empty refresh must not erase an earlier successful discovery.
        catalog.update([], for: .claude)
        let restored = ModelCatalog(defaults: defaults)
        let claude = restored.models(for: .claude)
        XCTAssertTrue(claude.contains { $0["model"] as? String == "claude-future-9[1m]" && $0["displayName"] as? String == "Future Claude" })
        XCTAssertTrue(claude.contains { $0["model"] as? String == "claude-discovered-10" })
        XCTAssertFalse(claude.contains { $0["model"] as? String == "custom-codex" })
        XCTAssertTrue(restored.models(for: .codex).contains { $0["model"] as? String == "custom-codex" })
        XCTAssertFalse(restored.needsRefresh(for: .claude))
        XCTAssertTrue(restored.needsRefresh(for: .claude, now: Date().addingTimeInterval(7 * 60 * 60)))
        XCTAssertTrue(restored.needsRefresh(for: .codex))
    }

    func testDiscoveryDeduplicatesWithoutLosingCapabilitiesOrCustomNames() throws {
        let catalog = ModelCatalog(defaults: nil)
        XCTAssertThrowsError(try catalog.add(id: " \n", name: "Empty", for: .claude))
        XCTAssertThrowsError(try catalog.add(id: "not a model", name: "Invalid", for: .claude))
        try catalog.add(id: "claude-fable-5-2", name: "My Fable", for: .claude)
        catalog.update([
            ["model": "claude-fable-5-2", "displayName": "Fable 5.2", "supportedReasoningEfforts": [["reasoningEffort": "xhigh"]]],
            ["model": "claude-fable-5-2"], ["model": ""], ["id": "next-release", "displayName": "Next release"]
        ], for: .claude)
        let entries = catalog.models(for: .claude)
        let fable = entries.filter { $0["model"] as? String == "claude-fable-5-2" }
        XCTAssertEqual(fable.count, 1)
        XCTAssertEqual(fable.first?["displayName"] as? String, "My Fable")
        XCTAssertEqual((fable.first?["supportedReasoningEfforts"] as? [[String: String]])?.first?["reasoningEffort"], "xhigh")
        XCTAssertTrue(entries.contains { $0["model"] as? String == "next-release" })
    }

    func testPickerAddsAndKeepsCustomModelAcrossCatalogUpdatesAndReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .claude)
        session.setInferenceSettings(InferenceSettings(model: "claude-fable-5-1[1m]", effort: "high", tier: "default"))
        let original = InferenceSettings.load(provider: .claude)
        defer { original.save(provider: .claude) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: store, modelCatalog: ModelCatalog(defaults: nil))
        defer { workspace.stopAll(); workspace.window?.close() }
        XCTAssertEqual(workspace.chosenSettings.model, "claude-fable-5-1[1m]", "Adding Fable 5.2 must preserve a conversation's existing choice")
        try workspace.addCustomModel(id: "claude-new-release", name: "New Claude")
        XCTAssertEqual(session.inferenceSettings.model, "claude-new-release")
        session.onModels?([["model": "claude-fable-5-2", "displayName": "Fable 5.2"]])
        XCTAssertEqual(workspace.chosenSettings.model, "claude-new-release")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let picker = try XCTUnwrap(descendants(try XCTUnwrap(workspace.window?.contentView)).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Model" })
        XCTAssertNotNil(picker.item(withTitle: "Add Model…"))
        XCTAssertNotNil(picker.item(withTitle: "Refresh Models"))
        XCTAssertEqual(picker.selectedItem?.title, "New Claude")
        let add = try XCTUnwrap(picker.item(withTitle: "Add Model…"))
        picker.select(add)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(add.action), to: add.target, from: add))
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, "claude-new-release", "A menu action must not become the selected model")
        let sheet = try XCTUnwrap(workspace.window?.attachedSheet)
        let inputs = descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let id = try XCTUnwrap(inputs.first { $0.accessibilityLabel() == "Model ID" })
        let name = try XCTUnwrap(inputs.first { $0.accessibilityLabel() == "Display name (optional)" })
        id.stringValue = "claude-from-sheet"; name.stringValue = "From sheet"
        workspace.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(workspace.chosenSettings.model, "claude-from-sheet")
        let restored = Session(project: root, id: session.id, storageRoot: root, provider: .claude)
        XCTAssertEqual(restored.inferenceSettings.model, "claude-from-sheet")
    }

    func testClaudeDiscoveryPreservesUnknownModelsAndEffortsWithoutEnablingTools() {
        let records = ClaudeConnection.modelRecords([
            ["value": "claude-unreleased-12", "displayName": "Future Model", "supportedEffortLevels": ["low", "max"], "supportsFastMode": true],
            ["value": ""], ["id": "custom-endpoint-model"]
        ])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["model"] as? String, "claude-unreleased-12")
        XCTAssertEqual(records[0]["supportsFastMode"] as? Bool, true)
        XCTAssertEqual((records[0]["supportedReasoningEfforts"] as? [[String: String]])?.map { $0["reasoningEffort"]! }, ["low", "max"])
        let arguments = ClaudeConnection.discoveryArguments
        XCTAssertFalse(arguments.contains("--resume"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(arguments.contains("{\"disableAllHooks\":true}"))
    }

    func testCustomCodexModelUsesStandardAndDuplicateDisplayNamesRemainSelectable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .codex)
        session.setInferenceSettings(InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast"))
        let original = InferenceSettings.load(provider: .codex)
        defer { original.save(provider: .codex) }
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")), modelCatalog: ModelCatalog(defaults: nil))
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.applyModelList([["model": "first", "displayName": "Shared name"], ["model": "second", "displayName": "Shared name"]])
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let picker = try XCTUnwrap(descendants(try XCTUnwrap(workspace.window?.contentView)).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Model" })
        XCTAssertEqual(picker.itemArray.filter { $0.title == "Shared name" }.compactMap { $0.representedObject as? String }, ["first", "second"])
        try workspace.addCustomModel(id: "custom-endpoint-model", name: "My model")
        XCTAssertEqual(workspace.chosenSettings.model, "custom-endpoint-model")
        XCTAssertEqual(workspace.chosenSettings.tier, "default", "Unknown models must not inherit an unadvertised speed tier")
        XCTAssertEqual(session.inferenceSettings.tier, "default")
    }

    func testLiveClaudeCatalogWithoutSendingPromptWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THOUGHTSTREAM_MODEL_DISCOVERY_TEST"] == "1" else { throw XCTSkip("Opt-in catalog-only discovery") }
        let records = try await ProviderModelDiscovery.models(for: .claude, executable: ClaudeConnection.executable())
        XCTAssertTrue(records.contains { $0["model"] as? String == "claude-fable-5-2" && $0["displayName"] as? String == "Fable 5.2" })
    }

    func testCodexDiscoveryPaginatesWithoutStartingAConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("catalog.py"), log = root.appendingPathComponent("requests.jsonl")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            with open(\(String(reflecting: log.path)), 'a') as output:
                output.write(json.dumps(request) + '\\n')
            if 'id' not in request:
                continue
            result = {}
            if request.get('method') == 'model/list':
                if request.get('params', {}).get('cursor') == 'second':
                    result = {'data': [{'model': 'future-model', 'displayName': 'Future model'}]}
                else:
                    result = {'data': [{'model': 'first-model'}], 'nextCursor': 'second'}
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let records = try await ProviderModelDiscovery.models(for: .codex, executable: executable)
        XCTAssertEqual(records.compactMap { $0["model"] as? String }, ["first-model", "future-model"])
        let methods = try String(contentsOf: log).split(separator: "\n").compactMap { line -> String? in
            let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return event?["method"] as? String
        }
        XCTAssertEqual(methods, ["initialize", "initialized", "model/list", "model/list"])
    }
}
