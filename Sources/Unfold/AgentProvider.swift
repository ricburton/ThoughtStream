import Foundation

enum AgentProvider: String, CaseIterable, Codable {
    case codex, claude, gemini, local
    var label: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini"
        case .local: return "Local Model"
        }
    }
    /// A local model runs on this Mac and keeps working with no Internet.
    var needsInternet: Bool { self != .local }
    static var selected: AgentProvider {
        AgentProvider(rawValue: UserDefaults.standard.string(forKey: "thoughtstream.provider") ?? "") ?? .codex
    }
    func select() { UserDefaults.standard.set(rawValue, forKey: "thoughtstream.provider") }
    var accessLabel: String {
        if AccessMode.selected == .fullAccess { return "Full access · no approvals" }
        switch self {
        case .claude: return "Claude permissions · ask before actions"
        case .gemini: return "Gemini · actions requiring approval are blocked"
        case .local: return "Local tools · ask before actions"
        case .codex: return AccessMode.selected.label
        }
    }
}
