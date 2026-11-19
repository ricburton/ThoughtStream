import AppKit

/// What a local model can do on this Mac. Each tool reports into the feed with
/// the same events Codex and Claude use, so commands, file changes and results
/// look the same whichever model ran them.
@MainActor
final class LocalToolbox {
    let project: URL
    /// Emits a provider-neutral event (item/started, item/completed, output deltas).
    var emit: (String, [String: Any]) -> Void = { _, _ in }
    /// Asks the user before an action. Not consulted under full access.
    var approve: (LocalToolCall, String) async -> Bool = { _, _ in false }
    var accessMode: () -> AccessMode = { AccessMode.selected }
    private var running: [Process] = []

    init(project: URL) { self.project = project }

    nonisolated static let resultLimit = 24_000

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any]] as [String: Any]]
    }
    private static func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static let schemas: [[String: Any]] = [
        tool("run_command", "Run a shell command on this Mac with zsh and return its output and exit code. Use it to inspect or change anything a Terminal command can: files, git, processes, system settings, installed tools.",
             ["command": text("The command line to run."),
              "timeout_seconds": ["type": "integer", "description": "Stop the command after this many seconds. Default 120."]],
             required: ["command"]),
        tool("read_file", "Read a text file. Returns numbered lines.",
             ["path": text("File path, absolute or relative to the working folder."),
              "start_line": ["type": "integer", "description": "First line to read, starting at 1."],
              "max_lines": ["type": "integer", "description": "How many lines to read. Default 400."]],
             required: ["path"]),
        tool("write_file", "Create a file or replace its whole content.",
             ["path": text("File path, absolute or relative to the working folder."), "content": text("The complete new content.")],
             required: ["path", "content"]),
        tool("edit_file", "Replace an exact piece of text in a file. The old text must appear exactly once unless replace_all is true.",
             ["path": text("File path, absolute or relative to the working folder."),
              "old_text": text("The exact text to replace, including whitespace."), "new_text": text("The replacement text."),
              "replace_all": ["type": "boolean", "description": "Replace every occurrence."]],
             required: ["path", "old_text", "new_text"]),
        tool("list_directory", "List the files and folders in a folder.",
             ["path": text("Folder path. Defaults to the working folder.")], required: []),
        tool("open_item", "Open a file, folder, web link or app on this Mac, the way double-clicking it would.",
             ["target": text("A path, a URL such as https://example.com, or an app name such as Safari.")], required: ["target"]),
        tool("run_applescript", "Run AppleScript to control Mac apps and the system: Finder, Safari, Mail, Music, Calendar, Reminders, notifications, volume, windows. Returns the script's result.",
             ["script": text("The AppleScript source.")], required: ["script"])
    ]

    func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return project.appendingPathComponent(expanded).standardizedFileURL
    }

    func isInsideProject(_ url: URL) -> Bool {
        let root = project.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Workspace access reads inside the project freely and asks before
    /// anything else. Full access never asks.
    func needsApproval(_ call: LocalToolCall) -> Bool {
        guard accessMode() != .fullAccess else { return false }
        switch call.name {
        case "read_file": return !isInsideProject(resolve(call.arguments["path"] as? String ?? ""))
        case "list_directory": return !isInsideProject(resolve(call.arguments["path"] as? String ?? "."))
        default: return true
        }
    }

    /// A one-line description of what is about to happen, for the approval prompt.
    func summary(_ call: LocalToolCall) -> String {
        let arguments = call.arguments
        switch call.name {
        case "run_command": return "Run: " + (arguments["command"] as? String ?? "")
        case "read_file": return "Read " + resolve(arguments["path"] as? String ?? "").path
        case "write_file": return "Write " + resolve(arguments["path"] as? String ?? "").path
        case "edit_file": return "Edit " + resolve(arguments["path"] as? String ?? "").path
        case "list_directory": return "List " + resolve(arguments["path"] as? String ?? ".").path
        case "open_item": return "Open " + (arguments["target"] as? String ?? "")
        case "run_applescript": return "Run AppleScript:\n" + (arguments["script"] as? String ?? "")
        default: return call.name
        }
    }

    nonisolated static func clip(_ text: String, limit: Int = resultLimit) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3), tail = text.suffix(limit / 3)
        return head + "\n… [\(text.count - limit) characters omitted] …\n" + tail
    }

    /// Runs one tool call and returns the text handed back to the model.
    func run(_ call: LocalToolCall) async -> String {
        guard Self.schemas.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == call.name }) else {
            return "Unknown tool \(call.name). Available tools: run_command, read_file, write_file, edit_file, list_directory, open_item, run_applescript."
        }
        if needsApproval(call), await !approve(call, summary(call)) {
            let item: [String: Any] = ["id": call.id, "type": "dynamicToolCall", "tool": call.name, "arguments": call.arguments,
                                       "result": "Declined by the user.", "isError": true]
            emit("item/completed", ["item": item])
            return "The user declined this action. Do not retry it; ask what they would like instead."
        }
        if Task.isCancelled { return "Interrupted." }
        switch call.name {
        case "run_command": return await runCommand(call)
        case "run_applescript": return await runAppleScript(call)
        case "write_file", "edit_file": return changeFile(call)
        default: return inspect(call)
        }
    }

    func stop() {
        for process in running { Self.terminate(process) }
        running.removeAll()
    }

    /// Stop a command and what it started. The shell alone would leave its
    /// children running after a timeout or an interruption.
    nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        children.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        children.standardOutput = FileHandle.nullDevice; children.standardError = FileHandle.nullDevice
        try? children.run()
        process.terminate()
    }

    // MARK: Commands

    private func runCommand(_ call: LocalToolCall) async -> String {
        guard let command = call.arguments["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: run_command needs a command."
        }
        let timeout = min(900, max(1, (call.arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 120))
        emit("item/started", ["item": ["id": call.id, "type": "commandExecution", "command": command, "cwd": project.path]])
        let result = await execute(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command], timeout: timeout) { [weak self] fragment in
            self?.emit("item/commandExecution/outputDelta", ["itemId": call.id, "delta": fragment])
        }
        var item: [String: Any] = ["id": call.id, "type": "commandExecution", "command": command, "cwd": project.path,
                                   "status": result.interrupted ? "interrupted" : result.exitCode == 0 ? "succeeded" : "failed",
                                   "durationMs": result.durationMs, "aggregatedOutput": result.output]
        if !result.interrupted { item["exitCode"] = Int(result.exitCode) }
        emit("item/completed", ["item": item])
        let output = result.output.trimmingCharacters(in: .newlines)
        var text = Self.clip(output.isEmpty ? "(no output)" : output)
        if result.timedOut { text += "\n[Stopped after \(Int(timeout)) seconds.]" }
        else if result.interrupted { text += "\n[Interrupted.]" }
        return text + "\n[exit code \(result.exitCode)]"
    }

    private func runAppleScript(_ call: LocalToolCall) async -> String {
        guard let script = call.arguments["script"] as? String, !script.isEmpty else { return "Error: run_applescript needs a script." }
        let started: [String: Any] = ["id": call.id, "type": "dynamicToolCall", "tool": call.name, "arguments": call.arguments]
        emit("item/started", ["item": started])
        let result = await execute(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], timeout: 120) { _ in }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var finished = started
        finished["result"] = text.isEmpty ? "Done." : text
        finished["isError"] = result.exitCode != 0
        emit("item/completed", ["item": finished])
        if result.exitCode != 0 { return "AppleScript failed: " + Self.clip(text.isEmpty ? "exit code \(result.exitCode)" : text) }
        return text.isEmpty ? "Done." : Self.clip(text)
    }

    struct Execution {
        var output = ""
        var exitCode: Int32 = -1
        var durationMs = 0
        var timedOut = false
        var interrupted = false
    }

    /// Runs a process in the project folder, streaming its combined output.
    func execute(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                 onOutput: @escaping @MainActor (String) -> Void) async -> Execution {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: project.path) ? project : FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "CLAUDECODE"] { environment.removeValue(forKey: key) }
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let collector = OutputCollector()
        let began = Date()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let fragment = collector.append(data)
            if !fragment.isEmpty { Task { @MainActor in onOutput(fragment) } }
        }
        var result = Execution()
        let finished: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                process.terminationHandler = { _ in continuation.resume(returning: true) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    _ = collector.append(Data("Could not start: \(error.localizedDescription)".utf8))
                    continuation.resume(returning: false)
                    return
                }
                running.append(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    collector.markTimedOut()
                    Self.terminate(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                }
            }
        } onCancel: {
            Self.terminate(process)
        }
        // Let the last output arrive, but never block on the pipe: a command
        // may leave a background child holding it open indefinitely.
        var settled = collector.count
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if collector.count == settled { break }
            settled = collector.count
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Fragments already queued for the main actor are delivered before the result.
        try? await Task.sleep(nanoseconds: 20_000_000)
        running.removeAll { $0 === process }
        result.output = collector.text
        result.timedOut = collector.timedOut
        result.interrupted = Task.isCancelled && !collector.timedOut
        result.exitCode = finished ? process.terminationStatus : -1
        result.durationMs = Int(Date().timeIntervalSince(began) * 1000)
        return result
    }

    // MARK: Files

    private func inspect(_ call: LocalToolCall) -> String {
        let started: [String: Any] = ["id": call.id, "type": "dynamicToolCall", "tool": call.name, "arguments": call.arguments]
        emit("item/started", ["item": started])
        let outcome: Result<String, Error>
        do {
            switch call.name {
            case "read_file": outcome = .success(try readFile(call.arguments))
            case "list_directory": outcome = .success(try listDirectory(call.arguments))
            default: outcome = .success(try openItem(call.arguments))
            }
        } catch { outcome = .failure(error) }
        var finished = started
        let text: String
        switch outcome {
        case .success(let value): text = value; finished["isError"] = false
        case .failure(let error): text = "Error: " + error.localizedDescription; finished["isError"] = true
        }
        finished["result"] = text
        emit("item/completed", ["item": finished])
        return text
    }

    private func readFile(_ arguments: [String: Any]) throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else { throw LocalModelClient.error("read_file needs a path.") }
        let url = resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw LocalModelClient.error("\(url.path) does not exist.") }
        guard !isDirectory.boolValue else { throw LocalModelClient.error("\(url.path) is a folder. Use list_directory.") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 4_000_000 else { throw LocalModelClient.error("\(url.lastPathComponent) is \(size / 1_000_000) MB, too large to read whole. Use run_command with head, tail or grep.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), !data.prefix(4_096).contains(0) else {
            throw LocalModelClient.error("\(url.lastPathComponent) is not a text file.")
        }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, (arguments["start_line"] as? NSNumber)?.intValue ?? 1)
        let count = min(2_000, max(1, (arguments["max_lines"] as? NSNumber)?.intValue ?? 400))
        guard start <= lines.count else { return "(\(url.lastPathComponent) has \(lines.count) lines.)" }
        let end = min(lines.count, start + count - 1)
        var body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        if end < lines.count { body += "\n… [\(lines.count - end) more lines; read again with start_line \(end + 1)]" }
        return Self.clip(body)
    }

    private func listDirectory(_ arguments: [String: Any]) throws -> String {
        let url = resolve(arguments["path"] as? String ?? ".")
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        let names = entries.map { entry -> String in
            let directory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return entry.lastPathComponent + (directory ? "/" : "")
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return "\(url.path) is empty." }
        let shown = names.prefix(500)
        return url.path + "\n" + shown.joined(separator: "\n") + (names.count > shown.count ? "\n… [\(names.count - shown.count) more]" : "")
    }

    private func openItem(_ arguments: [String: Any]) throws -> String {
        guard let target = (arguments["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            throw LocalModelClient.error("open_item needs a target.")
        }
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, !target.hasPrefix("/") {
            guard NSWorkspace.shared.open(url) else { throw LocalModelClient.error("Nothing on this Mac can open \(target).") }
            return "Opened \(target)."
        }
        let file = resolve(target)
        if FileManager.default.fileExists(atPath: file.path) {
            guard NSWorkspace.shared.open(file) else { throw LocalModelClient.error("Could not open \(file.path).") }
            return "Opened \(file.path)."
        }
        let name = target.hasSuffix(".app") ? String(target.dropLast(4)) : target
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"]
        guard let app = folders.map({ URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw LocalModelClient.error("No file, link or app named \(target) was found.")
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        return "Opened \(name)."
    }

    private func changeFile(_ call: LocalToolCall) -> String {
        let arguments = call.arguments
        guard let path = arguments["path"] as? String, !path.isEmpty else { return "Error: \(call.name) needs a path." }
        let url = resolve(path)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let updated: String
        if call.name == "write_file" {
            guard let content = arguments["content"] as? String else { return "Error: write_file needs content." }
            updated = content
        } else {
            guard let existing else { return "Error: \(url.path) does not exist or is not text. Use write_file to create it." }
            guard let old = arguments["old_text"] as? String, !old.isEmpty, let new = arguments["new_text"] as? String else {
                return "Error: edit_file needs old_text and new_text."
            }
            let occurrences = existing.components(separatedBy: old).count - 1
            guard occurrences > 0 else { return "Error: old_text was not found in \(url.lastPathComponent). Read the file and copy the exact text." }
            let all = arguments["replace_all"] as? Bool ?? false
            guard occurrences == 1 || all else {
                return "Error: old_text appears \(occurrences) times in \(url.lastPathComponent). Include more surrounding text, or set replace_all."
            }
            updated = existing.replacingOccurrences(of: old, with: new)
        }
        guard updated != existing else { return "\(url.lastPathComponent) already has that content." }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let item: [String: Any] = ["id": call.id, "type": "dynamicToolCall", "tool": call.name, "arguments": ["path": url.path],
                                       "result": "Error: " + error.localizedDescription, "isError": true]
            emit("item/completed", ["item": item])
            return "Error: " + error.localizedDescription
        }
        let diff = Self.diff(old: existing ?? "", new: updated, path: url.path, isNew: existing == nil)
        emit("item/completed", ["item": ["id": call.id, "type": "fileChange", "changes": [["path": url.path, "diff": diff]]]])
        return existing == nil ? "Created \(url.path) (\(updated.components(separatedBy: "\n").count) lines)." : "Updated \(url.path)."
    }

    /// A unified diff with three lines of context, for the feed.
    static func diff(old: String, new: String, path: String, isNew: Bool) -> String {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n"), after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard before.count + after.count <= 20_000 else {
            return "--- \(isNew ? "/dev/null" : path)\n+++ \(path)\n(\(before.count) lines before, \(after.count) after; too large for an inline diff)"
        }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both versions together into one annotated line list.
        var rows: [(mark: Character, text: String, old: Int, new: Int)] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) { rows.append(("-", before[i], i, j)); i += 1 }
            else if j < after.count, inserted.contains(j) { rows.append(("+", after[j], i, j)); j += 1 }
            else if i < before.count, j < after.count { rows.append((" ", before[i], i, j)); i += 1; j += 1 }
            else { break }
        }
        var output = ["--- " + (isNew ? "/dev/null" : path), "+++ " + path]
        let changed = rows.indices.filter { rows[$0].mark != " " }
        guard !changed.isEmpty else { return output.joined(separator: "\n") }
        var hunks: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - 3)...min(rows.count - 1, index + 3)
            if let last = hunks.last, range.lowerBound <= last.upperBound + 1 { hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound) }
            else { hunks.append(range) }
        }
        for hunk in hunks {
            let slice = rows[hunk]
            let oldCount = slice.filter { $0.mark != "+" }.count, newCount = slice.filter { $0.mark != "-" }.count
            let oldStart = oldCount == 0 ? slice.first!.old : slice.first!.old + 1
            let newStart = newCount == 0 ? slice.first!.new : slice.first!.new + 1
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output += slice.map { String($0.mark) + $0.text }
        }
        return output.joined(separator: "\n")
    }
}

/// Collects process output off the main thread, holding back a split UTF-8 character.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var decoded = 0
    private var didTimeOut = false
    private static let limit = 2_000_000

    /// Appends bytes and returns the newly complete text.
    func append(_ bytes: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        guard data.count < Self.limit else { return "" }
        data.append(bytes.prefix(Self.limit - data.count))
        // Back off up to three bytes so a multi-byte character is never cut.
        for trim in 0...3 where data.count - trim >= decoded {
            if let text = String(data: data[decoded..<(data.count - trim)], encoding: .utf8) {
                decoded = data.count - trim
                return text
            }
        }
        return ""
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return data.count }
    func markTimedOut() { lock.lock(); didTimeOut = true; lock.unlock() }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
