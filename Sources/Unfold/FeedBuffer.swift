import Foundation

enum StreamKind: String { case prose = "Agent", reasoning = "Reasoning summary", command = "Command", code = "Code", output = "Output", change = "File change", error = "Error", system = "Session", user = "You", tool = "Tool", compaction = "Context compaction" }

struct StreamRecord: Codable, Equatable {
    var kind: String
    var text: String
    var language: String?
    var time: Date = Date()
    var itemID: String? = nil
    var python: [PythonSnippet]? = nil
    var command: CommandActivity? = nil
    var isFinalResponse: Bool? = nil
    var queuedStatus: String? = nil
    var queuedDetail: String? = nil
    var queuedMessageID: String? = nil
}

struct CommandActivity: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case running, succeeded, failed, interrupted, unknown }
    var state: State
    var startedAt: Date
    var finishedAt: Date? = nil
    var durationMs: Int? = nil
    var exitCode: Int? = nil

    func elapsed(at now: Date = Date()) -> String {
        if state != .running && durationMs == nil && finishedAt == nil { return "—" }
        let seconds = durationMs.map { Double($0) / 1000 } ?? max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
        if seconds < 1 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds)
        return total < 60 ? "\(total)s" : total < 3600 ? "\(total / 60)m \(total % 60)s" : "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

/// A chronological feed: only adjacent fragments of the same item and kind merge.
/// Interleaved activity keeps its original order rather than moving earlier output.
struct FeedBuffer {
    private(set) var records: [StreamRecord]
    init(_ records: [StreamRecord] = []) { self.records = records }

    @discardableResult
    mutating func updateCommand(_ activity: CommandActivity, itemID: String) -> Int? {
        guard let index = records.lastIndex(where: { $0.kind == StreamKind.command.rawValue && $0.itemID == itemID }) else { return nil }
        records[index].command = activity
        return index
    }

    @discardableResult
    mutating func append(_ record: StreamRecord, merging: Bool) -> Int {
        if merging, let item = record.itemID, let last = records.indices.last,
           records[last].itemID == item, records[last].kind == record.kind,
           records[last].language == record.language {
            records[last].text += record.text
            return last
        }
        // Runtime bookkeeping may arrive after completion. Keep it available
        // just before the answer, until a new conversational message begins.
        if records.last?.isFinalResponse == true,
           ![StreamKind.user.rawValue, StreamKind.prose.rawValue, StreamKind.reasoning.rawValue, StreamKind.error.rawValue].contains(record.kind) {
            let index = records.count - 1
            records.insert(record, at: index)
            return index
        }
        records.append(record)
        return records.count - 1
    }

    @discardableResult
    mutating func finalizeResponse(_ response: StreamRecord) -> Int {
        var response = response
        response.isFinalResponse = true
        let first = response.itemID.flatMap { item in records.firstIndex { $0.kind == StreamKind.prose.rawValue && $0.itemID == item } }
        if let first { response.time = records[first].time }
        if let item = response.itemID {
            records.removeAll { $0.kind == StreamKind.prose.rawValue && $0.itemID == item }
        }
        records.append(response)
        return first ?? records.count - 1
    }
}
