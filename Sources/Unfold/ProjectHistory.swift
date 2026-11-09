import Foundation

struct ProjectConversation {
    let id: String
    let title: String
    var updatedAt: Date? = nil
}

/// Reads local history without resuming threads or starting model work.
@MainActor
final class ProjectHistory {
    typealias Request = (String, [String: Any]) async throws -> [String: Any]
    private var request: Request!
    private var connection: CodexConnection?
    private var startup: Task<Void, Error>?

    init(request: @escaping Request) { self.request = request }

    init(executable: URL) {
        request = { [weak self] method, params in
            guard let self else { throw CancellationError() }
            return try await self.runtimeRequest(method, params, executable: executable)
        }
    }

    private func runtimeRequest(_ method: String, _ params: [String: Any], executable: URL) async throws -> [String: Any] {
        if connection == nil {
            let runtime = CodexConnection()
            connection = runtime
            startup = Task { try await runtime.start(executable: executable) }
        }
        guard let runtime = connection, let startup else { throw CancellationError() }
        do {
            try await startup.value
            return try await runtime.request(method, params)
        } catch {
            // A failed start or disconnected reader must not poison every
            // subsequent history lookup for the lifetime of the workspace.
            if connection === runtime { stop() }
            throw error
        }
    }

    func stop() {
        startup?.cancel(); connection?.stop()
        startup = nil; connection = nil
    }

    func conversations(in project: URL) async throws -> [ProjectConversation] {
        let paths = Array(Set([project.standardizedFileURL.path, project.resolvingSymlinksInPath().path])).sorted()
        var rows: [[String: Any]] = []
        for archived in [false, true] {
            rows += try await pages("thread/list", ["cwd": paths, "limit": 100, "sortKey": "updated_at", "modelProviders": [], "archived": archived])
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let cwd = row["cwd"] as? String,
                  paths.contains(URL(fileURLWithPath: cwd).standardizedFileURL.path),
                  row["parentThreadId"] as? String == nil,
                  !(row["source"] as? String ?? "").hasPrefix("subAgent"),
                  seen.insert(id).inserted else { return nil }
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (row["preview"] as? String ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let updatedAt = (row["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return ProjectConversation(id: id, title: name.isEmpty ? (preview.isEmpty ? "Previous chat" : String(preview.prefix(100))) : name,
                                       updatedAt: updatedAt)
        }
    }

    func transcript(_ id: String) async throws -> [StreamRecord] {
        let response = try await request("thread/read", ["threadId": id, "includeTurns": false])
        guard let thread = response["thread"] as? [String: Any] else { throw CodexConnection.error("The conversation could not be read.") }
        let turns: [[String: Any]]
        if thread["historyMode"] as? String == "paginated" {
            turns = try await pages("thread/turns/list", ["threadId": id, "itemsView": "full", "sortDirection": "asc", "limit": 100])
        } else {
            let full = try await request("thread/read", ["threadId": id, "includeTurns": true])
            guard let value = (full["thread"] as? [String: Any])?["turns"] as? [[String: Any]] else {
                throw CodexConnection.error("The conversation history is unavailable.")
            }
            turns = value
        }
        return Self.records(turns: turns, createdAt: (thread["createdAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    private func pages(_ method: String, _ parameters: [String: Any]) async throws -> [[String: Any]] {
        var params = parameters, result: [[String: Any]] = [], cursors = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await request(method, params)
            guard let rows = page["data"] as? [[String: Any]] else { throw CodexConnection.error("Conversation history returned an invalid page.") }
            result.append(contentsOf: rows)
            guard let cursor = page["nextCursor"] as? String, !cursor.isEmpty else { return result }
            guard cursors.insert(cursor).inserted else { throw CodexConnection.error("Conversation history repeated a page.") }
            params["cursor"] = cursor
        }
    }

    static func records(turns: [[String: Any]], createdAt: Double) -> [StreamRecord] {
        var records: [StreamRecord] = []
        for turn in turns {
            let date = Date(timeIntervalSince1970: (turn["startedAt"] as? NSNumber)?.doubleValue ?? createdAt)
            for item in turn["items"] as? [[String: Any]] ?? [] {
                let id = item["id"] as? String
                func append(_ kind: StreamKind, _ text: String, language: String? = nil, command: CommandActivity? = nil) {
                    guard !text.isEmpty else { return }
                    records.append(StreamRecord(kind: kind.rawValue, text: text, language: language, time: date, itemID: id, command: command))
                }
                switch item["type"] as? String {
                case "userMessage":
                    for content in item["content"] as? [[String: Any]] ?? [] {
                        if content["type"] as? String == "text" { append(.user, content["text"] as? String ?? "") }
                        else { append(.user, Session.pretty(content)) }
                    }
                case "agentMessage":
                    append(.prose, item["text"] as? String ?? "")
                    if item["phase"] as? String == "final_answer", records.last?.itemID == id, !records.isEmpty {
                        records[records.count - 1].isFinalResponse = true
                    }
                case "plan": append(.prose, item["text"] as? String ?? "")
                case "reasoning": append(.reasoning, (item["summary"] as? [String] ?? []).joined(separator: "\n\n"))
                case "commandExecution":
                    let exit = item["exitCode"] as? Int
                    let status = item["status"] as? String ?? ""
                    let state: CommandActivity.State = status == "completed" ? (exit == nil ? .unknown : exit == 0 ? .succeeded : .failed) : status == "failed" || status == "declined" ? .failed : .unknown
                    append(.command, (item["cwd"] as? String ?? "") + "\n$ " + (item["command"] as? String ?? ""), language: "bash",
                           command: CommandActivity(state: state, startedAt: date, durationMs: item["durationMs"] as? Int, exitCode: exit))
                    append(.output, item["aggregatedOutput"] as? String ?? "")
                case "fileChange":
                    for change in item["changes"] as? [[String: Any]] ?? [] {
                        append(.change, (change["path"] as? String ?? "") + "\n" + (change["diff"] as? String ?? ""), language: "diff")
                    }
                case "contextCompaction": append(.compaction, "Earlier context was compacted.")
                default: append(.tool, Session.pretty(Session.redact(item)))
                }
            }
            if let error = (turn["error"] as? [String: Any])?["message"] as? String {
                records.append(StreamRecord(kind: StreamKind.error.rawValue, text: error, time: date))
            }
        }
        var ordered = FeedBuffer()
        for record in records { ordered.append(record, merging: false) }
        return ordered.records
    }
}
