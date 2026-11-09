import Foundation

/// Claude Code's bidirectional stream-json transport. Emits the same semantic
/// events as the Codex adapter so both providers share the native feed.
@MainActor
final class ClaudeConnection {
    var onEvent: (([String: Any]) -> Void)?
    var onSession: ((String) -> Void)?
    var onModels: (([[String: Any]]) -> Void)?
    var onDisconnect: (() -> Void)?
    var onNetworkActivity: () -> Void = { ConnectivityMonitor.shared.recordNetworkActivity() }
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var permissions: [String: [String: Any]] = [:]
    private var tools: [String: [String: Any]] = [:]
    private var messageID = ""
    private var turnID: String?
    private var lastText: (id: String, text: String)?
    private var intentionalStop = false
    private var stderrText = ""

    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [UserDefaults.standard.string(forKey: "claudePath"), home + "/.local/bin/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .compactMap { $0 } + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexConnection.error("Install Claude Code, then sign in with ‘claude auth login’ in Terminal.")
        }
        return URL(fileURLWithPath: path)
    }

    static func isAuthenticated() async throws -> Bool {
        let executable = try executable()
        return try await Task.detached {
            let task = Process(), output = Pipe()
            task.executableURL = executable; task.arguments = ["auth", "status"]
            task.standardOutput = output; task.standardError = FileHandle.nullDevice
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return value?["loggedIn"] as? Bool == true
        }.value
    }

    /// Launch the official interactive sign-in, preserving a custom account
    /// directory. Quote paths as shell data, including apostrophes and spaces.
    static func signInScript(executable: URL, configDirectory: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/zsh\nunset CLAUDECODE\n"
        if let configDirectory { script += "export CLAUDE_CONFIG_DIR=\(quote(configDirectory))\n" }
        script += "exec \(quote(executable.path)) auth login --claudeai\n"
        return script
    }

    static func arguments(settings: InferenceSettings, mode: AccessMode, resume: String?, fork: Bool) -> [String] {
        var args = ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--permission-mode", mode == .fullAccess ? "bypassPermissions" : "manual",
                    "--model", settings.model, "--effort", settings.effort,
                    "--settings", "{\"fastMode\":\(settings.claudeFastModeEnabled)}",
                    "--append-system-prompt", AgentInstructions.text]
        if let resume { args += ["--resume", resume] }
        if fork { args.append("--fork-session") }
        return args
    }

    static var discoveryArguments: [String] {
        ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
         "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
         "--tools", "", "--disable-slash-commands", "--settings", "{\"disableAllHooks\":true}"]
    }

    static func modelRecords(_ models: [[String: Any]]) -> [[String: Any]] {
        models.compactMap { model in
            guard let id = model["value"] as? String ?? model["id"] as? String, !id.isEmpty else { return nil }
            var record = model
            record["model"] = id
            record["displayName"] = model["displayName"] as? String ?? id
            let efforts = model["supportedEffortLevels"] as? [String] ?? InferenceSettings.claudeEfforts
            let supported: [[String: String]] = efforts.map { ["reasoningEffort": $0] }
            record["supportedReasoningEfforts"] = supported
            return record
        }
    }

    func start(executable: URL, project: URL, settings: InferenceSettings, resume: String?, fork: Bool = false, discoveryOnly: Bool = false) async throws {
        guard process == nil else { return }
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        input = stdin; output = stdout; errors = stderr; intentionalStop = false
        task.executableURL = executable; task.currentDirectoryURL = project
        task.arguments = discoveryOnly ? Self.discoveryArguments : Self.arguments(settings: settings, mode: AccessMode.selected, resume: resume, fork: fork)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        task.environment = env
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(bytes) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in
                let text = String(decoding: bytes, as: UTF8.self)
                self?.stderrText += text
                self?.stderrText = String(self?.stderrText.suffix(4000) ?? "")
                self?.emit("runtime/stderr", ["text": text])
            }
        }
        task.terminationHandler = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self, self.process === task else { return }
                self.process = nil
                self.failPending("Claude Code exited (status \(task.terminationStatus)). \(self.stderrText)")
                if !self.intentionalStop { self.onDisconnect?() }
            }
        }
        try task.run(); process = task
        do {
            let initialized = try await control(["subtype": "initialize"])
            if let models = initialized["models"] as? [[String: Any]] { onModels?(Self.modelRecords(models)) }
        } catch { stop(); throw error }
    }

    func send(_ content: [[String: Any]]) throws {
        if turnID == nil {
            let id = UUID().uuidString; turnID = id; lastText = nil
            emit("turn/started", ["turn": ["id": id]])
        }
        try write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func interrupt() async throws { _ = try await control(["subtype": "interrupt"]) }

    func respond(_ id: String, result: [String: Any]) throws {
        guard let request = permissions[id] else { throw CodexConnection.error("This Claude request is no longer pending.") }
        let allow = result["decision"] as? String == "accept"
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": result["updatedInput"] ?? request["input"] ?? [:]]
            : ["behavior": "deny", "message": "The user declined this request."]
        try write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
        permissions.removeValue(forKey: id)
    }

    func stop() {
        intentionalStop = true
        output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        process?.terminate(); process = nil
        failPending("Claude Code stopped.")
    }
    private func failPending(_ text: String) {
        let callbacks = pending; pending.removeAll()
        for callback in callbacks.values { callback.resume(throwing: CodexConnection.error(text)) }
    }
    private func control(_ request: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["type": "control_request", "request_id": id, "request": request]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.pending.removeValue(forKey: id)?.resume(throwing: CodexConnection.error("Claude Code did not answer \(request["subtype"] ?? "request") within 60 seconds."))
            }
        }
    }
    private func write(_ message: [String: Any]) throws {
        guard process?.isRunning == true, let input else { throw CodexConnection.error("Claude Code is not running.") }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        onEvent?(["_direction": "outgoing", "_provider": "claude", "payload": message])
    }
    private func emit(_ method: String, _ params: [String: Any]) { onEvent?(["method": method, "params": params, "_provider": "claude"]) }

    func receive(_ bytes: Data) {
        for line in CodexConnection.completeLines(appending: bytes, to: &buffer) {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            receive(event)
        }
    }
    func receive(_ event: [String: Any]) {
        if ProviderNetworkActivity.claude(event) { onNetworkActivity() }
        // Raw provider frames remain available in the redacted protocol export.
        onEvent?(["_provider": "claude", "payload": event])
        switch event["type"] as? String {
        case "control_response":
            guard let response = event["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let callback = pending.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "error" { callback.resume(throwing: CodexConnection.error(response["error"] as? String ?? "Claude request failed.")) }
            else { callback.resume(returning: response["response"] as? [String: Any] ?? [:]) }
        case "control_request":
            guard let request = event["request"] as? [String: Any], let id = event["request_id"] as? String else { return }
            if request["subtype"] as? String == "can_use_tool" {
                permissions[id] = request
                onEvent?(["id": id, "method": "claude/tool/requestApproval", "params": request])
            } else {
                try? write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported host request"]])
            }
        case "control_cancel_request":
            if let id = event["request_id"] as? String { permissions.removeValue(forKey: id); emit("serverRequest/resolved", ["requestId": id]) }
        case "system":
            // Startup hooks have an ID before a conversation exists on disk.
            // Only the initialized conversation or its result is resumable.
            if event["subtype"] as? String == "init", let id = event["session_id"] as? String { onSession?(id) }
            if event["subtype"] as? String == "compact_boundary" { emit("item/completed", ["item": ["type": "contextCompaction"]]) }
            if event["subtype"] as? String == "api_retry" { emit("runtime/stderr", ["text": "Claude is retrying: \(event["error"] ?? "request failed")"] ) }
        case "stream_event":
            guard event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil,
                  let stream = event["event"] as? [String: Any] else { return }
            if stream["type"] as? String == "message_start", let message = stream["message"] as? [String: Any] {
                messageID = message["id"] as? String ?? UUID().uuidString
            }
            if stream["type"] as? String == "content_block_delta", let delta = stream["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                emit("item/agentMessage/delta", ["itemId": messageID, "delta": text])
            }
        case "assistant":
            guard let message = event["message"] as? [String: Any] else { return }
            let parent = event["parent_tool_use_id"] as? String
            let id = message["id"] as? String ?? UUID().uuidString
            let content = message["content"] as? [[String: Any]] ?? []
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !text.isEmpty, parent == nil {
                lastText = (id, text)
                emit("item/completed", ["item": ["id": id, "type": "agentMessage", "text": text, "phase": "commentary"]])
            }
            for block in content where block["type"] as? String == "tool_use" {
                guard let toolID = block["id"] as? String, tools[toolID] == nil else { continue }
                tools[toolID] = block
                let input = block["input"] as? [String: Any] ?? [:]
                if block["name"] as? String == "Bash" {
                    emit("item/started", ["item": ["id": toolID, "type": "commandExecution", "command": input["command"] ?? "Shell command"]])
                } else { emit("item/started", ["item": ["id": toolID, "type": "dynamicToolCall", "tool": block["name"] ?? "Tool", "arguments": input]]) }
            }
        case "user":
            let message = event["message"] as? [String: Any] ?? [:]
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let tool = tools.removeValue(forKey: id) else { continue }
                let failed = block["is_error"] as? Bool ?? false
                let content = block["content"]
                let text = (content as? String) ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                if tool["name"] as? String == "Bash" {
                    // Tool success is known, but the shell's numeric exit status
                    // is not guaranteed by stream-json. Do not invent one.
                    emit("item/completed", ["item": ["id": id, "type": "commandExecution", "status": failed ? "failed" : "succeeded", "aggregatedOutput": text]])
                } else { emit("item/completed", ["item": ["id": id, "type": "dynamicToolCall", "tool": tool["name"] ?? "Tool", "result": content ?? "", "isError": failed]]) }
            }
        case "result":
            if let id = event["session_id"] as? String { onSession?(id) }
            let failed = event["is_error"] as? Bool ?? false
            let text = event["result"] as? String ?? lastText?.text ?? ""
            if !failed, !text.isEmpty {
                emit("item/completed", ["item": ["id": lastText?.id ?? UUID().uuidString, "type": "agentMessage", "text": text, "phase": "final_answer"]])
            }
            var turn: [String: Any] = ["id": turnID ?? "", "status": failed ? "failed" : "completed"]
            if failed { turn["error"] = ["message": (event["errors"] as? [String])?.joined(separator: "\n") ?? text] }
            turnID = nil; lastText = nil; tools.removeAll(); permissions.removeAll()
            emit("turn/completed", ["turn": turn])
        default: break
        }
    }
}
