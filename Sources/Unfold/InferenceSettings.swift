import Foundation

struct InferenceSettings: Codable, Equatable {
    var model: String
    var effort: String
    var tier: String

    static let preferred = InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "default")
    static let tiers = ["default", "fast", "ultrafast"]
    // https://aistudio.google.com/docs/models — verified 2026-11-21.
    static let geminiPreferredModel = "gemini-4-carbon"
    static let geminiModels: [(id: String, name: String)] = [
        ("gemini-4-carbon", "Gemini 4 Carbon"), ("gemini-4-neon", "Gemini 4 Neon"),
        ("gemini-4-hydrogen", "Gemini 4 Hydrogen"), ("gemini-4-argon", "Gemini 4 Argon"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash")]
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
        switch provider {
        case .claude: return ["default", "fast"]
        case .local, .gemini: return ["default"]
        case .codex: return tiers
        }
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
    /// An explicit model change can require a different effort. With no
    /// advertised choices, retain the user's value for custom/future models.
    func resolvingEffort(in catalog: [[String: Any]]) -> InferenceSettings {
        guard let record = Self.modelRecord(for: model, in: catalog) else { return self }
        let efforts = (record["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }.filter { !$0.isEmpty }
        guard let first = efforts.first, !efforts.contains(effort) else { return self }
        var resolved = self
        let suggested = record["defaultReasoningEffort"] as? String
        resolved.effort = suggested.flatMap { efforts.contains($0) ? $0 : nil } ?? first
        return resolved
    }
    static func modelRecord(for model: String, in catalog: [[String: Any]]) -> [String: Any]? {
        catalog.first { ($0["model"] as? String ?? $0["id"] as? String) == model }
            ?? catalog.first { $0["value"] as? String == model || $0["resolvedModel"] as? String == model }
    }
    static func supportsClaudeFastMode(_ model: String, in catalog: [[String: Any]] = []) -> Bool {
        if let supported = modelRecord(for: model, in: catalog)?["supportsFastMode"] as? Bool { return supported }
        let name = model.lowercased().components(separatedBy: "[")[0]
        return name == "opus" || name.range(of: #"^(?:claude-)?opus-(?:4[.-]8|5(?:[.-]5)?)(?:-\d{8})?$"#, options: .regularExpression) != nil
    }
    static func load(from defaults: UserDefaults = .standard, provider: AgentProvider = .codex) -> InferenceSettings {
        if provider == .gemini {
            return InferenceSettings(model: defaults.string(forKey: "thoughtstream.gemini.model") ?? geminiPreferredModel,
                                     effort: "default", tier: "default")
        }
        if provider == .local {
            // Empty until a local model is chosen; the first one found is used then.
            return InferenceSettings(model: defaults.string(forKey: "thoughtstream.local.model") ?? "", effort: "default", tier: "default")
        }
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
                                     tier: tier == "fast" ? "fast" : "default")
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
        if provider == .gemini {
            defaults.set(model, forKey: "thoughtstream.gemini.model")
            return
        }
        if provider == .local {
            if !model.isEmpty { defaults.set(model, forKey: "thoughtstream.local.model") }
            return
        }
        if provider == .claude {
            defaults.set(model, forKey: "thoughtstream.claude.model")
            defaults.set(effort, forKey: "thoughtstream.claude.effort")
            // Preserve intent; the connected runtime checks model capabilities.
            defaults.set(tier == "fast" ? "fast" : "default", forKey: "thoughtstream.claude.tier")
            return
        }
        defaults.set(model, forKey: "unfold.inference.model")
        defaults.set(effort, forKey: "unfold.inference.effort")
        defaults.set(tier, forKey: "unfold.inference.tier")
    }
    var displayName: String {
        if let name = Self.geminiModels.first(where: { $0.id == model })?.name { return name }
        if model == "gpt-6.1-sol" { return "GPT-6.1 Sol" }
        if LocalModel.split(model) != nil { return LocalModel.shortName(model) }
        return Self.claudeModels.first { $0.id == model }?.name ?? model
    }
    var summary: String { "\(displayName) · \(effort.capitalized) · \(tier == "default" ? "Standard" : tier.capitalized)" }
    var threadParameters: [String: Any] {
        ["model": model, "serviceTier": tier, "config": ["model_reasoning_effort": effort]]
    }
    var turnParameters: [String: Any] { ["model": model, "effort": effort, "serviceTier": tier] }
}
