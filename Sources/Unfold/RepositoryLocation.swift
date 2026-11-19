import Foundation

/// The checked-out branch and, for a linked worktree, its name. Read straight
/// from `.git` metadata so no `git` process (or Command Line Tools prompt) runs.
struct RepositoryLocation: Equatable, Sendable {
    /// Branch name, or a short commit hash when HEAD is detached.
    var branch: String
    var isDetached: Bool
    /// Set when the folder is a linked worktree rather than the main checkout.
    var worktree: String?
    var root: URL
    /// The repository's shared git directory; every worktree of it has the same one.
    var common: URL

    var summary: String {
        let head = isDetached ? "detached at \(branch)" : branch
        return worktree.map { "\(head) · worktree \($0)" } ?? head
    }

    static func read(_ directory: URL) -> RepositoryLocation? {
        let files = FileManager.default
        var folder = directory.standardizedFileURL
        while true {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? location(gitDirectory: dotGit, root: folder, worktree: nil, common: dotGit)
                    : linked(pointer: dotGit, root: folder)
            }
            // At the root, some URLs answer "/.." instead of "/", and the walk
            // would climb forever. Stop there, and whenever a step fails to shorten the path.
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if folder.path == "/" || parent.path == folder.path || parent.path.count >= folder.path.count { return nil }
            folder = parent
        }
    }

    /// A `.git` file points at the real git directory: `gitdir: <path>`.
    private static func linked(pointer: URL, root: URL) -> RepositoryLocation? {
        guard let text = try? String(contentsOf: pointer, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
        // Linked worktrees live in <common>/worktrees/<name>; submodules in <common>/modules/<name>.
        let isWorktree = gitDirectory.deletingLastPathComponent().lastPathComponent == "worktrees"
        let common = isWorktree ? gitDirectory.deletingLastPathComponent().deletingLastPathComponent() : gitDirectory
        return location(gitDirectory: gitDirectory, root: root, worktree: isWorktree ? root.lastPathComponent : nil, common: common)
    }

    private static func location(gitDirectory: URL, root: URL, worktree: String?, common: URL) -> RepositoryLocation? {
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return RepositoryLocation(branch: branch, isDetached: false, worktree: worktree, root: root, common: common)
        }
        return RepositoryLocation(branch: String(head.prefix(7)), isDetached: true, worktree: worktree, root: root, common: common)
    }

    /// Every checkout of the repository: the main one plus its linked worktrees.
    static func checkouts(sharing common: URL) -> [URL] {
        var roots: [URL] = common.lastPathComponent == ".git" ? [common.deletingLastPathComponent()] : []
        let registry = common.appendingPathComponent("worktrees")
        for entry in (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [] {
            // Each entry's `gitdir` file holds the path of that worktree's `.git` file.
            guard let pointer = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), pointer.hasPrefix("/") else { continue }
            roots.append(URL(fileURLWithPath: pointer).deletingLastPathComponent())
        }
        return roots
    }

    /// The checkout the agent last worked in. An agent can stay in the chat's
    /// folder while it commits to another worktree (`git -C …`, absolute file
    /// paths), so recent activity decides; the chat's folder is the fallback.
    /// `activity` is newest first.
    static func active(project: URL, activity: [String]) -> RepositoryLocation? {
        guard let home = read(project) else { return nil }
        var roots: [(path: String, root: URL)] = []
        for root in checkouts(sharing: home.common) {
            for path in Set([root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]) { roots.append((path, root)) }
        }
        guard roots.count > 1 else { return home }
        for text in activity {
            let source = text.replacingOccurrences(of: "\\/", with: "/")
            // The earliest mention wins; at one position the longest root does,
            // so a worktree nested inside the main checkout is not read as main.
            var best: (at: String.Index, length: Int, root: URL)?
            for candidate in roots {
                var search = source.startIndex..<source.endIndex
                while let found = source.range(of: candidate.path, range: search) {
                    search = found.upperBound..<source.endIndex
                    if let next = source[found.upperBound...].first, next.isLetter || next.isNumber || "._-".contains(next) { continue }
                    if best == nil || found.lowerBound < best!.at || (found.lowerBound == best!.at && candidate.path.count > best!.length) {
                        best = (found.lowerBound, candidate.path.count, candidate.root)
                    }
                    break
                }
            }
            if let best { return read(best.root) ?? home }
        }
        return home
    }

    /// The text worth scanning for folders: recent commands, edits and tool
    /// calls, newest first. Output is left out; listings name every checkout.
    static func activity(in records: [StreamRecord], limit: Int = 30) -> [String] {
        let kinds: Set<String> = [StreamKind.command.rawValue, StreamKind.change.rawValue, StreamKind.tool.rawValue]
        var texts: [String] = []
        for record in records.reversed() where kinds.contains(record.kind) {
            texts.append(String(record.text.prefix(6_000)))
            if texts.count == limit { break }
        }
        return texts
    }
}
