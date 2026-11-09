import XCTest
@testable import ThoughtStream

@MainActor
final class RuntimeReconnectTests: XCTestCase {
    func testLocalHostSurvivesClosingAndReopeningItsSocket() async throws {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNFOLD_TEST_CODEX_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ThoughtStream.app/Contents/Resources/codex/bin/codex").path)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Local Codex runtime is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), first = CodexConnection(), second = CodexConnection()
        defer {
            first.stop(); second.stop(terminateRuntime: true)
            CodexRuntimeHost.stop(id: id)
            try? FileManager.default.removeItem(at: root)
        }
        var methods: [String] = []
        first.onEvent = { if let method = $0["method"] as? String { methods.append(method) } }
        second.onEvent = first.onEvent
        // Local protocol only: never request inference or send any prompt.
        try await first.start(executable: executable, project: root, persistentID: id)
        let created = try await first.request("thread/start", ["cwd": root.path, "ephemeral": false,
                                                                "sandbox": "read-only", "approvalPolicy": "never"])
        let thread = try XCTUnwrap((created["thread"] as? [String: Any])?["id"] as? String)
        let fixture = String(repeating: "Local reconnect fixture. ", count: 3000)
        _ = try await first.request("thread/inject_items", ["threadId": thread, "items": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": fixture]]]]])
        let socket = try CodexRuntimeHost.socket(for: id)
        let before = try String(contentsOf: socket.appendingPathExtension("pid"))
        first.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        try await second.start(executable: executable, project: root, persistentID: id)
        let loaded = try await second.request("thread/loaded/list")
        XCTAssertTrue((loaded["data"] as? [String] ?? []).contains(thread), "Host must keep the thread loaded after disconnect")
        let resumed = try await second.request("thread/resume", ["threadId": thread, "excludeTurns": true,
                                                                  "initialTurnsPage": ["limit": 1, "itemsView": "full", "sortDirection": "desc"]])
        XCTAssertEqual((resumed["thread"] as? [String: Any])?["id"] as? String, thread)
        XCTAssertEqual(try String(contentsOf: socket.appendingPathExtension("pid")), before)
        XCTAssertTrue((resumed["initialTurnsPage"] as? [String: Any])?["data"] as? [[String: Any]] == nil
                      || ((resumed["initialTurnsPage"] as? [String: Any])?["data"] as? [[String: Any]])?.isEmpty == true)
        _ = try await second.request("thread/archive", ["threadId": thread])
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("turn/steer"))
    }

}
