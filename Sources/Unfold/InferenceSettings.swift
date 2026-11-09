import Foundation

struct InferenceSettings: Codable, Equatable {
    var model: String
    var effort: String
    var tier: String

    static let preferred = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "default")
    static let tiers = ["default", "fast", "ultrafast"]
    /// Most capable Claude model; Claude Code's own list replaces this catalog once connected.
    static let claudePreferredModel = "claude-fable-5-2"
    static let claudeModels: [(id: String, name: String)] = [
        ("claude-fable-5-2", "Fable 5.2"), ("claude-fable-5-1[1m]", "Fable 5.1"), ("claude-fable-5", "Fable 5"),
        ("opus", "Opus 5.5"), ("claude-opus-5", "Opus 5"), ("claude-opus-4-8", "Opus 4.8"),
        ("claude-opus-4-7", "Opus 4.7"), ("claude-opus-4-6", "Opus 4.6"),
        ("sonnet", "Sonnet 5.5"), ("claude-sonnet-5", "Sonnet 5"), ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("haiku", "Haiku 5.5"), ("claude-haiku-4-5-20251001", "Haiku 4.5")]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static func tiers(for provider: AgentProvider) -> [String] {
        provider == .claude ? ["default", "fast"] : tiers
    }
    /// Standard is safe before discovery. Accelerated tiers require this runtime's
    /// model/account catalog, rather than general API availability.
    static func codexTiers(for model: String, in catalog: [[String: Any]]) -> [String] {
        guard let record = catalog.first(where: { ($0["model"] as? String ?? $0["id"] as? String) == model }) else {
            return ["default"]
        }
        let advertised = (record["additionalSpeedTiers"] as? [String] ?? [])
            + (record["serviceTiers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let supported = Set(advertised.map { $0 == "priority" ? "fast" : $0 })
        return tiers.filter { $0 == "default" || supported.contains($0) }
    }
    func resolvingCodexTier(in catalog: [[String: Any]]) -> InferenceSettings {
        var resolved = self
        let requested = tier == "priority" ? "fast" : tier
        let supported = Self.codexTiers(for: model, in: catalog)
        resolved.tier = supported.contains(requested) ? requested : supported.contains("fast") ? "fast" : "default"
        return resolved
    }
    static func supportsClaudeFastMode(_ model: String) -> Bool {
        let name = model.lowercased().components(separatedBy: "[")[0]
        return name == "opus" || name.range(of: #"^(?:claude-)?opus-(?:4[.-]8|5(?:[.-]5)?)(?:-\d{8})?$"#, options: .regularExpression) != nil
    }
    var claudeFastModeEnabled: Bool { tier == "fast" && Self.supportsClaudeFastMode(model) }
    static func load(from defaults: UserDefaults = .standard, provider: AgentProvider = .codex) -> InferenceSettings {
        if provider == .claude {
            let migrated = defaults.bool(forKey: "thoughtstream.claude.preferredModelMigrated")
            let model = claudeModel(saved: defaults.string(forKey: "thoughtstream.claude.model"), migrated: migrated)
            if !migrated {
                defaults.set(model, forKey: "thoughtstream.claude.model")
                defaults.set(true, forKey: "thoughtstream.claude.preferredModelMigrated")
            }
            let tier = defaults.string(forKey: "thoughtstream.claude.tier") ?? "default"
            return InferenceSettings(model: model,
                                     effort: defaults.string(forKey: "thoughtstream.claude.effort") ?? "high",
                                     tier: tier == "fast" && supportsClaudeFastMode(model) ? "fast" : "default")
        }
        return InferenceSettings(
            model: defaults.string(forKey: "unfold.inference.model") ?? preferred.model,
            effort: defaults.string(forKey: "unfold.inference.effort") ?? preferred.effort,
            tier: defaults.string(forKey: "unfold.inference.tier") ?? preferred.tier)
    }
    /// "sonnet" was the implicit default before the full catalog; it moves once to the most capable model.
    static func claudeModel(saved: String?, migrated: Bool) -> String {
        guard let saved, migrated || saved != "sonnet" else { return claudePreferredModel }
        return saved
    }
    func save(to defaults: UserDefaults = .standard, provider: AgentProvider = .codex) {
        if provider == .claude {
            defaults.set(model, forKey: "thoughtstream.claude.model")
            defaults.set(effort, forKey: "thoughtstream.claude.effort")
            defaults.set(claudeFastModeEnabled ? "fast" : "default", forKey: "thoughtstream.claude.tier")
            return
        }
        defaults.set(model, forKey: "unfold.inference.model")
        defaults.set(effort, forKey: "unfold.inference.effort")
        defaults.set(tier, forKey: "unfold.inference.tier")
    }
    var displayName: String {
        if model == "gpt-6.1-sol" { return "GPT-6.1 Sol" }
        return Self.claudeModels.first { $0.id == model }?.name ?? model
    }
    var summary: String { "\(displayName) · \(effort.capitalized) · \(tier == "default" ? "Standard" : tier.capitalized)" }
    var threadParameters: [String: Any] {
        ["model": model, "serviceTier": tier, "config": ["model_reasoning_effort": effort]]
    }
    var turnParameters: [String: Any] { ["model": model, "effort": effort, "serviceTier": tier] }
}
