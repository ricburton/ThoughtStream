import AppKit

enum AccountProvider: CaseIterable {
    case codex, claude

    var title: String { self == .codex ? "Codex" : "Claude Code" }
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
}

@MainActor
final class ProviderAccountControls: NSObject {
    typealias Connect = (AccountProvider, String?, (String) -> Void) async throws -> String

    private enum Copy {
        static let connectKey = "Connect with API Key"
        static let updateKey = "Update API Key"
    }

    let provider: AccountProvider
    let status: NSTextField
    let keyField = NSSecureTextField()
    let connectLocal: NSButton
    let getKey = ThemedButton(title: "Get API Key…", target: nil, action: nil)
    let connectKey = ThemedButton(title: Copy.connectKey, target: nil, action: nil)
    private let connect: Connect
    private var task: Task<Void, Never>?

    static func all(connect: @escaping Connect) -> [ProviderAccountControls] {
        AccountProvider.allCases.map { ProviderAccountControls(provider: $0, connect: connect) }
    }

    private init(provider: AccountProvider, connect: @escaping Connect) {
        self.provider = provider
        self.connect = connect
        connectLocal = ThemedButton(title: "Connect " + provider.localLabel, target: nil, action: nil)
        status = NSTextField(wrappingLabelWithString: "Use your existing " + provider.title + " CLI sign-in.")
        super.init()
        status.font = Typography.caption
        status.textColor = FeedPalette.muted
        status.isSelectable = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyField.placeholderString = "Enter " + provider.keyLabel
        keyField.setAccessibilityLabel(provider.keyLabel)
        for button in [connectLocal, connectKey, getKey] {
            button.target = self
            button.font = Typography.interface
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        keyField.target = self
        keyField.action = #selector(useAPIKey)
        connectKey.action = #selector(useAPIKey)
        connectLocal.action = #selector(useLocal)
        getKey.action = #selector(openDashboard)
    }

    @objc private func openDashboard() { NSWorkspace.shared.open(provider.dashboard) }
    @objc private func useLocal() { begin(key: nil) }
    @objc private func useAPIKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { keyField.window?.makeFirstResponder(keyField); return }
        keyField.stringValue = ""
        begin(key: key)
    }

    func cancel() { task?.cancel() }

    private func begin(key: String?) {
        guard task == nil else { return }
        connectLocal.isEnabled = false
        connectKey.isEnabled = false
        keyField.isEnabled = false
        status.stringValue = "Connecting…"
        task = Task {
            defer {
                task = nil
                connectLocal.isEnabled = true
                connectKey.isEnabled = true
                keyField.isEnabled = true
                connectKey.title = provider.currentKey == nil ? Copy.connectKey : Copy.updateKey
            }
            do { status.stringValue = try await connect(provider, key) { self.status.stringValue = $0 } }
            catch is CancellationError { status.stringValue = "Connection cancelled." }
            catch { status.stringValue = error.localizedDescription }
        }
    }
}
