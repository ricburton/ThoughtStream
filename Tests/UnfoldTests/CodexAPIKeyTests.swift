import Foundation
import XCTest
@testable import ThoughtStream

final class CodexAPIKeyTests: XCTestCase {
    private func withRuntime(_ test: @MainActor (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys, time
        root = pathlib.Path(__file__).parent
        ephemeral = sys.argv[1:] == ["-c", 'cli_auth_credentials_store="ephemeral"', "app-server"]
        assert ephemeral or sys.argv[1:] == ["app-server"]
        assert "OPENAI_API_KEY" not in os.environ and "CODEX_API_KEY" not in os.environ
        account = None if ephemeral else "chatgpt"
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            if method == "initialize":
                result = {}
            elif method == "account/login/start":
                params = request["params"]
                assert ephemeral and params["type"] == "apiKey"
                if params["apiKey"] == "rejected-fixture":
                    print(json.dumps({"id": request["id"], "error": {"code": -1, "message": "rejected"}}), flush=True)
                    continue
                if params["apiKey"] == "pending-fixture":
                    (root / "checking").touch()
                    while not (root / "continue").exists():
                        time.sleep(0.01)
                account = "apiKey"
                result = {"type": account}
            elif method == "account/read":
                result = {"account": {"type": account}}
            elif method == "model/list":
                result = {"data": [{"id": "test-model"}]}
            else:
                raise AssertionError(method)
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await test(directory, executable)
    }

    @MainActor
    func testAPIKeyUsesEphemeralStdioAndIsAbsentFromProtocolEvents() async throws {
        try await withRuntime { directory, executable in
            let connection = CodexConnection()
            defer { connection.stop() }
            connection.onNetworkActivity = {}
            var events: [[String: Any]] = []
            connection.onEvent = { events.append($0) }
            try await connection.startWithKey("unit-test-only", executable: executable, directory: directory)
            let models = try await connection.listModels()
            XCTAssertEqual(models.first?["id"] as? String, "test-model")
            XCTAssertFalse(events.isEmpty)
            XCTAssertFalse(String(describing: events).contains("unit-test-only"))
        }
    }

    @MainActor
    func testRejectedSwitchKeepsOpenChatUsableAndLocalSignInCanReplaceKey() async throws {
        try await withRuntime { directory, executable in
            let provider = AccountProvider.codex
            let previousKey = provider.currentKey
            defer { provider.currentKey = previousKey }
            provider.currentKey = "current-fixture"
            let chat = Session(project: directory, storageRoot: directory, provider: .codex)
            defer { chat.stop() }
            try await chat.connect(executable, persistentRuntime: false)
            chat.report(.user, "Keep this conversation")
            let runtime = try XCTUnwrap(chat.client)
            let history = chat.history

            do {
                _ = try await provider.connect(apiKey: "rejected-fixture", executable: executable,
                    sessions: { [chat] }, configureQueue: { _ in XCTFail("Queue changed on rejection") }, status: { _ in })
                XCTFail("Expected the fixture server to reject login")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("could not configure"))
            }
            XCTAssertEqual(provider.currentKey, "current-fixture")
            XCTAssertTrue(chat.ready && chat.client === runtime)
            let models = try await runtime.listModels()
            XCTAssertEqual(models.first?["id"] as? String, "test-model")
            XCTAssertEqual(chat.history, history)

            var reconfigured: [UUID] = []
            _ = try await provider.connect(apiKey: nil, executable: executable, sessions: { [chat] },
                configureQueue: { reconfigured.append($0.id) }, status: { _ in XCTFail("Already signed in locally") })
            XCTAssertNil(provider.currentKey)
            XCTAssertEqual(reconfigured, [chat.id])
            XCTAssertFalse(chat.ready)
            try await chat.connect(executable, persistentRuntime: false)
            let account = try await chat.client?.accountType()
            XCTAssertEqual(account, .chatGPT)
            XCTAssertEqual(chat.history, history)
        }
    }

    @MainActor
    func testTurnStartingDuringKeyVerificationPreventsSwitch() async throws {
        try await withRuntime { directory, executable in
            let chat = Session(project: directory, storageRoot: directory)
            defer { chat.stop() }
            let provider = AccountProvider.codex
            let previousKey = provider.currentKey
            defer { provider.currentKey = previousKey }
            let change = Task {
                try await provider.connect(apiKey: "pending-fixture", executable: executable,
                    sessions: { [chat] }, configureQueue: { _ in XCTFail("Active chat was stopped") }, status: { _ in })
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            let checking = directory.appendingPathComponent("checking").path
            while !FileManager.default.fileExists(atPath: checking), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: checking))
            chat.turn = "existing-turn"
            try Data().write(to: directory.appendingPathComponent("continue"))
            do {
                _ = try await change.value
                XCTFail("Changing credentials during a turn should fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("active"))
            }
            XCTAssertEqual(chat.turn, "existing-turn")
            XCTAssertEqual(provider.currentKey, previousKey)
        }
    }
}
