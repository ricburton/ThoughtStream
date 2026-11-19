import Foundation
import Darwin

/// Recovery for older builds that saved an explicitly rejected steer as uncertain.
/// Only the latest submission, with an exact input match and its own rejection,
/// is evidence. Missing history or a lost acknowledgement remains uncertain.
enum QueueSubmissionJournal {
    static func rejectedSteer(in url: URL, thread: String, expectedTurn: String,
                              text: String, imagePaths: [String], createdAt: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return false }
        var remainder = Data()
        var skippingLargeLine = false
        var errors: [Int: String] = [:]
        var followingTimestamp: Double?

        func inspect(_ line: Data) -> Bool? {
            // Protocol keys are sorted. Skip large tool events before parsing;
            // only outgoing requests, response errors and timestamps matter.
            let prefix = String(decoding: line.prefix(160), as: UTF8.self)
            let compactPrefix = prefix.replacingOccurrences(of: " ", with: "")
            guard compactPrefix.hasPrefix("{\"_direction\":\"outgoing\"")
                || compactPrefix.hasPrefix("{\"_direction\":\"incoming\",\"error\":")
                || compactPrefix.hasPrefix("{\"_direction\":\"incoming\",\"emittedAtMs\":") else { return nil }
            if prefix.contains("\"emittedAtMs\"") {
                // Extract just the timestamp, without decoding a large streamed item.
                if let range = prefix.range(of: "\"emittedAtMs\":"),
                   let value = Double(prefix[range.upperBound...].prefix(while: { $0.isNumber || $0 == " " }).trimmingCharacters(in: .whitespaces)) {
                    followingTimestamp = value
                }
                return nil
            }
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = event["id"] as? Int else { return nil }
            if event["_direction"] as? String == "incoming", event["method"] == nil,
               let error = event["error"] as? [String: Any], let message = error["message"] as? String {
                errors[id] = message
                return nil
            }
            guard event["_direction"] as? String == "outgoing" else { return nil }
            let method = event["method"] as? String
            if method == "initialize" { errors.removeAll() }
            defer { errors.removeValue(forKey: id) }
            guard method == "turn/start" || method == "turn/steer",
                  let params = event["params"] as? [String: Any], params["threadId"] as? String == thread else { return nil }
            // A different or later submission makes the old rejection irrelevant.
            guard method == "turn/steer", params["expectedTurnId"] as? String == expectedTurn,
                  let content = params["input"] as? [[String: Any]], let error = errors[id],
                  error.hasPrefix("expected active turn id `\(expectedTurn)` but found `"),
                  let followingTimestamp else { return false }
            let elapsed = followingTimestamp / 1000 - createdAt.timeIntervalSince1970
            // Legacy requests lack a local timestamp. Require a nearby provider
            // event to rule out an older identical message from the same turn.
            guard elapsed >= -2, elapsed <= 120 else { return false }
            let actualText = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let actualPaths = content.filter { ["localImage", "local_image"].contains($0["type"] as? String ?? "") }.compactMap { $0["path"] as? String }
            return actualText == text && actualPaths == imagePaths
                && content.count == (text.isEmpty ? 0 : 1) + imagePaths.count
        }

        while offset > 0 {
            if Task.isCancelled { return false }
            let count = min(offset, 65_536); offset -= count
            do {
                try handle.seek(toOffset: offset)
                guard var data = try handle.read(upToCount: Int(count)) else { return false }
                data.append(remainder)
                // memchr avoids per-byte Data iteration in large protocol logs.
                let boundaries: [Int] = data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return [] }
                    var positions: [Int] = [], offset = 0
                    while offset < bytes.count, let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset) {
                        offset = base.distance(to: UnsafeRawPointer(newline))
                        positions.append(offset); offset += 1
                    }
                    return positions
                }
                let starts = [0] + boundaries.map { $0 + 1 }
                let ends = boundaries + [data.count]
                let lines = zip(starts, ends).map { data[$0..<$1] }
                if skippingLargeLine, lines.count > 1, let start = lines.last,
                   String(decoding: start.prefix(160), as: UTF8.self).contains("\"outgoing\"") {
                    return false // An oversized later request cannot be ruled out.
                }
                for line in lines.dropFirst().dropLast(skippingLargeLine ? 1 : 0).reversed() {
                    if let result = inspect(Data(line)) { return result }
                }
                if lines.count > 1 { skippingLargeLine = false }
                remainder = skippingLargeLine ? Data() : lines.first.map { Data($0) } ?? Data()
                // Tool results can span megabytes. They cannot prove rejection;
                // skip oversized lines rather than repeatedly copying them.
                if remainder.count > 1_048_576 { remainder.removeAll(); skippingLargeLine = true }
            } catch { return false }
        }
        return inspect(remainder) ?? false
    }
}
