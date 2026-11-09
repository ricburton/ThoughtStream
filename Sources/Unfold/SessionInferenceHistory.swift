import Foundation

/// One-time migration for conversations saved before per-chat settings existed.
enum SessionInferenceHistory {
    static func latest(in url: URL, provider: AgentProvider) -> InferenceSettings? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var offset = try? handle.seekToEnd() else { return nil }
        var remainder = Data()
        // Read backwards so large streamed transcripts usually need only their
        // last turn. Partial JSON lines are joined across chunk boundaries.
        while offset > 0 {
            let count = min(offset, 65_536)
            offset -= count
            do {
                try handle.seek(toOffset: offset)
                guard var data = try handle.read(upToCount: Int(count)) else { return nil }
                data.append(remainder)
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropFirst().reversed() {
                    if let settings = decode(Data(line), provider: provider) { return settings }
                }
                remainder = lines.first.map { Data($0) } ?? Data()
            } catch { return nil }
        }
        return decode(remainder, provider: provider)
    }

    private static func decode(_ data: Data, provider: AgentProvider) -> InferenceSettings? {
        guard data.range(of: Data("\"model\"".utf8)) != nil,
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let params: [String: Any]
        if provider == .codex {
            // Old resume requests used the global default, so they are not
            // evidence of the model the user actually chose for this chat.
            guard event["_direction"] as? String == "outgoing",
                  ["thread/start", "turn/start"].contains(event["method"] as? String ?? ""),
                  let value = event["params"] as? [String: Any] else { return nil }
            params = value
        } else {
            guard let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "system", payload["subtype"] as? String == "init" else { return nil }
            params = payload
        }
        guard let model = params["model"] as? String, !model.isEmpty else { return nil }
        let config = params["config"] as? [String: Any]
        return InferenceSettings(model: model,
            effort: params["effort"] as? String ?? config?["model_reasoning_effort"] as? String ?? "high",
            tier: params["serviceTier"] as? String ?? "default")
    }
}
