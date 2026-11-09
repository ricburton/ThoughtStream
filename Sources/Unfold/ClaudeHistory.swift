import Foundation

/// Reads Claude's local transcripts without starting or resuming model work.
enum ClaudeHistory {
    struct Conversation: Sendable {
        let id: String
        let title: String
        let updated: Date
    }
    static var base: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("projects", isDirectory: true)
    }
    static func directory(_ project: URL, root: URL = base) -> URL {
        let slug = project.path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return root.appendingPathComponent(slug, isDirectory: true)
    }
    private static func belongs(_ event: [String: Any], to project: URL) -> Bool {
        guard event["isSidechain"] as? Bool != true, let cwd = event["cwd"] as? String else { return false }
        return URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath() == project.standardizedFileURL.resolvingSymlinksInPath()
    }
    static func conversations(in project: URL, root: URL = base) -> [Conversation] {
        let directories = Set([directory(project, root: root), directory(project.resolvingSymlinksInPath(), root: root)])
        var found: [String: Conversation] = [:]
        for directory in directories {
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.pathExtension == "jsonl" {
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let prefix = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
                try? handle.close()
                let rows = prefix.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
                guard let first = rows.first(where: { belongs($0, to: project) && $0["type"] as? String == "user" }),
                      let message = first["message"] as? [String: Any] else { continue }
                let text = message["content"] as? String ?? (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                guard !text.isEmpty else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                found[id] = Conversation(id: id, title: String(text.prefix(100)), updated: updated)
            }
        }
        return found.values.sorted { $0.updated > $1.updated }
    }
    static func transcript(_ id: String, project: URL, root: URL = base) throws -> [StreamRecord] {
        guard UUID(uuidString: id) != nil else { throw NSError(domain: "ThoughtStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Claude session ID."]) }
        let candidates = [directory(project, root: root), directory(project.resolvingSymlinksInPath(), root: root)].map { $0.appendingPathComponent(id + ".jsonl") }
        guard let url = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw NSError(domain: "ThoughtStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude's local conversation is no longer available."])
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let dateParser = ISO8601DateFormatter(); dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDateParser = ISO8601DateFormatter()
        var records = FeedBuffer(), seen = Set<String>()
        for line in data.split(separator: 10) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], belongs(row, to: project),
                  let message = row["message"] as? [String: Any], let role = row["type"] as? String else { continue }
            let date = (row["timestamp"] as? String).flatMap { dateParser.date(from: $0) ?? plainDateParser.date(from: $0) } ?? .distantPast
            let id = row["uuid"] as? String ?? UUID().uuidString
            guard seen.insert(id).inserted else { continue }
            func append(_ kind: StreamKind, _ text: String, suffix: String = "", itemID: String? = nil, command: CommandActivity? = nil) {
                guard !text.isEmpty else { return }
                records.append(StreamRecord(kind: kind.rawValue, text: text, time: date, itemID: itemID ?? (id + suffix), command: command), merging: false)
            }
            if let text = message["content"] as? String { append(role == "user" ? .user : .prose, text); continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                append(.prose, blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n"), itemID: message["id"] as? String)
            }
            for (index, block) in blocks.enumerated() {
                let suffix = ":\(index)"
                switch block["type"] as? String {
                case "text": if role == "user" { append(.user, block["text"] as? String ?? "", suffix: suffix) }
                case "tool_use":
                    let input = block["input"] as? [String: Any] ?? [:]
                    if block["name"] as? String == "Bash" {
                        append(.command, "\n$ " + (input["command"] as? String ?? "Command"), suffix: suffix, itemID: block["id"] as? String, command: CommandActivity(state: .unknown, startedAt: date))
                    } else if let data = try? JSONSerialization.data(withJSONObject: block, options: [.prettyPrinted, .sortedKeys]) {
                        append(.tool, String(decoding: data, as: UTF8.self), suffix: suffix)
                    }
                case "tool_result":
                    let content = block["content"] as? String ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    append(.output, content, suffix: suffix, itemID: block["tool_use_id"] as? String)
                    if let toolID = block["tool_use_id"] as? String,
                       let previous = records.records.last(where: { $0.itemID == toolID && $0.command != nil }),
                       var activity = previous.command {
                        activity.state = block["is_error"] as? Bool == true ? .failed : .succeeded
                        activity.finishedAt = date
                        records.updateCommand(activity, itemID: toolID)
                    }
                default: break // Thinking and opaque internal blocks are not conversation text.
                }
            }
        }
        return records.records
    }
}
