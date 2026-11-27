import Foundation

enum AccountProvider: CaseIterable {
    case codex, claude

    var title: String { agent.label }
    var agent: AgentProvider { self == .codex ? .codex : .claude }
    var localLabel: String { self == .codex ? "Local Codex" : "Local Claude" }
    var keyLabel: String { self == .codex ? "OpenAI API key" : "Anthropic API key" }
    var dashboard: URL {
        switch self {
        case .codex: return URL(string: "https://platform.openai.com/api-keys")!
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        }
    }

    @MainActor var currentKey: String? {
        get { self == .codex ? CodexConnection.sessionAPIKey : ClaudeConnection.sessionAPIKey }
        nonmutating set {
            switch self {
            case .codex: CodexConnection.sessionAPIKey = newValue
            case .claude: ClaudeConnection.sessionAPIKey = newValue
            }
        }
    }

    /// Verify the candidate outside the conversation. Commit the change on the
    /// main actor only once verification succeeds and affected chats are idle.
    @MainActor
    func connect(apiKey: String?, executable: URL, sessions: () -> [Session],
                 configureQueue: (Session) -> Void, status: (String) -> Void) async throws -> String {
        func affectedChats() throws -> [Session] {
            guard currentKey != apiKey else { return [] }
            let chats = sessions().filter { $0.provider == agent }
            guard chats.allSatisfy({ $0.canChangeAccount }) else {
                throw CodexConnection.error("Finish the active " + title + " task before changing accounts.")
            }
            return chats
        }

        _ = try affectedChats()
        let result: String
        switch (self, apiKey) {
        case (.codex, let key?):
            let probe = CodexConnection()
            defer { probe.stop() }
            try await probe.startWithKey(key, executable: executable, directory: AgentInstructions.runtimeDirectory())
            result = "API key configured in Codex. Access is checked when you send a message."
        case (.codex, nil):
            try await CodexConnection.ensureLocalSignIn(executable: executable, status: status)
            result = "Signed in with ChatGPT."
        case (.claude, let key?):
            try await ClaudeConnection.checkAPIKey(key)
            result = "Anthropic accepted the API key."
        case (.claude, nil):
            try await ClaudeConnection.ensureLocalSignIn(executable: executable, status: status)
            result = "Signed in with Claude Code."
        }

        try Task.checkCancellation()
        let chats = try affectedChats()
        for chat in chats { chat.stop() }
        currentKey = apiKey
        for chat in chats { configureQueue(chat) }
        return result
    }
}
