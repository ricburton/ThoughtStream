import AppKit
import XCTest
@testable import ThoughtStream

final class ServiceTierTests: XCTestCase {
    private let fastOnly: [[String: Any]] = [[
        "model": "gpt-6.1-sol", "additionalSpeedTiers": ["fast"],
        "serviceTiers": [["id": "priority", "name": "Fast"]]
    ]]

    func testUnavailableTierFallsBackWithoutChangingModelOrEffort() {
        let requested = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
        let resolved = requested.resolvingCodexTier(in: fastOnly)
        XCTAssertEqual(resolved, InferenceSettings(model: requested.model, effort: requested.effort, tier: "fast"))
        XCTAssertEqual(InferenceSettings.codexTiers(for: requested.model, in: fastOnly), ["default", "fast"])
        XCTAssertEqual(requested.tier, "ultrafast")
    }

    func testUnknownModelOrMissingCapabilitiesUsesStandard() {
        let requested = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
        for catalog: [[String: Any]] in [[], [["model": requested.model]], [["model": "other", "additionalSpeedTiers": ["ultrafast"]]]] {
            XCTAssertEqual(requested.resolvingCodexTier(in: catalog).tier, "default")
        }
    }

    func testBothCatalogFormatsSupportUltrafastAndPriorityAlias() {
        for field: [String: Any] in [
            ["additionalSpeedTiers": ["fast", "ultrafast"]],
            ["serviceTiers": [["id": "priority"], ["id": "ultrafast"]]]
        ] {
            var record = field
            record["id"] = "gpt-6.1-sol"
            XCTAssertEqual(InferenceSettings.codexTiers(for: "gpt-6.1-sol", in: [record]), ["default", "fast", "ultrafast"])
            for (requested, expected) in [("priority", "fast"), ("fast", "fast"), ("ultrafast", "ultrafast")] {
                XCTAssertEqual(InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: requested)
                    .resolvingCodexTier(in: [record]).tier, expected)
            }
        }
    }

    @MainActor
    func testSpeedPickerAlwaysOffersUltrafastAndPreservesSelection() throws {
        let defaults = UserDefaults.standard
        let keys = ["thoughtstream.provider", "unfold.inference.model", "unfold.inference.effort", "unfold.inference.tier"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        AgentProvider.codex.select()
        let requested = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
        InferenceSettings(model: requested.model, effort: requested.effort, tier: "default").save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = WorkspaceWindow(restoredSessions: [], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        defer { controller.stopAll(); controller.window?.close(); try? FileManager.default.removeItem(at: root) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(controller.window?.contentView)
        let speed = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Speed" })
        XCTAssertEqual(speed.itemTitles, ["Standard", "Fast", "Ultrafast"])
        XCTAssertEqual(controller.chosenSettings.tier, "default")
        speed.selectItem(withTitle: "Ultrafast")
        XCTAssertTrue(try XCTUnwrap(speed.selectedItem).isEnabled)
        XCTAssertTrue(speed.sendAction(speed.action, to: speed.target))
        XCTAssertEqual(InferenceSettings.load(), requested)
        controller.applyModelList(fastOnly)
        XCTAssertEqual(speed.itemTitles, ["Standard", "Fast", "Ultrafast"])
        XCTAssertEqual(controller.chosenSettings.tier, "ultrafast")
        controller.applyModelList([["model": requested.model, "additionalSpeedTiers": ["fast", "ultrafast"]]])
        XCTAssertEqual(speed.itemTitles, ["Standard", "Fast", "Ultrafast"])
        XCTAssertEqual(controller.chosenSettings, requested)
        XCTAssertEqual(InferenceSettings.load(), requested)
    }

    @MainActor
    func testNewThreadAndTurnUseFastWhenUltrafastIsUnavailable() async throws {
        try await exerciseRuntime()
    }

    @MainActor
    func testResumeDoesNotApplyUnsupportedSavedTier() async throws {
        try await exerciseRuntime(resume: true)
    }

    @MainActor
    func testResumeKeepsChatModelWhenGlobalPreferenceChanges() async throws {
        try await exerciseRuntime(resume: true, ultrafast: true, perChat: true)
    }

    @MainActor
    func testPreviouslyBlockedUltrafastMessageRetriesWithFast() async throws {
        try await exerciseRuntime(queued: true)
    }

    @MainActor
    func testAdvertisedUltrafastStillReachesThreadAndTurn() async throws {
        try await exerciseRuntime(ultrafast: true)
    }

    @MainActor
    func testTemporaryCatalogFailureRecoversBeforeSending() async throws {
        try await exerciseRuntime(recover: true)
    }

    @MainActor
    func testCatalogIsRecheckedAfterSuccessfulConnection() async throws {
        try await exerciseRuntime(disappear: true)
    }

    @MainActor
    func testLateRuntimeWarningPreventsFirstTurn() async throws {
        try await exerciseRuntime(ultrafast: true, warn: true)
    }

    @MainActor
    func testResumeRetriesTemporaryMissingTier() async throws {
        try await exerciseRuntime(resume: true, recover: true)
    }

    @MainActor
    func testSteeringExistingTurnDoesNotRequireNewTierAvailability() async throws {
        try await exerciseRuntime(steer: true)
    }

    @MainActor
    private func exerciseRuntime(resume: Bool = false, queued: Bool = false, ultrafast: Bool = false, perChat: Bool = false, recover: Bool = false, disappear: Bool = false, warn: Bool = false, steer: Bool = false) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Python fixture unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("runtime")
        try Self.runtime.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for (enabled, name) in [(ultrafast, "ultrafast"), (recover, "recover"), (disappear, "disappear"), (warn, "warn")] {
            if enabled { try Data().write(to: root.appendingPathComponent(name)) }
        }
        let shouldSend = !warn || steer
        let expectedTier = (ultrafast || recover) && !disappear ? "ultrafast" : "fast"


        // Exercise existing saved preferences, including resumes which have no
        // per-call settings override. Restore only these keys after the fixture.
        let defaults = UserDefaults.standard
        let keys = ["unfold.inference.model", "unfold.inference.effort", "unfold.inference.tier"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        let requested = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "ultrafast")
        requested.save()

        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { true })
        let session = Session(project: root, thread: resume ? "existing" : nil, storageRoot: root)
        defer { session.stop(); monitor.stop() }
        if perChat {
            session.setInferenceSettings(requested)
            InferenceSettings(model: "gpt-6-astra", effort: "low", tier: "default").save()
        }
        if queued {
            // Save with yesterday's unavailable tier, then replay through the
            // actual queue worker after its local runtime connects.
            try session.enqueueChat("Queued message", attachments: [], settings: requested)
            let pending = try XCTUnwrap(session.outbox.pending)
            try session.outbox.update(pending.id, state: .blocked,
                detail: "Ultrafast availability could not be confirmed for GPT-6.1 Sol. Your speed choice was kept.")
            session.configureMessageQueue(connectivity: monitor) {
                try await session.connect(script, persistentRuntime: false)
            }
            let deadline = Date().addingTimeInterval(12)
            while let pending = session.outbox.pending, pending.state != .blocked, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if shouldSend { XCTAssertNil(session.outbox.pending) }
            else {
                XCTAssertEqual(session.outbox.pending?.state, .blocked)
                XCTAssertEqual(session.outbox.pending?.tier, "ultrafast")
            }
        } else {
            do {
                try await session.connect(script, persistentRuntime: false)
                if steer { session.thread = "existing"; session.turn = "active" }
                if perChat { try await session.send("Test message") }
                else { try await session.send("Test message", model: requested.model, effort: requested.effort, tier: requested.tier) }
                XCTAssertTrue(shouldSend, "A supported fallback should allow sending")
            } catch {
                XCTAssertFalse(shouldSend, "Unexpected error: \(error)")
                XCTAssertTrue(error.localizedDescription.contains(warn ? "could not apply" : "availability could not be confirmed"))
            }
        }
        let calls = try String(contentsOf: root.appendingPathComponent("requests.jsonl"))
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let methods = calls.compactMap { $0["method"] as? String }
        if steer {
            XCTAssertTrue(methods.contains("turn/steer"))
            XCTAssertFalse(methods.contains("turn/start"))
            XCTAssertEqual(methods.filter { $0 == "model/list" }.count, 1)
            return
        }
        if !shouldSend {
            XCTAssertFalse(methods.contains("turn/start"))
            if !warn { XCTAssertFalse(methods.contains("thread/start")) }
            XCTAssertEqual(session.inferenceSettings.tier, "ultrafast")
            return
        }
        if recover { XCTAssertGreaterThanOrEqual(methods.filter { $0 == "model/list" }.count, 3) }
        if resume {
            let index = try XCTUnwrap(methods.firstIndex(of: "thread/resume"))
            let params = try XCTUnwrap(calls[index]["params"] as? [String: Any])
            XCTAssertNil(params["model"], "Reconnection must preserve the existing thread model")
            XCTAssertNil(params["serviceTier"], "Reconnection must not depend on speed availability")
        }
        let settingsMethods = resume ? ["turn/start"] : ["thread/start", "turn/start"]
        for method in settingsMethods {
            let index = try XCTUnwrap(methods.firstIndex(of: method))
            XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "model/list")), index)
            let params = try XCTUnwrap(calls[index]["params"] as? [String: Any])
            XCTAssertEqual(params["model"] as? String, requested.model)
            XCTAssertEqual(params["serviceTier"] as? String, expectedTier)
        }
    }

    private static let runtime = #"""
#!/usr/bin/python3
import json, os, sys
root = os.path.dirname(__file__)
catalog_calls = 0
for line in sys.stdin:
    request = json.loads(line)
    with open(os.path.join(root, 'requests.jsonl'), 'a') as log:
        log.write(json.dumps(request) + '\n')
    if 'id' not in request:
        continue
    method = request['method']
    result = {}
    if method == 'model/list':
        catalog_calls += 1
        enabled = os.path.exists(os.path.join(root, 'ultrafast')) or (os.path.exists(os.path.join(root, 'recover')) and catalog_calls >= 3) or (os.path.exists(os.path.join(root, 'disappear')) and catalog_calls == 1)
        tiers = ['fast', 'ultrafast'] if enabled else ['fast']
        result = {'data': [{'model': 'gpt-6.1-sol', 'additionalSpeedTiers': tiers}]}
    elif method == 'project/list':
        result = {'data': [{'id': 'project', 'name': 'Project', 'roots': [{'path': root}]}]}
    elif method in ('thread/start', 'thread/resume', 'thread/read'):
        result = {'thread': {'id': 'existing', 'historyMode': 'legacy', 'turns': []}}
        if method == 'thread/start' and os.path.exists(os.path.join(root, 'warn')):
            print(json.dumps({'method': 'warning', 'params': {'threadId': 'existing', 'message': 'Configured service tier `ultrafast` is not advertised as supported for model `gpt-6.1-sol` and will be omitted from requests.'}}), flush=True)
    elif method == 'turn/start':
        result = {'turn': {'id': 'turn'}}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
"""#
}
