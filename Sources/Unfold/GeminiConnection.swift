import Foundation
import Darwin

/// Gemini CLI's documented headless JSONL protocol. Each turn starts a process
/// and resumes the exact provider session; no prompt is sent during discovery.
@MainActor
final class GeminiConnection {
    var onEvent: (([String: Any]) -> Void)?
    var onSession: ((String) -> Void)?
    private var process: Process?
    private var generation: UUID?
    private var buffer = Data()
    private var turnID: String?
    private var messageID = UUID().uuidString
    private var text = ""
    private var result: [String: Any]?
    private var failure: String?
    private var interrupted = false
    private var tools: [String: [String: Any]] = [:]

    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [UserDefaults.standard.string(forKey: "geminiPath"), home + "/.local/bin/gemini",
                     "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
            .compactMap { $0 } + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/gemini" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexConnection.error("Install Gemini CLI in Terminal with ‘npm install -g @google/gemini-cli’, then run ‘gemini’ to sign in. Return here and retry your message.")
        }
        return URL(fileURLWithPath: path)
    }

    static func arguments(model: String, mode: AccessMode, resume: String?) -> [String] {
        // Headless CLI cannot display permission prompts. In default mode it
        // denies actions needing approval; only explicit Full access uses yolo.
        var args = ["--output-format", "stream-json", "--model", model,
                    "--approval-mode", mode == .fullAccess ? "yolo" : "default"]
        if let resume { args += ["--resume", resume] }
        return args
    }

    func send(_ prompt: String, attachments: [ChatAttachment], executable: URL, project: URL,
              model: String, resume: String?, beforeLaunch: () throws -> Void = {}) throws {
        guard process == nil else { throw CodexConnection.error("Wait for Gemini to finish, or stop the current turn.") }
        _ = try Session.messageInput(prompt, attachments: attachments)
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("thoughtstream-gemini-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var launched = false
        defer { if !launched { try? fm.removeItem(at: directory) } }
        // Stage images under simple names, so CLI @path parsing is unambiguous.
        // The directory is included explicitly because attachments live outside
        // the project. No unrelated directories are added to Gemini's workspace.
        var input = prompt
        for (index, attachment) in attachments.enumerated() {
            let image = directory.appendingPathComponent("image-\(index).png")
            try fm.copyItem(at: URL(fileURLWithPath: attachment.path), to: image)
            input += "\n@\"\(image.path)\""
        }
        let inputURL = directory.appendingPathComponent("input.txt")
        let errorURL = directory.appendingPathComponent("stderr.txt")
        try Data(input.utf8).write(to: inputURL)
        fm.createFile(atPath: errorURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { if !launched { try? stdin.close(); try? stderr.close() } }
        let task = Process(), stdout = Pipe()
        task.executableURL = executable; task.currentDirectoryURL = project
        task.arguments = Self.arguments(model: model, mode: AccessMode.selected, resume: resume)
        if !attachments.isEmpty { task.arguments! += ["--include-directories", directory.path] }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["NO_COLOR"] = "1"
        task.environment = env
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        try beforeLaunch()
        try task.run()
        launched = true
        process = task
        let token = UUID(); generation = token
        buffer.removeAll(); text = ""; result = nil; failure = nil; interrupted = false; tools.removeAll()
        messageID = UUID().uuidString; turnID = UUID().uuidString
        emit("turn/started", ["turn": ["id": turnID!]])
        // One reader delivers frames in order and drains EOF before completion.
        // stderr goes to a file so neither pipe can deadlock the other.
        Task.detached { [weak self] in
            defer {
                try? stdin.close(); try? stderr.close(); try? stdout.fileHandleForReading.close()
                try? fm.removeItem(at: directory)
            }
            while true {
                let bytes = stdout.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                await self?.receive(bytes, generation: token)
            }
            task.waitUntilExit()
            var errorText = ""
            if let handle = try? FileHandle(forReadingFrom: errorURL) {
                if let end = try? handle.seekToEnd() {
                    try? handle.seek(toOffset: end > 8000 ? end - 8000 : 0)
                    if let bytes = try? handle.readToEnd() { errorText = String(decoding: bytes, as: UTF8.self) }
                }
                try? handle.close()
            }
            await self?.exited(status: task.terminationStatus, stderr: errorText, generation: token)
        }
    }

    private func receive(_ bytes: Data, generation token: UUID) {
        guard generation == token else { return }
        for line in CodexConnection.completeLines(appending: bytes, to: &buffer) {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            receive(event)
        }
    }

    private func receive(_ event: [String: Any]) {
        onEvent?(["_provider": "gemini", "payload": event])
        switch event["type"] as? String {
        case "init":
            if let id = event["session_id"] as? String, !id.isEmpty { onSession?(id) }
        case "message":
            guard event["role"] as? String == "assistant", let content = event["content"] as? String else { return }
            ConnectivityMonitor.shared.recordNetworkActivity()
            if event["delta"] as? Bool == true {
                text += content
                emit("item/agentMessage/delta", ["itemId": messageID, "delta": content])
            } else {
                text = content
                emit("item/completed", ["item": ["id": messageID, "type": "agentMessage", "text": text, "phase": "commentary"]])
            }
        case "tool_use":
            finishMessage(final: false)
            let id = event["tool_id"] as? String ?? UUID().uuidString
            let item: [String: Any] = ["id": id, "type": "dynamicToolCall", "tool": event["tool_name"] ?? "Gemini tool",
                                       "arguments": event["parameters"] ?? [:], "status": "inProgress"]
            tools[id] = item; emit("item/started", ["item": item])
        case "tool_result":
            let id = event["tool_id"] as? String ?? ""
            var item = tools.removeValue(forKey: id) ?? ["id": id, "type": "dynamicToolCall"]
            item["status"] = event["status"] as? String == "success" ? "completed" : "failed"
            item["output"] = event["output"]; item["error"] = event["error"]
            emit("item/completed", ["item": item])
        case "error":
            let message = event["message"] as? String ?? "Gemini reported an error."
            if event["severity"] as? String == "warning" { emit("runtime/stderr", ["text": message]) }
            else { failure = message }
        case "result": result = event
        default: break
        }
    }

    private func finishMessage(final: Bool) {
        guard !text.isEmpty else { return }
        emit("item/completed", ["item": ["id": messageID, "type": "agentMessage", "text": text,
                                           "phase": final ? "final_answer" : "commentary"]])
        text = ""; messageID = UUID().uuidString
    }

    private func exited(status: Int32, stderr: String, generation token: UUID) {
        guard generation == token else { return }
        if !buffer.isEmpty, let event = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] { receive(event) }
        buffer.removeAll()
        process = nil; generation = nil
        let success = status == 0 && result?["status"] as? String == "success" && failure == nil && !interrupted
        finishMessage(final: success)
        var turn: [String: Any] = ["id": turnID ?? "", "status": interrupted ? "interrupted" : success ? "completed" : "failed"]
        if !success && !interrupted {
            let resultError = result?["error"] as? [String: Any]
            let detail = failure ?? resultError?["message"] as? String ?? (stderr.isEmpty ? "Gemini exited without a successful result (status \(status))." : stderr)
            turn["error"] = ["message": detail + "\nIf sign-in is required, run ‘gemini’ in Terminal, then retry. Your model must be available to that account."]
        }
        turnID = nil
        emit("turn/completed", ["turn": turn])
    }

    func interrupt() {
        interrupted = true
        terminateProcess()
    }
    func stop() {
        terminateProcess()
        generation = nil; process = nil; turnID = nil
    }
    private func terminateProcess() {
        guard let task = process, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }
    private func emit(_ method: String, _ params: [String: Any]) {
        onEvent?(["method": method, "params": params, "_provider": "gemini"])
    }
}
