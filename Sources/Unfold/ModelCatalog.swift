import Foundation

/// Provider discovery is cached separately from models explicitly added by the
/// user. Refreshing availability must never erase a custom model or chat choice.
@MainActor
final class ModelCatalog {
    private let defaults: UserDefaults?
    private var discovered: [AgentProvider: [[String: Any]]] = [:]
    private var custom: [AgentProvider: [[String: Any]]] = [:]
    private var refreshed: [AgentProvider: Date] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        for provider in AgentProvider.allCases {
            discovered[provider] = Self.decode(defaults?.data(forKey: Self.key(provider, "discovered")))
            custom[provider] = Self.decode(defaults?.data(forKey: Self.key(provider, "custom")))
            refreshed[provider] = defaults?.object(forKey: Self.key(provider, "refreshed")) as? Date
        }
    }

    func models(for provider: AgentProvider) -> [[String: Any]] {
        let available = discovered[provider] ?? []
        let fallback: [[String: Any]] = provider == .claude
            ? InferenceSettings.claudeModels.map { ["model": $0.id, "displayName": $0.name] }
            : [["model": InferenceSettings.preferred.model, "displayName": InferenceSettings.preferred.displayName]]
        // Keep the new release available with an older CLI's cached list, too.
        let seed: [[String: Any]] = provider == .claude
            ? [["model": InferenceSettings.claudePreferredModel, "displayName": "Fable 5.2"]] : []
        var seen = Set<String>()
        return ((available.isEmpty ? fallback : available) + seed + (custom[provider] ?? [])).filter {
            guard let id = Self.identifier($0), seen.insert(id).inserted else { return false }
            return true
        }.map { record in
            var record = record
            if let id = Self.identifier(record), let name = custom[provider]?.first(where: { Self.identifier($0) == id })?["displayName"] {
                record["displayName"] = name
            }
            return record
        }
    }

    func update(_ records: [[String: Any]], for provider: AgentProvider) {
        var seen = Set<String>()
        let valid = records.compactMap { record -> [String: Any]? in
            guard let id = Self.identifier(record), seen.insert(id).inserted else { return nil }
            var record = record; record["model"] = id
            return record
        }
        guard !valid.isEmpty, let data = try? JSONSerialization.data(withJSONObject: valid) else { return }
        discovered[provider] = valid; refreshed[provider] = Date()
        defaults?.set(data, forKey: Self.key(provider, "discovered"))
        defaults?.set(refreshed[provider], forKey: Self.key(provider, "refreshed"))
    }

    @discardableResult
    func add(id: String, name: String, for provider: AgentProvider) throws -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw CodexConnection.error("Enter a model ID without spaces, such as claude-fable-5-2.")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var records = custom[provider] ?? []
        records.removeAll { Self.identifier($0) == id }
        records.append(["model": id, "displayName": name.isEmpty ? id : name])
        let data = try JSONSerialization.data(withJSONObject: records)
        custom[provider] = records
        defaults?.set(data, forKey: Self.key(provider, "custom"))
        return id
    }

    func needsRefresh(for provider: AgentProvider, now: Date = Date()) -> Bool {
        guard let date = refreshed[provider] else { return true }
        return now.timeIntervalSince(date) >= 6 * 60 * 60
    }

    static func identifier(_ record: [String: Any]) -> String? {
        guard let id = record["model"] as? String ?? record["id"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }
    private static func key(_ provider: AgentProvider, _ kind: String) -> String { "thoughtstream.models.\(provider.rawValue).\(kind)" }
    private static func decode(_ data: Data?) -> [[String: Any]] {
        guard let data else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}

@MainActor
enum ProviderModelDiscovery {
    /// A fresh transport reads capabilities without attaching to a chat,
    /// submitting a prompt, or changing the running conversation's model.
    static func models(for provider: AgentProvider, executable: URL) async throws -> [[String: Any]] {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("thoughtstream-models-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        if provider == .claude {
            let runtime = ClaudeConnection()
            var result: [[String: Any]] = []
            runtime.onModels = { result = $0 }
            defer { runtime.stop() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let settings = InferenceSettings(model: InferenceSettings.claudePreferredModel, effort: "high", tier: "default")
                try await runtime.start(executable: executable, project: project, settings: settings, resume: nil, discoveryOnly: true)
                try Task.checkCancellation()
            } onCancel: { Task { @MainActor in runtime.stop() } }
            guard !result.isEmpty else { throw CodexConnection.error("Claude Code returned no models. Your saved models are still available.") }
            return result
        }
        let runtime = CodexConnection()
        defer { runtime.stop() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await runtime.start(executable: executable, project: project)
            let result = try await runtime.listModels()
            guard !result.isEmpty else { throw CodexConnection.error("Codex returned no models. Your saved models are still available.") }
            return result
        } onCancel: { Task { @MainActor in runtime.stop() } }
    }
}
