import Foundation
import SQLite3

/// A disk-backed, local-only index. The actor never runs on the UI executor.
actor LocalHistorySearch {
    struct Roots: Sendable {
        var sessions: URL
        var codex: URL
        var claude: URL
        var database: URL
        static var standard: Roots {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Roots(sessions: support.appendingPathComponent("UnfoldNative/Sessions"),
                         codex: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"),
                         claude: ClaudeHistory.base,
                         database: support.appendingPathComponent("UnfoldNative/Search/history-v1.sqlite"))
        }
    }
    struct Document: Codable, Sendable {
        var source: String
        var sessionID: String?
        var thread: String?
        var provider: String
        var project: String
        var title: String
        var updated: Date
        var records: [StreamRecord]
    }
    struct Result: Sendable {
        var document: Document
        var record: Int
        var text: String
        var needle: String
        var approximate: Bool
        var snippet: String { Self.snippet(text, around: needle) }
        static func snippet(_ text: String, around needle: String) -> String {
            let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) ?? text.startIndex..<text.startIndex
            let start = text.index(range.lowerBound, offsetBy: -75, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (start > text.startIndex ? "…" : "") + excerpt + (end < text.endIndex ? "…" : "")
        }
    }
    private let roots: Roots
    private var db: OpaquePointer?
    private var refreshing = false
    init(roots: Roots = .standard) { self.roots = roots }
    deinit { sqlite3_close(db) }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: roots.database.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(roots.database.path, &db) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try execute("CREATE TABLE IF NOT EXISTS sources(path TEXT PRIMARY KEY, stamp TEXT, metadata TEXT);")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(source UNINDEXED, position UNINDEXED, text, tokenize='trigram');")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(source UNINDEXED, position UNINDEXED, text, tokenize='unicode61', prefix='2 3');")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS vocabulary USING fts5vocab(words, 'row');")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: roots.database.path)
    }
    private func failure() -> Error {
        NSError(domain: "ThoughtStream.Search", code: 1, userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Local search is unavailable."])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            if step == SQLITE_INTERRUPT { throw CancellationError() }
            guard step == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
    /// File parsing yields to searches; unchanged files are never parsed twice.
    func refresh() async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        try open()
        let roots = roots
        let files = await Task.detached(priority: .utility) { Self.files(roots) }.value
        let names = await Task.detached(priority: .utility) { Self.codexNames(roots.codex) }.value
        var seen = Set<String>()
        for (url, format) in files {
            try Task.checkCancellation()
            let path = url.path
            seen.insert(path)
            let existing = try rows("SELECT stamp,metadata FROM sources WHERE path=?", [path]).first
            let prior = existing.flatMap { try? JSONDecoder().decode(Document.self, from: Data($0[1].utf8)) }
            let fileStamp = Self.stamp(url, format: format)
            let stamp = fileStamp + (prior?.thread.flatMap { names[$0]?.title } ?? "")
            if existing?.first == stamp { continue }
            let document = await Task.detached(priority: .utility) { Self.read(url, format: format, names: names) }.value
            try Task.checkCancellation()
            guard let document else { try remove(path); continue }
            try store(document, stamp: fileStamp + (document.thread.flatMap { names[$0]?.title } ?? ""))
            await Task.yield()
        }
        for row in try rows("SELECT path FROM sources") where !seen.contains(row[0]) { try remove(row[0]) }
    }
    private func remove(_ path: String) throws {
        _ = try rows("DELETE FROM messages WHERE source=?", [path])
        _ = try rows("DELETE FROM words WHERE source=?", [path])
        _ = try rows("DELETE FROM sources WHERE path=?", [path])
    }
    private func store(_ document: Document, stamp: String) throws {
        var metadata = document; metadata.records = []
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            try remove(document.source)
            _ = try rows("INSERT INTO sources VALUES(?,?,?)", [document.source, stamp, json])
            for (index, record) in document.records.enumerated() where !record.text.isEmpty {
                _ = try rows("INSERT INTO messages(source,position,text) VALUES(?,?,?)", [document.source, String(index), record.text])
                _ = try rows("INSERT INTO words(source,position,text) VALUES(?,?,?)", [document.source, String(index), record.text])
            }
            // A chat's title and project are also searchable, opening its first message.
            let heading = document.title + " · " + document.project
            _ = try rows("INSERT INTO messages(source,position,text) VALUES(?,?,?)", [document.source, "-1", heading])
            _ = try rows("INSERT INTO words(source,position,text) VALUES(?,?,?)", [document.source, "-1", heading])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func search(_ query: String, limit: Int = 80) throws -> [Result] {
        try open()
        try Task.checkCancellation()
        sqlite3_progress_handler(db, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let quoted = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let exact: [[String]]
        let sql = "SELECT source,position,text FROM messages WHERE messages MATCH ? LIMIT 800"
        if query.count >= 3 { exact = try rows(sql, [quoted]) }
        else { exact = try rows("SELECT source,position,text FROM messages WHERE instr(lower(text),lower(?))>0 LIMIT 800", [query]) }
        var candidates: [([String], String, Bool)] = exact.map { ($0, query, false) }
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Exact substrings rank first; token prefixes and a single typo are a small fallback.
        if candidates.count < limit, !tokens.isEmpty, tokens.count <= 8 {
            var alternatives: [[String]] = []
            for token in tokens {
                var variants = [token]
                if token.count >= 4 {
                    let first = String(token.prefix(1))
                    let terms = try rows("SELECT term FROM vocabulary WHERE length(term) BETWEEN CAST(? AS INTEGER) AND CAST(? AS INTEGER) AND term>=? AND term<? LIMIT 6000", [String(token.count - 1), String(token.count + 1), first, first + "\u{10ffff}"])
                    variants += terms.map { $0[0] }.filter { Self.oneEditApart(token, $0) }.prefix(12)
                }
                alternatives.append(variants)
            }
            let expression = alternatives.map { variants in "(" + variants.map { "\"" + $0 + "\"*" }.joined(separator: " OR ") + ")" }.joined(separator: " AND ")
            for row in try rows("SELECT source,position,text FROM words WHERE words MATCH ? ORDER BY rank LIMIT 300", [expression]) {
                let words = row[2].split { !$0.isLetter && !$0.isNumber }.map(String.init)
                let needle = words.first { word in alternatives.flatMap { $0 }.contains { word.lowercased().hasPrefix($0) } } ?? tokens[0]
                candidates.append((row, needle, true))
            }
        }
        var metadata: [String: Document] = [:], results: [Result] = [], unique = Set<String>()
        for (row, needle, approximate) in candidates {
            try Task.checkCancellation()
            if metadata[row[0]] == nil, let raw = try rows("SELECT metadata FROM sources WHERE path=?", [row[0]]).first?.first {
                metadata[row[0]] = try? JSONDecoder().decode(Document.self, from: Data(raw.utf8))
            }
            guard let document = metadata[row[0]], let position = Int(row[1]) else { continue }
            let identity = document.provider + ":" + (document.thread ?? document.sessionID ?? document.source) + ":" + row[2]
            guard unique.insert(identity).inserted else { continue }
            results.append(Result(document: document, record: max(0, position), text: row[2], needle: needle, approximate: approximate))
        }
        return Array(results.sorted {
            if $0.approximate != $1.approximate { return !$0.approximate }
            if $0.document.updated != $1.document.updated { return $0.document.updated > $1.document.updated }
            return $0.record < $1.record
        }.prefix(limit))
    }
    func load(_ result: Result) async -> Document? {
        let url = URL(fileURLWithPath: result.document.source)
        let format: Format = result.document.sessionID != nil ? .thoughtStream : result.document.provider == "claude" ? .claude : .codex
        return await Task.detached(priority: .userInitiated) { Self.read(url, format: format, names: [:]) }.value
    }
    static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let changes = a.indices.filter { a[$0] != b[$0] }
            if changes.count <= 1 { return true }
            return changes.count == 2 && changes[1] == changes[0] + 1 && a[changes[0]] == b[changes[1]] && a[changes[1]] == b[changes[0]]
        }
        let short = a.count < b.count ? a : b, long = a.count < b.count ? b : a
        var i = 0, j = 0
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1 } else { j += 1; if j - i > 1 { return false } }
        }
        return true
    }
}

extension LocalHistorySearch {
    enum Format: Sendable { case thoughtStream, codex, claude }
    static func files(_ roots: Roots) -> [(URL, Format)] {
        let manager = FileManager.default
        var result = ((try? manager.contentsOfDirectory(at: roots.sessions, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }.map { ($0, Format.thoughtStream) }
        for (root, format) in [(roots.codex.appendingPathComponent("sessions"), Format.codex), (roots.codex.appendingPathComponent("archived_sessions"), .codex), (roots.claude, .claude)] {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if format == .claude && url.pathComponents.contains("subagents") { continue }
                result.append((url, format))
            }
        }
        return result
    }
    static func stamp(_ url: URL, format: Format) -> String {
        let urls = format == .thoughtStream ? ["history-v1.json", "history-v1.backup.json", "history-journal.jsonl", "session.json", "feed.json"].map { url.appendingPathComponent($0) } : [url]
        return urls.map { file in
            let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(attributes?.fileSize ?? 0)"
        }.joined(separator: ";")
    }
    struct Name: Sendable { var title: String; var updated: Date? }
    static func codexNames(_ root: URL) -> [String: Name] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var result: [String: Name] = [:]
        for line in data.split(separator: 10) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let id = row["id"] as? String, let title = row["thread_name"] as? String else { continue }
            result[id] = Name(title: title, updated: date(row["updated_at"]))
        }
        return result
    }
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func read(_ url: URL, format: Format, names: [String: Name]) -> Document? {
        if format == .thoughtStream {
            guard let data = ConversationStore.snapshot(in: url)?.metadata ?? (try? Data(contentsOf: url.appendingPathComponent("session.json"))),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let project = meta["project"] as? String else { return nil }
            let records = ConversationStore(folder: url).load()
            return Document(source: url.path, sessionID: meta["id"] as? String, thread: meta["thread"] as? String, provider: meta["provider"] as? String ?? "codex", project: project, title: meta["title"] as? String ?? "Previous chat", updated: records.last?.time ?? .distantPast, records: records)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var thread = url.deletingPathExtension().lastPathComponent, project: String?, title: String?, records: [StreamRecord] = [], seen = Set<String>()
        var updated = Date.distantPast
        let dateParser = ISO8601DateFormatter(); dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let secondsParser = ISO8601DateFormatter()
        func timestamp(_ value: Any?) -> Date {
            guard let string = value as? String else { return .distantPast }
            return dateParser.date(from: string) ?? secondsParser.date(from: string) ?? .distantPast
        }
        for line in data.split(separator: 10) {
            if Task.isCancelled { return nil }
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if format == .codex {
                guard let payload = row["payload"] as? [String: Any] else { continue }
                if row["type"] as? String == "session_meta" {
                    if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return nil }
                    thread = payload["id"] as? String ?? thread; project = payload["cwd"] as? String
                    title = names[thread]?.title
                    continue
                }
                guard row["type"] as? String == "response_item", payload["type"] as? String == "message",
                      let role = payload["role"] as? String, role == "user" || role == "assistant" else { continue }
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard !text.isEmpty, !text.hasPrefix("<environment_context>"), !text.hasPrefix("# AGENTS.md instructions") else { continue }
                let time = timestamp(row["timestamp"])
                records.append(StreamRecord(kind: role == "user" ? StreamKind.user.rawValue : StreamKind.prose.rawValue, text: text, time: time, itemID: payload["id"] as? String, isFinalResponse: payload["phase"] as? String == "final_answer" ? true : nil))
                updated = max(updated, time)
            } else {
                guard row["isSidechain"] as? Bool != true else { continue }
                if let cwd = row["cwd"] as? String { project = cwd }
                if let customTitle = row["customTitle"] as? String { title = customTitle }
                guard let message = row["message"] as? [String: Any], let role = row["type"] as? String, role == "user" || role == "assistant" else { continue }
                let id = row["uuid"] as? String ?? UUID().uuidString
                guard seen.insert(id).inserted else { continue }
                let time = timestamp(row["timestamp"])
                let blocks = message["content"] as? [[String: Any]] ?? (message["content"] as? String).map { [["type": "text", "text": $0]] } ?? []
                for (index, block) in blocks.enumerated() where block["type"] as? String == "text" {
                    guard let text = block["text"] as? String, !text.isEmpty else { continue }
                    records.append(StreamRecord(kind: role == "user" ? StreamKind.user.rawValue : StreamKind.prose.rawValue, text: text, time: time, itemID: id + ":\(index)"))
                }
                updated = max(updated, time)
            }
        }
        guard let project, !records.isEmpty else { return nil }
        title = title ?? records.first(where: { $0.kind == StreamKind.user.rawValue }).map { String($0.text.prefix(100)) } ?? "Previous chat"
        return Document(source: url.path, thread: thread, provider: format == .claude ? "claude" : "codex", project: project, title: title!, updated: names[thread]?.updated ?? updated, records: records)
    }
}
