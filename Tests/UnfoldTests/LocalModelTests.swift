import AppKit
import XCTest
@testable import ThoughtStream

final class LocalModelTests: XCTestCase {
    // MARK: Finding models

    func testFinderReadsBothRuntimeFormatsAndSkipsEmbeddingModels() throws {
        let tags = #"{"models":[{"name":"qwen3:8b","size":5200000000,"details":{"parameter_size":"8.2B"}},{"name":"nomic-embed-text:latest","size":274000000},{"model":"llama3.2:latest"}]}"#
        let ollama = try XCTUnwrap(LocalModelFinder.parse(Data(tags.utf8), runtime: .ollama))
        XCTAssertEqual(ollama.map(\.name), ["qwen3:8b", "llama3.2:latest"])
        XCTAssertEqual(ollama[0].sizeBytes, 5_200_000_000)
        XCTAssertEqual(ollama[0].parameterSize, "8.2B")
        XCTAssertEqual(ollama[0].identifier, "ollama|qwen3:8b")
        XCTAssertEqual(ollama[0].displayName, "qwen3:8b · Ollama")
        let list = #"{"object":"list","data":[{"id":"mlx-community/Qwen3-4B-4bit"},{"id":"text-embedding-nomic"}]}"#
        let studio = try XCTUnwrap(LocalModelFinder.parse(Data(list.utf8), runtime: .lmStudio))
        XCTAssertEqual(studio.map(\.identifier), ["lmstudio|mlx-community/Qwen3-4B-4bit"])
        XCTAssertNil(LocalModelFinder.parse(Data("<html>".utf8), runtime: .ollama), "Something else on that port is not a runtime")
        XCTAssertNil(LocalModelFinder.parse(Data(tags.utf8), runtime: .lmStudio))
        // A chat stores runtime and model together; names may contain slashes and colons.
        XCTAssertEqual(LocalModel.split("lmstudio|mlx-community/Qwen3-4B-4bit")?.model, "mlx-community/Qwen3-4B-4bit")
        XCTAssertNil(LocalModel.split("gpt-6.1-sol"))
        XCTAssertEqual(InferenceSettings(model: "ollama|qwen3:8b", effort: "default", tier: "default").displayName, "qwen3:8b")
    }

    func testCustomServerAddressesAreNormalized() {
        XCTAssertEqual(LocalRuntime.custom("192.168.1.20:8080")?.baseURL.absoluteString, "http://192.168.1.20:8080")
        XCTAssertEqual(LocalRuntime.custom(" http://studio.local:1234/v1/ ")?.baseURL.absoluteString, "http://studio.local:1234")
        XCTAssertEqual(LocalRuntime.custom("192.168.1.20:8080")?.key, "custom:192.168.1.20:8080")
        XCTAssertEqual(LocalRuntime.custom("192.168.1.20:8080")?.kind, .openAI)
        XCTAssertNil(LocalRuntime.custom(""))
        XCTAssertNil(LocalRuntime.custom("ftp://example.com"))
        let defaults = UserDefaults(suiteName: "local-\(UUID().uuidString)")!
        defaults.set(["127.0.0.1:11434", "10.0.0.5:9000"], forKey: LocalRuntime.customEndpointsKey)
        let all = LocalRuntime.all(defaults: defaults)
        XCTAssertEqual(all.count, LocalRuntime.builtIn.count + 1, "A custom entry for a built-in address is not listed twice")
        XCTAssertEqual(all.last?.name, "10.0.0.5:9000")
    }

    @MainActor
    func testRegistryStartsAnInstalledRuntimeAndExplainsWhenNothingCanAnswer() async throws {
        let defaults = UserDefaults(suiteName: "local-\(UUID().uuidString)")!
        let box = RuntimeBox()
        let model = LocalModel(runtime: .ollama, name: "qwen3:8b")
        let registry = LocalModelRegistry(defaults: defaults, discover: { await box.statuses() },
                                          start: { _ in await box.start([model]); return true }, canStart: { $0.key == "ollama" })
        await box.set([LocalRuntimeStatus(runtime: .ollama, isRunning: false, models: [], isInstalled: true)])
        // Nothing is serving, but Ollama is installed: resolving a chat starts it.
        let resolved = try await registry.resolve("")
        XCTAssertEqual(resolved, model)
        let starts = await box.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(registry.preferredModel(), model)
        XCTAssertEqual(registry.records.first?["model"] as? String, "ollama|qwen3:8b")
        // A model added by bare name runs on whichever runtime has it.
        let bare = try await registry.resolve("qwen3:8b")
        XCTAssertEqual(bare, model)
        // A model that was removed says so instead of silently using another.
        do { _ = try await registry.resolve("ollama|gone:latest"); XCTFail("Expected an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("gone:latest is no longer available in Ollama")) }
        await box.set([LocalRuntimeStatus(runtime: .jan, isRunning: false, models: [], isInstalled: true)])
        await registry.refresh()
        do { _ = try await registry.resolve(""); XCTFail("Expected an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No local model runtime is running")) }
        XCTAssertTrue(registry.usesLocalModelsOffline, "Falling back to local models is on by default")
        registry.usesLocalModelsOffline = false
        XCTAssertFalse(registry.usesLocalModelsOffline)
        XCTAssertEqual(registry.contextLength, 16_384)
    }

    // MARK: Wire formats

    func testThinkTagsAreRoutedEvenWhenSplitAcrossFragments() {
        var splitter = ThinkTagSplitter()
        var text = "", reasoning = ""
        for fragment in ["<thi", "nk>plan the ", "answer</th", "ink>Hello", " there <", "b>"] {
            let part = splitter.feed(fragment)
            text += part.text; reasoning += part.reasoning
        }
        let tail = splitter.finish()
        text += tail.text; reasoning += tail.reasoning
        XCTAssertEqual(reasoning, "plan the answer")
        XCTAssertEqual(text, "Hello there <b>")
        var plain = ThinkTagSplitter()
        XCTAssertEqual(plain.feed("a < b and c > d").text + plain.finish().text, "a < b and c > d")
    }

    func testOllamaStreamCarriesThinkingTextAndToolCalls() throws {
        var parser = LocalStreamParser(kind: .ollama)
        var text = "", reasoning = ""
        for line in [
            #"{"message":{"role":"assistant","content":"","thinking":"Check the folder."},"done":false}"#,
            #"{"message":{"role":"assistant","content":"Looking"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"run_command","arguments":{"command":"ls -la"}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        ] {
            let chunk = try parser.consume(line)
            text += chunk.text; reasoning += chunk.reasoning
        }
        XCTAssertTrue(parser.isDone)
        _ = parser.finish()
        XCTAssertEqual(text, "Looking")
        XCTAssertEqual(reasoning, "Check the folder.")
        XCTAssertEqual(parser.reply.toolCalls.count, 1)
        XCTAssertEqual(parser.reply.toolCalls[0].name, "run_command")
        XCTAssertEqual(parser.reply.toolCalls[0].arguments["command"] as? String, "ls -la")
        var failing = LocalStreamParser(kind: .ollama)
        XCTAssertThrowsError(try failing.consume(#"{"error":"model requires more system memory"}"#)) {
            XCTAssertEqual($0.localizedDescription, "model requires more system memory")
        }
    }

    func testOpenAIStreamAssemblesFragmentedToolArguments() throws {
        var parser = LocalStreamParser(kind: .openAI)
        var text = ""
        for line in [
            ": keep-alive", "",
            #"data: {"choices":[{"delta":{"role":"assistant","content":"On it. "}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"notes.txt\","}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"content\":\"hi\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"list_directory","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]"
        ] { text += try parser.consume(line).text }
        XCTAssertTrue(parser.isDone)
        _ = parser.finish()
        XCTAssertEqual(text, "On it. ")
        XCTAssertEqual(parser.reply.toolCalls.map(\.name), ["write_file", "list_directory"])
        XCTAssertEqual(parser.reply.toolCalls[0].id, "call_1")
        XCTAssertEqual(parser.reply.toolCalls[0].arguments["path"] as? String, "notes.txt")
        XCTAssertEqual(parser.reply.toolCalls[0].arguments["content"] as? String, "hi")
        XCTAssertTrue(parser.reply.toolCalls[1].arguments.isEmpty)
    }

    @MainActor
    func testRequestsMatchEachRuntimesProtocol() throws {
        let call = LocalToolCall(id: "call_1", name: "read_file", arguments: ["path": "a.txt"])
        let messages: [LocalChatMessage] = [.system("Be brief."), .user("Look", images: [Data([1, 2, 3])]),
                                            .assistant("", toolCalls: [call]), .tool(callID: "call_1", name: "read_file", content: "1\thello")]
        func body(_ runtime: LocalRuntime) throws -> ([String: Any], URLRequest) {
            let request = try LocalModelClient(runtime: runtime, session: .shared)
                .chatRequest(model: "m", messages: messages, tools: LocalToolbox.schemas, contextLength: 8192)
            return (try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]), request)
        }
        let (ollama, ollamaRequest) = try body(.ollama)
        XCTAssertEqual(ollamaRequest.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual((ollama["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        XCTAssertEqual((ollama["tools"] as? [[String: Any]])?.count, LocalToolbox.schemas.count)
        let ollamaMessages = try XCTUnwrap(ollama["messages"] as? [[String: Any]])
        XCTAssertEqual(ollamaMessages[1]["images"] as? [String], ["AQID"])
        let nativeCall = ((ollamaMessages[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        XCTAssertEqual((nativeCall?["arguments"] as? [String: Any])?["path"] as? String, "a.txt", "Ollama takes arguments as an object")
        XCTAssertEqual(ollamaMessages[3]["tool_name"] as? String, "read_file")

        let (open, openRequest) = try body(.lmStudio)
        XCTAssertEqual(openRequest.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertNil(open["options"])
        let openMessages = try XCTUnwrap(open["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(openMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual((parts.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AQID")
        let openCall = (openMessages[2]["tool_calls"] as? [[String: Any]])?.first
        XCTAssertEqual(openCall?["id"] as? String, "call_1")
        XCTAssertEqual((openCall?["function"] as? [String: Any])?["arguments"] as? String, #"{"path":"a.txt"}"#, "OpenAI takes arguments as a JSON string")
        XCTAssertEqual(openMessages[3]["tool_call_id"] as? String, "call_1")

        let capabilities = LocalModelClient.capabilities(["capabilities": ["completion", "tools", "thinking"],
                                                          "model_info": ["qwen3.context_length": 40960, "general.architecture": "qwen3"]])
        XCTAssertEqual(capabilities, LocalModelCapabilities(tools: true, contextLength: 40960))
        XCTAssertEqual(LocalModelClient.capabilities(["capabilities": ["completion"]]).tools, false)
        XCTAssertNil(LocalModelClient.capabilities([:]).tools)
        XCTAssertTrue(LocalModelClient.isToolsRefusal(LocalModelClient.error("registry.ollama.ai/library/gemma3:4b does not support tools")))
        XCTAssertFalse(LocalModelClient.isToolsRefusal(LocalModelClient.error("model requires more system memory")))
    }

    // MARK: Acting on the Mac

    @MainActor
    func testWorkspaceAccessAsksBeforeActingButReadsTheProjectFreely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = LocalToolbox(project: root)
        func call(_ name: String, _ arguments: [String: Any]) -> LocalToolCall { LocalToolCall(id: UUID().uuidString, name: name, arguments: arguments) }
        toolbox.accessMode = { .workspace }
        XCTAssertFalse(toolbox.needsApproval(call("read_file", ["path": "notes.txt"])))
        XCTAssertFalse(toolbox.needsApproval(call("list_directory", [:])))
        XCTAssertTrue(toolbox.needsApproval(call("read_file", ["path": "/etc/hosts"])))
        XCTAssertTrue(toolbox.needsApproval(call("read_file", ["path": "../outside.txt"])), "Leaving the project needs approval")
        for name in ["run_command", "write_file", "edit_file", "open_item", "run_applescript"] {
            XCTAssertTrue(toolbox.needsApproval(call(name, ["path": "notes.txt", "command": "ls"])), name)
        }
        toolbox.accessMode = { .fullAccess }
        for name in ["run_command", "write_file", "run_applescript", "read_file"] {
            XCTAssertFalse(toolbox.needsApproval(call(name, ["path": "/etc/hosts", "command": "ls"])), name)
        }
        XCTAssertEqual(toolbox.summary(call("run_command", ["command": "git status"])), "Run: git status")
        XCTAssertEqual(toolbox.resolve("sub/a.txt").path, root.appendingPathComponent("sub/a.txt").standardizedFileURL.path)
        XCTAssertEqual(toolbox.resolve("/tmp/x").path, "/tmp/x")
        // Every tool the prompt describes has a schema a runtime can send.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(LocalToolbox.schemas))
        XCTAssertEqual(Set(LocalToolbox.schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }),
                       ["run_command", "read_file", "write_file", "edit_file", "list_directory", "open_item", "run_applescript"])
    }

    @MainActor
    func testToolsRunCommandsAndChangeFilesAndReportLikeOtherProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = LocalToolbox(project: root)
        toolbox.accessMode = { .fullAccess }
        var events: [(String, [String: Any])] = []
        toolbox.emit = { events.append(($0, $1)) }
        func item(_ method: String, type: String) -> [String: Any]? {
            events.last { $0.0 == method && ($0.1["item"] as? [String: Any])?["type"] as? String == type }?.1["item"] as? [String: Any]
        }
        // A command runs in the project, streams its output and reports its exit code.
        let listing = await toolbox.run(LocalToolCall(id: "c1", name: "run_command", arguments: ["command": "printf 'héllo\\n'; pwd; exit 3"]))
        XCTAssertTrue(listing.contains("héllo"))
        XCTAssertTrue(listing.contains(root.lastPathComponent))
        XCTAssertTrue(listing.hasSuffix("[exit code 3]"))
        XCTAssertEqual(item("item/started", type: "commandExecution")?["command"] as? String, "printf 'héllo\\n'; pwd; exit 3")
        let finished = try XCTUnwrap(item("item/completed", type: "commandExecution"))
        XCTAssertEqual(finished["status"] as? String, "failed")
        XCTAssertEqual(finished["exitCode"] as? Int, 3)
        let streamed = events.filter { $0.0 == "item/commandExecution/outputDelta" }.compactMap { $0.1["delta"] as? String }.joined()
        XCTAssertEqual(streamed, finished["aggregatedOutput"] as? String, "Streamed output matches the final record exactly once")
        // A runaway command is stopped at its time limit.
        let slow = await toolbox.run(LocalToolCall(id: "c2", name: "run_command", arguments: ["command": "echo start; sleep 30", "timeout_seconds": 1]))
        XCTAssertTrue(slow.contains("start"))
        XCTAssertTrue(slow.contains("Stopped after 1 seconds"))
        // Files: create, read with line numbers, edit exactly, and refuse an ambiguous edit.
        let created = await toolbox.run(LocalToolCall(id: "w1", name: "write_file", arguments: ["path": "notes/todo.txt", "content": "alpha\nbeta\ngamma\nbeta-2\n"]))
        XCTAssertTrue(created.hasPrefix("Created "))
        var change = try XCTUnwrap((item("item/completed", type: "fileChange")?["changes"] as? [[String: Any]])?.first)
        XCTAssertTrue((change["diff"] as? String ?? "").contains("+++ " + root.appendingPathComponent("notes/todo.txt").standardizedFileURL.path))
        XCTAssertTrue((change["diff"] as? String ?? "").contains("--- /dev/null"))
        let read = await toolbox.run(LocalToolCall(id: "r1", name: "read_file", arguments: ["path": "notes/todo.txt", "start_line": 2, "max_lines": 2]))
        XCTAssertTrue(read.hasPrefix("2\tbeta\n3\tgamma"))
        XCTAssertTrue(read.contains("read again with start_line 4"))
        let ambiguous = await toolbox.run(LocalToolCall(id: "e0", name: "edit_file", arguments: ["path": "notes/todo.txt", "old_text": "beta", "new_text": "BETA"]))
        XCTAssertTrue(ambiguous.contains("appears 2 times"))
        let edited = await toolbox.run(LocalToolCall(id: "e1", name: "edit_file", arguments: ["path": "notes/todo.txt", "old_text": "gamma", "new_text": "delta"]))
        XCTAssertTrue(edited.hasPrefix("Updated "))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes/todo.txt"), encoding: .utf8), "alpha\nbeta\ndelta\nbeta-2\n")
        change = try XCTUnwrap((item("item/completed", type: "fileChange")?["changes"] as? [[String: Any]])?.first)
        let diff = try XCTUnwrap(change["diff"] as? String)
        XCTAssertTrue(diff.contains("@@ -1,5 +1,5 @@"), diff)
        XCTAssertTrue(diff.contains("-gamma\n+delta"), diff)
        XCTAssertTrue(diff.contains(" alpha\n beta\n"), diff)
        let listed = await toolbox.run(LocalToolCall(id: "l1", name: "list_directory", arguments: [:]))
        XCTAssertTrue(listed.contains("notes/"))
        let missing = await toolbox.run(LocalToolCall(id: "r2", name: "read_file", arguments: ["path": "nope.txt"]))
        XCTAssertTrue(missing.hasPrefix("Error: "))
        let unknown = await toolbox.run(LocalToolCall(id: "u1", name: "launch_rocket", arguments: [:]))
        XCTAssertTrue(unknown.contains("Unknown tool launch_rocket"))
    }

    @MainActor
    func testDeclinedActionNeverRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolbox = LocalToolbox(project: root)
        toolbox.accessMode = { .workspace }
        var asked: [String] = []
        toolbox.approve = { call, summary in asked.append(summary); return false }
        let marker = root.appendingPathComponent("ran")
        let result = await toolbox.run(LocalToolCall(id: "c1", name: "run_command", arguments: ["command": "touch \(marker.path)"]))
        XCTAssertEqual(asked, ["Run: touch \(marker.path)"])
        XCTAssertTrue(result.contains("declined"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let write = await toolbox.run(LocalToolCall(id: "w1", name: "write_file", arguments: ["path": "a.txt", "content": "x"]))
        XCTAssertTrue(write.contains("declined"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testDiffShowsOnlyChangedHunksWithContext() {
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 5\n", with: "line five\n").replacingOccurrences(of: "line 30\n", with: "line 30\ninserted\n")
        let diff = MainActor.assumeIsolated { LocalToolbox.diff(old: old, new: new, path: "/p/a.txt", isNew: false) }
        XCTAssertTrue(diff.hasPrefix("--- /p/a.txt\n+++ /p/a.txt\n@@ -2,7 +2,7 @@"), diff)
        XCTAssertTrue(diff.contains("-line 5\n+line five"))
        XCTAssertTrue(diff.contains("@@ -28,6 +28,7 @@\n line 28\n line 29\n line 30\n+inserted\n line 31"), diff)
        XCTAssertTrue(diff.contains("+inserted"))
        XCTAssertFalse(diff.contains("line 15"), "Unchanged regions are left out")
    }

    // MARK: A whole local chat

    @MainActor
    func testLocalChatsWorkOfflineUseToolsWithApprovalAndRunSideBySide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); LocalRuntimeStub.reset() }
        // The model first asks to run a command, then answers with its output.
        LocalRuntimeStub.respond = { request, body in
            switch request.url?.path {
            case "/api/show":
                return (200, [Data(#"{"capabilities":["completion","tools"],"model_info":{"qwen3.context_length":8192}}"#.utf8)])
            case "/api/chat":
                let messages = body["messages"] as? [[String: Any]] ?? []
                if let result = messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String {
                    let name = (messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? "").contains("second") ? "second" : "first"
                    return (200, [#"{"message":{"role":"assistant","content":"The \#(name) command printed "},"done":false}"#,
                                  #"{"message":{"role":"assistant","content":"\#(result.components(separatedBy: "\n")[0])."},"done":false}"#,
                                  #"{"message":{"role":"assistant","content":""},"done":true}"#].map { Data(($0 + "\n").utf8) })
                }
                return (200, [#"{"message":{"role":"assistant","content":"","thinking":"I should run it."},"done":false}"#,
                              #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"run_command","arguments":{"command":"echo local-ok"}}}]},"done":false}"#,
                              #"{"message":{"role":"assistant","content":""},"done":true}"#].map { Data(($0 + "\n").utf8) })
            default: return (404, [Data()])
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalRuntimeStub.self]
        let network = URLSession(configuration: configuration)
        let model = LocalModel(runtime: .ollama, name: "qwen3:8b")
        let defaults = UserDefaults(suiteName: "local-\(UUID().uuidString)")!
        let registry = LocalModelRegistry(defaults: defaults,
            discover: { [LocalRuntimeStatus(runtime: .ollama, isRunning: true, models: [model], isInstalled: true)] },
            start: { _ in false }, canStart: { _ in false })
        // No Internet at all: the probe never succeeds.
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { false })
        var chats: [Session] = []
        var approvals: [String] = []
        defer { chats.forEach { $0.stop() }; monitor.stop() }
        for prompt in ["Run the first command", "Run the second command"] {
            let chat = Session(project: root, storageRoot: root, provider: .local)
            chat.localModels = registry
            chat.makeLocalConnection = { LocalModelConnection(session: network) }
            chat.onRequest = { [weak chat] id, method, params in
                XCTAssertEqual(method, "local/tool/requestApproval")
                approvals.append(params["reason"] as? String ?? "")
                try? chat?.respond(id, ["decision": "accept"])
            }
            chat.configureMessageQueue(connectivity: monitor) { [weak chat] in try await chat?.connectLocal() }
            try chat.enqueueChat(prompt, attachments: [], settings: InferenceSettings(model: "", effort: "default", tier: "default"))
            chats.append(chat)
        }
        // Whether the saved access mode asks first or not, both chats finish.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !chats.allSatisfy({ chat in chat.turn == nil && chat.outbox.pending == nil && chat.history.contains { $0.isFinalResponse == true } }) {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(monitor.isOnline)
        for (chat, name) in zip(chats, ["first", "second"]) {
            let history = chat.history
            XCTAssertEqual(history.last { $0.kind == StreamKind.prose.rawValue }?.text, "The \(name) command printed local-ok.", "\(history.map { $0.kind + ": " + $0.text }) \(chat.outbox.pending?.detail ?? "")")
            XCTAssertTrue(history.contains { $0.kind == StreamKind.command.rawValue && $0.text.contains("$ echo local-ok") && $0.command?.state == .succeeded })
            XCTAssertTrue(history.contains { $0.kind == StreamKind.output.rawValue && $0.text.contains("local-ok") })
            XCTAssertTrue(history.contains { $0.kind == StreamKind.reasoning.rawValue && $0.text == "I should run it." })
            XCTAssertEqual(history.filter { $0.kind == StreamKind.user.rawValue }.count, 1)
            XCTAssertNil(history.first { $0.kind == StreamKind.user.rawValue }?.queuedStatus)
            XCTAssertEqual(chat.inferenceSettings.model, "ollama|qwen3:8b", "A chat with no model takes the first one found and keeps it")
            XCTAssertNil(chat.thread, "A local chat has no cloud thread")
        }
        if AccessMode.selected != .fullAccess { XCTAssertEqual(approvals, ["Run: echo local-ok", "Run: echo local-ok"]) }
        // The tool result went back to the model, with the conversation memory capped by the model.
        let followUps = LocalRuntimeStub.bodies.filter { ($0["messages"] as? [[String: Any]])?.contains { $0["role"] as? String == "tool" } == true }
        XCTAssertEqual(followUps.count, 2)
        let sent = try XCTUnwrap(followUps.first)
        XCTAssertEqual((sent["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        XCTAssertEqual(sent["model"] as? String, "qwen3:8b")
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertTrue((messages.first?["content"] as? String ?? "").contains(root.path))
        XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("local-ok\n[exit code 0]"))
        XCTAssertEqual(messages.last?["tool_name"] as? String, "run_command")
        // A follow-up waits for the turn, then continues the same conversation.
        try chats[0].enqueueChat("And again", attachments: [], settings: chats[0].inferenceSettings)
        let next = Date().addingTimeInterval(20)
        while Date() < next, !(chats[0].turn == nil && chats[0].outbox.pending == nil) { try await Task.sleep(nanoseconds: 30_000_000) }
        let last = try XCTUnwrap(LocalRuntimeStub.bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(last.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }, ["Run the first command", "And again"])
        // A fork starts from the same history with its own context.
        let fork = try await chats[0].fork()
        defer { fork.stop(); try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(fork.id.uuidString)) }
        XCTAssertEqual(fork.provider, .local)
        XCTAssertEqual(fork.history.filter { $0.kind == StreamKind.user.rawValue }.count, 2)
    }

    @MainActor
    func testRelaunchedLocalChatRemembersItsConversation() {
        let connection = LocalModelConnection(session: .shared)
        connection.seed(from: [
            StreamRecord(kind: StreamKind.user.rawValue, text: "What is in this folder?"),
            StreamRecord(kind: StreamKind.command.rawValue, text: "/p\n$ ls"),
            StreamRecord(kind: StreamKind.prose.rawValue, text: "Two files."),
            StreamRecord(kind: StreamKind.user.rawValue, text: #"{"type":"local_image","path":"/tmp/a.png"}"#),
            StreamRecord(kind: StreamKind.user.rawValue, text: "Still waiting", queuedMessageID: UUID().uuidString)
        ])
        XCTAssertTrue(connection.hasContext)
        let prompt = LocalModelConnection.systemPrompt(project: URL(fileURLWithPath: "/p"), tools: true)
        XCTAssertTrue(prompt.contains("run shell commands"))
        XCTAssertTrue(LocalModelConnection.systemPrompt(project: URL(fileURLWithPath: "/p"), tools: false).contains("cannot use tools"))
    }
}

private actor RuntimeBox {
    private var value: [LocalRuntimeStatus] = []
    private(set) var starts = 0
    func set(_ statuses: [LocalRuntimeStatus]) { value = statuses }
    func statuses() -> [LocalRuntimeStatus] { value }
    func start(_ models: [LocalModel]) {
        starts += 1
        value = value.map { LocalRuntimeStatus(runtime: $0.runtime, isRunning: true, models: models, isInstalled: true) }
    }
}

/// Serves canned runtime responses and records what each chat sent.
final class LocalRuntimeStub: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest, [String: Any]) -> (Int, [Data]))?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [[String: Any]] = []
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset() { lock.lock(); recorded = []; lock.unlock(); respond = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if request.url?.path == "/api/chat" || request.url?.path == "/v1/chat/completions" {
            Self.lock.lock(); Self.recorded.append(body); Self.lock.unlock()
        }
        let (status, chunks) = Self.respond?(request, body) ?? (500, [Data()])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
