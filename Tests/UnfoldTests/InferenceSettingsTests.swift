import XCTest
@testable import ThoughtStream

final class InferenceSettingsTests: XCTestCase {
    func testFreshInstallHasRequestedDefaultsAndExplicitPayloads() throws {
        let name = "UnfoldSettingsTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = InferenceSettings.load(from: defaults)
        XCTAssertEqual(settings, .preferred)
        XCTAssertEqual(settings.threadParameters["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(settings.threadParameters["serviceTier"] as? String, "default")
        XCTAssertEqual((settings.threadParameters["config"] as? [String: String])?["model_reasoning_effort"], "high")
        XCTAssertEqual(settings.turnParameters as? [String: String], ["model": "gpt-6-astra", "effort": "high", "serviceTier": "default"])
    }
    func testPreviousDefaultUpgradesOnceAndLaterManualChoiceIsRemembered() throws {
        let name = "UnfoldSettingsTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let oldDefault = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "default")
        oldDefault.save(to: defaults)
        XCTAssertEqual(InferenceSettings.load(from: defaults), .preferred)
        oldDefault.save(to: defaults)
        XCTAssertEqual(InferenceSettings.load(from: defaults), oldDefault)
    }
    func testManualSelectionIsRemembered() throws {
        let name = "UnfoldSettingsTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let choice = InferenceSettings(model: "gpt-6.1-sol", effort: "medium", tier: "fast")
        choice.save(to: defaults)
        XCTAssertEqual(InferenceSettings.load(from: defaults), choice)
    }
    func testModelChangeEffortUsesOnlyAdvertisedChoicesAndLeavesUnknownModelsAlone() {
        let settings = InferenceSettings(model: "future-model", effort: "max", tier: "default")
        let supported: [[String: Any]] = [["reasoningEffort": "low"], ["reasoningEffort": "high"]]
        XCTAssertEqual(settings.resolvingEffort(in: []), settings)
        XCTAssertEqual(settings.resolvingEffort(in: [["model": settings.model]]), settings)
        XCTAssertEqual(settings.resolvingEffort(in: [["model": settings.model, "supportedReasoningEfforts": supported, "defaultReasoningEffort": "high"]]).effort, "high")
        XCTAssertEqual(settings.resolvingEffort(in: [["model": settings.model, "supportedReasoningEfforts": supported, "defaultReasoningEffort": "unadvertised"]]).effort, "low")
        let compatible = InferenceSettings(model: settings.model, effort: "high", tier: "default")
        XCTAssertEqual(compatible.resolvingEffort(in: [["model": settings.model, "supportedReasoningEfforts": supported, "defaultReasoningEffort": "low"]]), compatible)
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
