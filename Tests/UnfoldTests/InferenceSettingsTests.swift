import XCTest
@testable import ThoughtStream

final class InferenceSettingsTests: XCTestCase {
    func testFreshInstallHasRequestedDefaultsAndExplicitPayloads() throws {
        let name = "UnfoldSettingsTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = InferenceSettings.load(from: defaults)
        XCTAssertEqual(settings, .preferred)
        XCTAssertEqual(settings.threadParameters["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(settings.threadParameters["serviceTier"] as? String, "default")
        XCTAssertEqual((settings.threadParameters["config"] as? [String: String])?["model_reasoning_effort"], "high")
        XCTAssertEqual(settings.turnParameters as? [String: String], ["model": "gpt-6.1-sol", "effort": "high", "serviceTier": "default"])
    }
    func testManualSelectionIsRemembered() throws {
        let name = "UnfoldSettingsTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let choice = InferenceSettings(model: "gpt-6.1-sol", effort: "medium", tier: "fast")
        choice.save(to: defaults)
        XCTAssertEqual(InferenceSettings.load(from: defaults), choice)
    }
    @MainActor
    func testModelListRefreshPreservesSelectedDefaults() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json"))
        let controller = WorkspaceWindow(restoredSessions: [], stateStore: store)
        defer { controller.stopAll(); controller.window?.close(); try? FileManager.default.removeItem(at: directory) }
        let initial = controller.chosenSettings
        controller.applyModelList([
            ["model": "another-model", "displayName": "Another model"],
            ["model": initial.model, "displayName": initial.displayName, "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": initial.effort]]]
        ])
        XCTAssertEqual(controller.chosenSettings, initial)
    }

}
