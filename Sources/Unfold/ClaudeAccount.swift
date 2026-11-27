import AppKit

extension ClaudeConnection {
    static var sessionAPIKey: String?
    nonisolated static let apiKeyVariable = "ANTHROPIC_API_KEY"
    private nonisolated static let baseURLVariable = "ANTHROPIC_BASE_URL"
    private nonisolated static let apiOrigin = "https://api.anthropic.com"
    private static let modelsURL = URL(string: apiOrigin + "/v1/models?limit=1")!
    private static let apiVersion = "2023-06-01"
    private static let authorizationHeader = "x-api-key"
    private static let versionHeader = "anthropic-version"
    private static let localSignInAttempts = 150
    private static let localSignInInterval = Duration.seconds(2)
    private nonisolated static let competingCredentials = [
        "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"
    ]

    static func isAuthenticated() async throws -> Bool {
        if sessionAPIKey != nil { return true }
        return try await hasLocalSignIn(executable: executable())
    }

    private static func hasLocalSignIn(executable: URL) async throws -> Bool {
        return try await Task.detached {
            let task = Process(), output = Pipe()
            task.executableURL = executable; task.arguments = ["auth", "status"]
            task.standardOutput = output; task.standardError = FileHandle.nullDevice
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return value?["loggedIn"] as? Bool == true
        }.value
    }

    static func ensureLocalSignIn(executable: URL, status: (String) -> Void) async throws {
        if try await hasLocalSignIn(executable: executable) { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("thoughtstream-claude-\(UUID().uuidString).command")
        try ClaudeConnection.signInScript(executable: executable).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        status("Finish signing in in Terminal and your browser.")
        for _ in 0..<localSignInAttempts {
            try await Task.sleep(for: localSignInInterval)
            try Task.checkCancellation()
            if try await hasLocalSignIn(executable: executable) { return }
        }
        throw CodexConnection.error("Sign-in is still pending. Finish in Terminal, then connect again.")
    }

    nonisolated static func environment(for apiKey: String?, inheriting base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "CLAUDECODE")
        if let apiKey {
            for variable in competingCredentials { environment.removeValue(forKey: variable) }
            environment[baseURLVariable] = apiOrigin
            environment[apiKeyVariable] = apiKey
        }
        return environment
    }

    static func checkAPIKey(_ key: String, configuration: URLSessionConfiguration = .ephemeral) async throws {
        var request = URLRequest(url: modelsURL, timeoutInterval: 15)
        request.setValue(key, forHTTPHeaderField: authorizationHeader)
        request.setValue(apiVersion, forHTTPHeaderField: versionHeader)
        let session = URLSession(configuration: configuration, delegate: RejectCredentialRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexConnection.error("No response from Anthropic.") }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw CodexConnection.error("Anthropic rejected this API key. Check the key and its permissions.")
        default: throw CodexConnection.error("Anthropic key check returned HTTP " + String(http.statusCode) + ".")
        }
    }

    /// Launch the official interactive sign-in, preserving a custom account
    /// directory. Quote paths as shell data, including apostrophes and spaces.
    static func signInScript(executable: URL, configDirectory: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/zsh\nunset CLAUDECODE\n"
        if let configDirectory { script += "export CLAUDE_CONFIG_DIR=\(quote(configDirectory))\n" }
        script += "exec \(quote(executable.path)) auth login --claudeai\n"
        return script
    }
}

private final class RejectCredentialRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
