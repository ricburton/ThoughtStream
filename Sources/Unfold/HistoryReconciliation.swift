import Foundation

/// Merge a complete provider read with the offline feed. Provider item IDs
/// replace streamed fragments; local-only events and unsynced text survive.
enum HistoryReconciliation {
    static func merge(local: [StreamRecord], remote: [StreamRecord]) -> [StreamRecord] {
        guard !remote.isEmpty else { return local }
        func keys(_ records: [StreamRecord]) -> [String] {
            var occurrences: [String: Int] = [:]
            return records.map { record in
                if let id = record.itemID, !id.isEmpty {
                    let base = "id:\(id):\(record.kind)"
                    if record.kind != StreamKind.user.rawValue { return base }
                    // A submitted message can contain text plus attachments.
                    // Each immutable content block matches independently.
                    let count = occurrences[base, default: 0]; occurrences[base] = count + 1
                    return base + ":\(count)"
                }
                let base = "text:\(record.kind):\(record.text)"
                let count = occurrences[base, default: 0]; occurrences[base] = count + 1
                return base + ":\(count)"
            }
        }
        var localKeys = keys(local)
        let remoteKeys = keys(remote)
        let originalGroups = Dictionary(grouping: local.indices, by: { localKeys[$0] })
        let remoteGroups = Dictionary(grouping: remote.indices, by: { remoteKeys[$0] })
        var matched = Set(localKeys).intersection(remoteKeys)
        var aliases: [String: String] = [:]
        // Locally submitted prompts have no provider ID yet. Claude's live and
        // on-disk IDs also differ. Match identical content once per occurrence.
        for key in localKeys where remoteGroups[key] == nil && aliases[key] == nil {
            guard let indices = originalGroups[key], let first = indices.first else { continue }
            // Unsent queue entries must not match an older identical prompt.
            guard local[first].queuedMessageID == nil, local[first].queuedStatus == nil else { continue }
            let text = indices.map { local[$0].text }.joined()
            if let candidate = remoteKeys.first(where: { candidate in
                guard !matched.contains(candidate), let rows = remoteGroups[candidate], let row = rows.first else { return false }
                return remote[row].kind == local[first].kind && rows.map { remote[$0].text }.joined() == text
            }) {
                aliases[key] = candidate; matched.insert(candidate)
            }
        }
        localKeys = localKeys.map { aliases[$0] ?? $0 }
        let localGroups = Dictionary(grouping: local.indices, by: { localKeys[$0] })
        var emitted = Set<String>(), output: [StreamRecord] = [], cursor = 0
        func emit(_ key: String) {
            guard emitted.insert(key).inserted, let indices = remoteGroups[key] else { return }
            var incoming = indices.map { remote[$0] }
            if let old = localGroups[key]?.map({ local[$0] }) {
                if old.contains(where: { $0.isFinalResponse == true }), !incoming.isEmpty {
                    incoming[incoming.count - 1].isFinalResponse = true
                }
                if let known = old.last?.command, known.state != .unknown,
                   incoming.last?.command?.state == .unknown {
                    incoming[incoming.count - 1].command = known
                }
                let oldText = old.map(\.text).joined(), newText = incoming.map(\.text).joined()
                if oldText.count > newText.count, oldText.hasPrefix(newText) {
                    output.append(contentsOf: old); return
                }
            }
            output.append(contentsOf: incoming)
        }
        for index in local.indices {
            let key = localKeys[index]
            if remoteGroups[key] != nil {
                if !emitted.contains(key), let position = remoteKeys[cursor...].firstIndex(of: key) {
                    while cursor <= position { emit(remoteKeys[cursor]); cursor += 1 }
                }
            } else { output.append(local[index]) }
        }
        while cursor < remote.count { emit(remoteKeys[cursor]); cursor += 1 }
        var ordered = FeedBuffer()
        for record in output { ordered.append(record, merging: false) }
        return ordered.records
    }
}
