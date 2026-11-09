import Foundation

/// An atomic checkpoint plus an append-only feed journal. Old feed/protocol files
/// remain available for compatibility; unreadable originals are preserved.
/// Confined to the sessions' serial persistence queue.
final class ConversationStore: @unchecked Sendable {
    struct Snapshot: Codable {
        let metadata: Data
        let records: [StreamRecord]
        let journalOffset: Int
    }
    struct Mutation: Codable {
        var record: StreamRecord?
        var merging: Bool?
        var command: CommandActivity?
        var itemID: String?
        var final: StreamRecord?
        var replacement: [StreamRecord]?
        var metadata: Data?
    }
    private struct Header: Decodable { let metadata: Data; let journalOffset: Int }
    private let folder: URL
    /// True after `load` when replay needed the legacy feed or journal tail.
    private(set) var needsCheckpoint = true
    /// Set by `prepareCheckpoint` on the caller's thread.
    private var hasBaseline = false
    // Only touched by `writeCheckpoint`, on the persistence queue.
    private var lastCheckpoint: Data?
    private var legacyWritable: (metadata: Bool, feed: Bool)?
    private var journal: URL { folder.appendingPathComponent("history-journal.jsonl") }
    private var checkpoint: URL { folder.appendingPathComponent("history-v1.json") }
    private var backup: URL { folder.appendingPathComponent("history-v1.backup.json") }

    init(folder: URL) { self.folder = folder }

    static func snapshot(in folder: URL) -> Snapshot? {
        for name in ["history-v1.json", "history-v1.backup.json"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) { return snapshot }
        }
        return nil
    }

    static func metadata(in folder: URL) -> Data? {
        // Launch lists every saved chat; skip decoding each one's records.
        var header: Header?
        for name in ["history-v1.json", "history-v1.backup.json"] where header == nil {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { header = try? JSONDecoder().decode(Header.self, from: data) }
        }
        let snapshot = header
        var metadata = snapshot?.metadata ?? (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
        for line in journalTail(in: folder, after: snapshot?.journalOffset ?? 0).split(separator: 10) {
            if let change = try? JSONDecoder().decode(Mutation.self, from: Data(line)), let value = change.metadata { metadata = value }
        }
        return metadata
    }

    func load() -> [StreamRecord] {
        let snapshot = Self.snapshot(in: folder)
        let initial = snapshot?.records ?? (try? Data(contentsOf: folder.appendingPathComponent("feed.json")))
            .flatMap { try? JSONDecoder().decode([StreamRecord].self, from: $0) } ?? []
        var feed = FeedBuffer(initial)
        let tail = Self.journalTail(in: folder, after: snapshot?.journalOffset ?? 0)
        needsCheckpoint = snapshot == nil || !tail.isEmpty
        for line in tail.split(separator: 10) {
            guard let change = try? JSONDecoder().decode(Mutation.self, from: Data(line)) else { continue }
            if let replacement = change.replacement { feed = FeedBuffer(replacement) }
            if let record = change.record { feed.append(record, merging: change.merging ?? false) }
            if let command = change.command, let id = change.itemID { feed.updateCommand(command, itemID: id) }
            if let final = change.final { feed.finalizeResponse(final) }
        }
        return feed.records
    }

    private static func journalTail(in folder: URL, after offset: Int) -> Data {
        guard offset >= 0, let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("history-journal.jsonl")) else { return Data() }
        defer { try? handle.close() }
        do {
            // Skip checkpointed bytes instead of loading years of deltas into
            // memory just to reopen an offline conversation.
            let end = try handle.seekToEnd()
            guard UInt64(offset) <= end else { return Data() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.readToEnd() ?? Data()
        } catch { return Data() }
    }

    /// Call on the session's persistence queue, before publishing the mutation.
    func append(_ change: Mutation, synchronize: Bool = true) throws {
        if !FileManager.default.fileExists(atPath: journal.path) {
            guard FileManager.default.createFile(atPath: journal.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: journal)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // Preserve a torn last line as evidence, but terminate it so a later
        // valid mutation can still be recovered.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != 10 {
                try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
            }
        }
        try handle.seekToEnd()
        var data = try JSONEncoder().encode(change); data.append(10)
        try handle.write(contentsOf: data)
        if synchronize { try handle.synchronize() }
    }

    func save(metadata: Data, records: [StreamRecord]) throws {
        let offset = try prepareCheckpoint(metadata: metadata, records: records)
        try writeCheckpoint(metadata: metadata, records: records, journalOffset: offset)
    }

    /// Journals the checkpoint's metadata and returns the offset it covers.
    /// Call in the same order as `append`, at the moment `records` was captured.
    func prepareCheckpoint(metadata: Data, records: [StreamRecord]) throws -> Int {
        if !hasBaseline, Self.snapshot(in: folder) == nil {
            // A baseline also makes replay unambiguous if both checkpoints
            // eventually become unreadable and only a legacy feed remains.
            try append(.init(replacement: records))
        }
        hasBaseline = true
        try append(.init(metadata: metadata), synchronize: false)
        return (try? journal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Encodes and atomically replaces the checkpoint. Safe to run on a
    /// background queue while later mutations are appended to the journal.
    func writeCheckpoint(metadata: Data, records: [StreamRecord], journalOffset offset: Int) throws {
        let data = try JSONEncoder().encode(Snapshot(metadata: metadata, records: records, journalOffset: offset))
        // Never replace a usable backup with a damaged primary. A primary this
        // store wrote is known to be readable, so it needn't be decoded again.
        if let lastCheckpoint {
            try lastCheckpoint.write(to: backup, options: .atomic)
        } else if let old = try? Data(contentsOf: checkpoint) {
            if (try? JSONDecoder().decode(Snapshot.self, from: old)) != nil { try old.write(to: backup, options: .atomic) }
            else { try old.write(to: folder.appendingPathComponent("history-v1.unreadable-" + UUID().uuidString + ".json"), options: .atomic) }
        }
        try data.write(to: checkpoint, options: .atomic)
        lastCheckpoint = data; needsCheckpoint = false
        // Keep compatibility files, but only after the authoritative paired
        // snapshot commits. Their mismatch can no longer lose a conversation.
        let metaURL = folder.appendingPathComponent("session.json"), feedURL = folder.appendingPathComponent("feed.json")
        // Do not overwrite unreadable legacy files: they may be repairable by
        // another version or contain evidence useful to manual recovery.
        // Check once per store; afterwards these files are ones it wrote.
        let writable = legacyWritable ?? {
            let oldMeta = try? Data(contentsOf: metaURL), oldFeed = try? Data(contentsOf: feedURL)
            return (oldMeta == nil || (try? JSONSerialization.jsonObject(with: oldMeta!)) != nil,
                    oldFeed == nil || (try? JSONDecoder().decode([StreamRecord].self, from: oldFeed!)) != nil)
        }()
        legacyWritable = writable
        if writable.metadata { try metadata.write(to: metaURL, options: .atomic) }
        if writable.feed { try JSONEncoder().encode(records).write(to: feedURL, options: .atomic) }
    }
}
