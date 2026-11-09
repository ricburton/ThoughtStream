import AppKit

/// Project membership is independent of a thread's working directory.
@MainActor
enum CodexProjects {
    struct Project {
        let id: String
        let name: String
        let roots: [String]
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func matching(_ folder: URL, in projects: [Project]) -> Project? {
        let path = canonicalPath(folder.path)
        let candidates = projects.compactMap { project -> (Project, Int)? in
            let lengths = project.roots.map(canonicalPath).filter {
                path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/")
            }.map(\.count)
            return lengths.max().map { (project, $0) }
        }
        guard let longest = candidates.map({ $0.1 }).max() else { return nil }
        let matches = candidates.filter { $0.1 == longest }
        return matches.count == 1 ? matches[0].0 : nil
    }

    static func resolve(_ folder: URL, using client: CodexConnection) async throws -> String {
        var projects: [Project] = [], cursor: String?, seen = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await client.request("project/list", params)
            guard let rows = result["data"] as? [[String: Any]] else {
                throw CodexConnection.error("Could not load ChatGPT projects. Your message has not been sent.")
            }
            projects += rows.compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                let roots = (row["roots"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                return Project(id: id, name: name, roots: roots)
            }
            cursor = result["nextCursor"] as? String
            if let next = cursor, !seen.insert(next).inserted {
                throw CodexConnection.error("ChatGPT returned a repeated project page. Your message has not been sent.")
            }
        } while cursor != nil

        let key = "chatGPTProjectBindings"
        let path = canonicalPath(folder.path)
        var bindings = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let saved = bindings[path], projects.contains(where: { $0.id == saved }) { return saved }
        if let match = matching(folder, in: projects) { return match.id }

        // A folder name alone cannot establish identity. Ask once when a folder
        // has no unique saved root (including two different PodWallet folders).
        let alert = NSAlert()
        alert.messageText = "Choose a ChatGPT project"
        alert.informativeText = "Choose where chats from this folder should appear. This choice is remembered.\n\n\(folder.path)"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let ordered = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        picker.addItem(withTitle: "Create project: \(folder.lastPathComponent)")
        for project in ordered {
            picker.addItem(withTitle: "\(project.name) — \(project.roots.first ?? "No folder")")
        }
        let sameName = ordered.enumerated().filter { $0.element.name == folder.lastPathComponent }
        if sameName.count == 1 { picker.selectItem(at: sameName[0].offset + 1) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Use project")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CodexConnection.error("Project selection cancelled. Your message has not been sent.")
        }
        let id: String
        if picker.indexOfSelectedItem > 0 {
            id = ordered[picker.indexOfSelectedItem - 1].id
        } else {
            let result = try await client.request("project/create", [
                "name": folder.lastPathComponent, "roots": [["path": path]],
                "idempotencyKey": UUID().uuidString
            ])
            guard let created = (result["project"] as? [String: Any])?["id"] as? String else {
                throw CodexConnection.error("ChatGPT did not return a project ID. Your message has not been sent.")
            }
            id = created
        }
        bindings[path] = id
        UserDefaults.standard.set(bindings, forKey: key)
        return id
    }
}
