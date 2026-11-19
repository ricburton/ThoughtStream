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
    private struct RecordActivity: Decodable { let kind: String; let time: Date }
    private struct ActivityHeader: Decodable { let records: [RecordActivity] }
    private struct CatalogStamp: Codable, Equatable {
        let size: Int?
        let modified: Date?
        let created: Date?
    }
    private struct Catalog: Codable {
        let stamps: [CatalogStamp]
        let metadata: Data
    }
    private let folder: URL
    /// True after `load` when replay needed the legacy feed or journal tail.
    private(set) var needsCheckpoint = true
    /// Set by `prepareCheckpoint` on the caller's thread.
    private var hasBaseline = false
    // Only touched by `writeCheckpoint`, on the persistence queue.
    private var lastCheckpointStamp: CatalogStamp?
    private let checkpointLock = NSLock()
    private var pendingCheckpoint: Snapshot?
    private var checkpointScheduled = false
    private var legacyWritable: (metadata: Bool, feed: Bool)?
    private var journal: URL { folder.appendingPathComponent("history-journal.jsonl") }
    private var checkpoint: URL { folder.appendingPathComponent("history-v1.json") }
    private var backup: URL { folder.appendingPathComponent("history-v1.backup.json") }

    init(folder: URL) { self.folder = folder }

    private static func stamp(_ url: URL) -> CatalogStamp {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        return CatalogStamp(size: value?.fileSize, modified: value?.contentModificationDate, created: value?.creationDate)
    }

    static func snapshot(in folder: URL) -> Snapshot? {
        for name in ["history-v1.json", "history-v1.backup.json"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) { return snapshot }
        }
        return nil
    }

    static func metadata(in folder: URL, includingActivity: Bool = false) -> Data? {
        // A disposable index avoids parsing every large checkpoint at launch.
        // Any change to an authoritative file invalidates it, including a torn
        // checkpoint or journal-only recovery. It never replaces those files.
        let names = ["history-v1.json", "history-v1.backup.json", "history-journal.jsonl", "session.json"]
        func stamps() -> [CatalogStamp] {
            names.map { stamp(folder.appendingPathComponent($0)) }
        }
        let before = stamps()
        let catalogURL = folder.appendingPathComponent(includingActivity ? "history-sidebar-v1.json" : "history-catalog-v1.json")
        if let data = try? Data(contentsOf: catalogURL),
           let cached = try? JSONDecoder().decode(Catalog.self, from: data), cached.stamps == before {
            return cached.metadata
        }
        // Launch lists every saved chat; skip decoding each one's records.
        var header: Header?
        var lastActivity: Date?, lastConversationActivity: Date?
        for name in ["history-v1.json", "history-v1.backup.json"] where header == nil {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name), options: .mappedIfSafe) {
                header = try? JSONDecoder().decode(Header.self, from: data)
                if includingActivity, let header,
                   let meta = (try? JSONSerialization.jsonObject(with: header.metadata)) as? [String: Any] {
                    lastActivity = (meta["lastActivity"] as? Double).map(Date.init(timeIntervalSince1970:))
                    lastConversationActivity = (meta["lastConversationActivity"] as? Double).map(Date.init(timeIntervalSince1970:))
                    if lastActivity == nil, let activity = try? JSONDecoder().decode(ActivityHeader.self, from: data) {
                        // One-time migration of old sidebar dates. Skip text,
                        // tool payloads, and all the other transcript fields.
                        lastActivity = activity.records.last?.time
                        lastConversationActivity = activity.records.last { ["You", "Agent"].contains($0.kind) }?.time
                    }
                }
            }
        }
        let snapshot = header
        var metadata = snapshot?.metadata ?? (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
        for line in journalTail(in: folder, after: snapshot?.journalOffset ?? 0).split(separator: 10) {
            if let change = try? JSONDecoder().decode(Mutation.self, from: Data(line)) {
                if let value = change.metadata { metadata = value }
                if includingActivity {
                    if let replacement = change.replacement {
                        lastActivity = replacement.last?.time
                        lastConversationActivity = replacement.last { ["You", "Agent"].contains($0.kind) }?.time
                    }
                    if let record = change.record ?? change.final {
                        lastActivity = record.time
                        if ["You", "Agent"].contains(record.kind) { lastConversationActivity = record.time }
                    }
                }
            }
        }
        if includingActivity, let value = metadata,
           var meta = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] {
            if let lastActivity { meta["lastActivity"] = lastActivity.timeIntervalSince1970 }
            if let lastConversationActivity { meta["lastConversationActivity"] = lastConversationActivity.timeIntervalSince1970 }
            metadata = (try? JSONSerialization.data(withJSONObject: meta)) ?? value
        }
        // Do not stamp a mixed read if another writer changed the files.
        if let metadata, before == stamps(),
           let data = try? JSONEncoder().encode(Catalog(stamps: before, metadata: metadata)) {
            try? data.write(to: catalogURL, options: .atomic)
        }
        return metadata
    }

    func load() -> [StreamRecord] {
        let snapshot = Self.snapshot(in: folder)
        hasBaseline = snapshot != nil
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

    /// Keep at most the in-flight snapshot and the newest waiting snapshot.
    /// Intermediate saves are already recoverable from the append-only journal.
    func enqueueCheckpoint(metadata: Data, records: [StreamRecord], journalOffset: Int,
                           on queue: DispatchQueue, onError: @escaping (Error) -> Void) {
        checkpointLock.lock()
        pendingCheckpoint = Snapshot(metadata: metadata, records: records, journalOffset: journalOffset)
        let schedule = !checkpointScheduled
        checkpointScheduled = true
        checkpointLock.unlock()
        guard schedule else { return }
        queue.async {
            while true {
                self.checkpointLock.lock()
                let snapshot = self.pendingCheckpoint
                self.pendingCheckpoint = nil
                if snapshot == nil { self.checkpointScheduled = false }
                self.checkpointLock.unlock()
                guard let snapshot else { return }
                autoreleasepool {
                    do {
                        try self.writeCheckpoint(metadata: snapshot.metadata, records: snapshot.records,
                                                 journalOffset: snapshot.journalOffset)
                    } catch { onError(error) }
                }
            }
        }
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
        if let old = try? Data(contentsOf: checkpoint, options: .mappedIfSafe) {
            let unchanged = lastCheckpointStamp.map { $0 == Self.stamp(checkpoint) } ?? false
            if unchanged || (try? JSONDecoder().decode(Snapshot.self, from: old)) != nil { try old.write(to: backup, options: .atomic) }
            else { try old.write(to: folder.appendingPathComponent("history-v1.unreadable-" + UUID().uuidString + ".json"), options: .atomic) }
        }
        try data.write(to: checkpoint, options: .atomic)
        lastCheckpointStamp = Self.stamp(checkpoint); needsCheckpoint = false
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
