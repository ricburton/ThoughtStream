import Foundation

enum AgentProvider: String, CaseIterable, Codable {
    case codex, claude
    var label: String { self == .codex ? "Codex" : "Claude Code" }
    static var selected: AgentProvider {
        AgentProvider(rawValue: UserDefaults.standard.string(forKey: "thoughtstream.provider") ?? "") ?? .codex
    }
    func select() { UserDefaults.standard.set(rawValue, forKey: "thoughtstream.provider") }
    var accessLabel: String {
        if AccessMode.selected == .fullAccess { return "Full access · no approvals" }
        return self == .claude ? "Claude permissions · ask before actions" : AccessMode.selected.label
    }
}
