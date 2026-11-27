import Foundation
import XCTest
@testable import ThoughtStream

final class CodexAPIKeyTests: XCTestCase {
    @MainActor
    func testAPIKeyUsesEphemeralStdioAndIsAbsentFromProtocolEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        assert sys.argv[1:] == ["-c", 'cli_auth_credentials_store="ephemeral"', "app-server"]
        assert "OPENAI_API_KEY" not in os.environ and "CODEX_API_KEY" not in os.environ
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            if method == "initialize":
                result = {}
            elif method == "account/login/start":
                assert request["params"] == {"type": "apiKey", "apiKey": "unit-test-only"}
                result = {"type": "apiKey"}
            elif method == "account/read":
                result = {"account": {"type": "apiKey"}}
            elif method == "model/list":
                result = {"data": [{"id": "test-model"}]}
            else:
                raise AssertionError(method)
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
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
