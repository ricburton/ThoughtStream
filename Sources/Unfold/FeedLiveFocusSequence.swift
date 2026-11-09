import Foundation

/// Visits semantic objects once while their contents continue streaming.
/// Runtime item identity survives interleaved fragments and final-answer moves.
struct FeedLiveFocusSequence {
    struct Object {
        let key: String
        var highlight: FeedHighlight
    }
    private(set) var pending: [Object] = []
    private var seen = Set<String>()
    private var showedReasoning = false
    private var showedCode = false

    static func key(_ entry: FeedHighlight, record: StreamRecord) -> String {
        let item = record.itemID ?? "local:\(record.time.timeIntervalSinceReferenceDate)"
        return "\(item):\(entry.kind):\(entry.occurrence):\(entry.kind == "Heading" ? entry.needle ?? "" : "")"
    }

    static func objects(_ entries: [FeedHighlight]) -> [FeedHighlight] {
        let detailedRows = Set(entries.filter { $0.freshCode || $0.createdOutput || $0.kind == "Heading" }.map(\.record))
        return entries.filter {
            !["You", "Session"].contains($0.kind) &&
            !($0.kind == "Reply" && detailedRows.contains($0.record)) &&
            (!$0.summary.isEmpty || !$0.title.isEmpty)
        }
    }

    mutating func offer(_ entry: FeedHighlight, record: StreamRecord) {
        let key = Self.key(entry, record: record)
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].highlight = entry
        } else if seen.insert(key).inserted {
            pending.append(Object(key: key, highlight: entry))
        }
    }

    mutating func next() -> Object? {
        guard !pending.isEmpty else { return nil }
        pending.sort { $0.highlight.record < $1.highlight.record }
        let index: Int
        if !showedReasoning, !showedCode,
           let first = pending.firstIndex(where: { $0.highlight.kind == "Reasoning" }) {
            index = first
        } else if !showedCode, let first = pending.firstIndex(where: { $0.highlight.freshCode }) {
            index = first
        } else { index = 0 }
        let object = pending.remove(at: index)
        showedReasoning = showedReasoning || object.highlight.kind == "Reasoning"
        showedCode = showedCode || object.highlight.freshCode
        // After a priority jump, continue downwards instead of replaying the
        // supporting activity that preceded it.
        pending.removeAll { $0.highlight.record < object.highlight.record }
        return object
    }

    mutating func remap(_ transform: (FeedHighlight) -> FeedHighlight?) {
        pending = pending.compactMap { object in
            transform(object.highlight).map { Object(key: object.key, highlight: $0) }
        }
    }
}
