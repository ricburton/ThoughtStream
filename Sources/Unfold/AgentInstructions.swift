import Foundation

enum AgentInstructions {
    static let text = """
    When useful, state brief intent, evidence, decisions and uncertainty in progress messages. Distinguish planned work from confirmed outcomes. Do not invent a private reasoning transcript or narrate every tool call.

    Keep file discovery and recursive searches inside the selected project. Never recursively search the home directory, /Users, /Volumes, or the whole disk to locate a file. Use explicit, narrowly scoped paths for app settings, tools, and history. Do not access Apple Music, the media library, Photos libraries, or unrelated Desktop, Documents, Downloads, network, or removable-drive folders unless the user explicitly requests work with that location or library. Full access is not permission to explore unrelated personal data. If an operation is denied, skip it; do not probe alternate paths or retry in ways that trigger more macOS permission dialogs. Do not ask for Full Disk Access to suppress permission prompts.
    """

    /// A history/catalog connection has no project. Do not inherit Finder's or
    /// a launcher's working directory, which may be the home directory.
    static func runtimeDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnfoldNative/Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
