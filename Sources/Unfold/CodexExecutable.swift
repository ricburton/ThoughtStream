import AppKit

@MainActor
enum CodexExecutable {
    private static let preferenceKey = "codexPath"
    private static let desktopBundle = "ChatGPT.app"
    private static let desktopCLI = "Contents/Resources/codex-cli/bin/codex"

    static func resolve(allowPrompt: Bool = true) throws -> URL {
        let files = FileManager.default
        let paths: [String?] = [
            UserDefaults.standard.string(forKey: preferenceKey),
            Bundle.main.resourceURL?.appendingPathComponent("codex/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/Applications/" + desktopBundle,
            files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/" + desktopBundle).path
        ]
        func executable(at path: String) -> URL? {
            var url = URL(fileURLWithPath: path)
            if url.pathExtension.lowercased() == "app" {
                url.appendPathComponent(desktopCLI)
            }
            let resolved = url.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  files.isExecutableFile(atPath: resolved.path) else { return nil }
            return url
        }
        for path in paths.compactMap({ $0 }) {
            if let url = executable(at: path) { return url }
        }
        guard allowPrompt else { throw CodexConnection.error("Install Codex to find previous conversations.") }
        let panel = NSOpenPanel()
        panel.title = "Select Codex"
        panel.message = "Choose the codex executable or the ChatGPT app that contains it."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url else {
            throw CodexConnection.error("No Codex executable selected.")
        }
        guard let url = executable(at: selected.path) else {
            throw CodexConnection.error("This selection does not contain an executable Codex CLI.")
        }
        UserDefaults.standard.set(url.path, forKey: preferenceKey)
        return url
    }
}
