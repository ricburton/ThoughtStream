import AppKit
import XCTest
@testable import ThoughtStream

@MainActor
final class GeminiTests: XCTestCase {
    func testCatalogAndSelectionStayScopedAndSurviveReopening() throws {
        let suite = "GeminiTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults)
        let expected = ["gemini-4-carbon", "gemini-4-neon", "gemini-4-hydrogen", "gemini-4-argon", "gemini-3.8-flash"]
        XCTAssertEqual(catalog.models(for: .gemini).compactMap(ModelCatalog.identifier), expected)
        try catalog.add(id: "gemini-future", name: "Future Gemini", for: .gemini)
        catalog.update([["model": "gemini-4-neon"]], for: .gemini)
        let restored = ModelCatalog(defaults: defaults)
        XCTAssertEqual(Set(restored.models(for: .gemini).compactMap(ModelCatalog.identifier)), Set(expected + ["gemini-future"]))
        XCTAssertFalse(restored.models(for: .codex).contains { ModelCatalog.identifier($0)?.hasPrefix("gemini") == true })
        let selected = InferenceSettings(model: "gemini-4-neon", effort: "default", tier: "default")
        selected.save(to: defaults, provider: .gemini)
        XCTAssertEqual(InferenceSettings.load(from: defaults, provider: .gemini), selected)
        XCTAssertEqual(InferenceSettings.load(from: defaults).model, InferenceSettings.preferred.model)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(project: root, storageRoot: root, provider: .gemini)
        session.setInferenceSettings(selected)
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")), modelCatalog: restored)
        defer { workspace.stopAll(); workspace.window?.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(workspace.window?.contentView)).compactMap { $0 as? NSPopUpButton }
        let picker = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "Model" })
        XCTAssertNotNil(controls.first { $0.accessibilityLabel() == "Agent provider" }?.item(withTitle: "Gemini"))
        XCTAssertEqual(controls.first { $0.accessibilityLabel() == "Reasoning effort" }?.isHidden, true)
        XCTAssertEqual(controls.first { $0.accessibilityLabel() == "Speed" }?.isHidden, true)
        XCTAssertNotNil(picker.item(withTitle: "Gemini 4 Carbon"))
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, "gemini-4-neon")
        let original = InferenceSettings.load(provider: .gemini)
        defer { original.save(provider: .gemini) }
        picker.select(try XCTUnwrap(picker.item(withTitle: "Gemini 4 Argon")))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        XCTAssertEqual(session.inferenceSettings.model, "gemini-4-argon")
        XCTAssertEqual(Session(project: root, id: session.id, storageRoot: root, provider: .gemini).inferenceSettings.model, "gemini-4-argon")
    }

    func testStreamingToolsImagesAndModelChangeResumeExactSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(root, behavior: "success")
        let session = Session(project: root, storageRoot: root, provider: .gemini)
        defer { session.stop() }
        try await session.connect(executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path), "Connect/discovery must not submit a prompt")
        let image = root.appendingPathComponent("a quoted \" image.png")
        try Data([1, 2, 3]).write(to: image)
        try await session.send("Describe the image", attachments: [ChatAttachment(id: UUID(), name: "Image", path: image.path)], model: "gemini-4-carbon")
        XCTAssertNotNil(session.turn)
        try await waitForCompletion(session)
        XCTAssertEqual(session.thread, "fixture-session")
        XCTAssertTrue(session.history.contains { $0.text == "Hello 🌍" && $0.isFinalResponse == true })
        XCTAssertTrue(session.history.contains { $0.kind == StreamKind.tool.rawValue && $0.text.contains("read_file") })
        try await session.send("Follow-up", model: "gemini-4-neon")
        try await waitForCompletion(session)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let first = try XCTUnwrap(calls[0]["arguments"] as? [String])
        let second = try XCTUnwrap(calls[1]["arguments"] as? [String])
        XCTAssertFalse(first.contains("--resume"))
        XCTAssertEqual(second[try XCTUnwrap(second.firstIndex(of: "--resume")) + 1], "fixture-session")
        XCTAssertEqual(second[try XCTUnwrap(second.firstIndex(of: "--model")) + 1], "gemini-4-neon")
        XCTAssertTrue(calls[0]["imageExists"] as? Bool == true)
        XCTAssertEqual(session.history.filter { $0.text == "Hello 🌍" }.count, 2, "Deltas must be reconciled exactly once")
        session.stop()
        let restored = Session(project: root, id: session.id, thread: session.thread, storageRoot: root, provider: .gemini)
        defer { restored.stop() }
        try await restored.connect(executable)
        try await restored.send("After reopening")
        try await waitForCompletion(restored)
        XCTAssertEqual(restored.inferenceSettings.model, "gemini-4-neon")
    }

    func testFailureAndInterruptionCompleteWithoutAutomaticResend() async throws {
        for behavior in ["error", "missing-result", "interrupt"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = Session(project: root, storageRoot: root, provider: .gemini)
            defer { session.stop() }
            try await session.connect(fixture(root, behavior: behavior))
            try await session.send("Test")
            if behavior == "interrupt" { try await session.interrupt() }
            try await waitForCompletion(session)
            let completed = session.protocolSnapshot().filter { $0["method"] as? String == "turn/completed" }
            XCTAssertEqual(completed.count, 1)
            let params = try XCTUnwrap(completed.first?["params"] as? [String: Any])
            let turn = try XCTUnwrap(params["turn"] as? [String: Any])
            XCTAssertEqual(turn["status"] as? String, behavior == "interrupt" ? "interrupted" : "failed")
            session.resendCandidate = try session.outbox.enqueue(text: "Do not duplicate", attachments: [], settings: session.inferenceSettings)
            XCTAssertNil(session.retryDroppedTurn(status: "failed", error: "connection reset"))
        }
    }

    func testQueuedMessagesWaitForCompletionAndResumeWithoutSteering() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fixture(root, behavior: "success")
        let session = Session(project: root, storageRoot: root, provider: .gemini)
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { true })
        defer { session.stop(); monitor.stop() }
        session.configureMessageQueue(connectivity: monitor) { try await session.connect(executable) }
        try session.enqueueChat("First", attachments: [], settings: session.inferenceSettings)
        for _ in 0..<250 {
            if session.turn != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(session.turn)
        let settings = InferenceSettings(model: "gemini-4-neon", effort: "default", tier: "default")
        try session.enqueueChat("Second", attachments: [], settings: settings)
        for _ in 0..<500 {
            if session.outbox.pending == nil && session.turn == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(session.outbox.pending)
        XCTAssertNil(session.turn)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(calls.compactMap { $0["prompt"] as? String }, ["First", "Second"])
        XCTAssertEqual(session.history.filter { $0.kind == StreamKind.user.rawValue }.map(\.text), ["First", "Second"])
        XCTAssertEqual((calls.last?["arguments"] as? [String])?.suffix(2), ["--resume", "fixture-session"])
    }

    func testPermissionModeIsExplicitAndNoUnsupportedInferenceFlags() {
        let restricted = GeminiConnection.arguments(model: "gemini-4-neon", mode: .workspace, resume: nil)
        XCTAssertEqual(restricted[restricted.firstIndex(of: "--approval-mode")! + 1], "default")
        XCTAssertFalse(restricted.contains("yolo"))
        XCTAssertFalse(restricted.contains("--effort"))
        let full = GeminiConnection.arguments(model: "gemini-4-carbon", mode: .fullAccess, resume: "exact-id")
        XCTAssertTrue(full.contains("yolo"))
        XCTAssertEqual(full.suffix(2), ["--resume", "exact-id"])
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func waitForCompletion(_ session: Session) async throws {
        for _ in 0..<250 {
            if session.turn == nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Gemini fixture did not complete")
    }
    private func fixture(_ root: URL, behavior: String) throws -> URL {
        let url = root.appendingPathComponent("gemini.py")
        let script = """
        #!/usr/bin/python3
        import json, os, re, sys, time
        prompt = sys.stdin.read()
        images = re.findall(r'@"([^"\\n]+)"', prompt)
        with open('calls.jsonl', 'a') as log:
            log.write(json.dumps({'arguments': sys.argv[1:], 'prompt': prompt, 'imageExists': bool(images) and os.path.isfile(images[0])}) + '\\n')
        def emit(value):
            print(json.dumps(value, ensure_ascii=False), flush=True)
        emit({'type': 'init', 'session_id': 'fixture-session', 'model': sys.argv[sys.argv.index('--model') + 1]})
        behavior = '\(behavior)'
        if behavior == 'interrupt':
            time.sleep(30)
        elif behavior == 'error':
            emit({'type': 'error', 'severity': 'error', 'message': 'Model is unavailable for this account'})
            sys.exit(1)
        elif behavior == 'missing-result':
            sys.exit(0)
        else:
            emit({'type': 'tool_use', 'tool_id': 'tool-1', 'tool_name': 'read_file', 'parameters': {'path': 'README.md'}})
            emit({'type': 'tool_result', 'tool_id': 'tool-1', 'status': 'success', 'output': 'Fixture'})
            emit({'type': 'message', 'role': 'assistant', 'content': 'Hello ', 'delta': True})
            data = (json.dumps({'type': 'message', 'role': 'assistant', 'content': '🌍', 'delta': True}, ensure_ascii=False) + '\\n').encode()
            split = data.index('🌍'.encode()) + 1
            sys.stdout.buffer.write(data[:split]); sys.stdout.buffer.flush()
            time.sleep(0.03)
            sys.stdout.buffer.write(data[split:]); sys.stdout.buffer.flush()
            sys.stdout.write(json.dumps({'type': 'result', 'status': 'success'})); sys.stdout.flush()
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
