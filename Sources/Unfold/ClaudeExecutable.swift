import Foundation

enum ClaudeExecutable {
    private static let preferenceKey = "claudePath"
    private static let desktopInstall = "Library/Application Support/Claude/claude-code"
    private static let bundledCLI = "claude.app/Contents/MacOS/claude"

    @MainActor
    static func resolve() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            UserDefaults.standard.string(forKey: preferenceKey),
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path
        ].compactMap { $0 }
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for path in paths + searchPath.filter({ $0.hasPrefix("/") }).map({ $0 + "/claude" }) {
            let candidate = URL(fileURLWithPath: path)
            if isExecutable(candidate) { return candidate }
        }
        if let installed = desktopCLI(in: home.appendingPathComponent(desktopInstall)) { return installed }
        throw CodexConnection.error("Install Claude Code or open Claude Code in Claude Desktop to connect.")
    }

    // Desktop installs each CLI under a version directory and a build identifier.
    static func desktopCLI(in root: URL) -> URL? {
        func children(of directory: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        let versions = children(of: root).sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
        for version in versions {
            for build in children(of: version).sorted(by: { $0.path < $1.path }) {
                let candidate = build.appendingPathComponent(bundledCLI)
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }
}
