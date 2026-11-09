import Foundation

/// Small, local labels for the overview. Never sends conversation data to a model.
enum FeedSummary {
    static func describe(_ source: String, kind: String, fallback: String) -> (title: String, detail: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(4096))
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let event = lines.first.map(String.init) ?? ""
        var json: NativeJSON?
        if trimmed.utf8.count < 262_144 {
            json = NativeJSON.parse(trimmed)
            if json == nil, lines.count == 2 { json = NativeJSON.parse(String(lines[1])) }
        }
        let message = json?["fields"]?["message"]?.string ?? json?["message"]?.string ?? ""
        let topic = (event + " " + message).lowercased()
        let state = json?["status"]?.string ?? json?["state"]?.string
        if topic.contains("moderation") || json?["category_flags"] != nil { return ("Safety checks", state ?? "Content metadata") }
        if topic.contains("tokenusage") { return ("Token usage", "Context and output") }
        if topic.contains("ratelimits") { return ("Usage limits", "Account capacity") }
        if topic.contains("thread/settings") { return ("Model settings", "Model, reasoning and speed") }
        if topic.contains("remotecontrol") { return ("Connection", state.map { "Remote control · \($0)" } ?? "Remote control") }
        if topic.contains("account/") || topic.contains("credential") || topic.contains("auth_storage") {
            return ("Connection", json?["planType"]?.string ?? json?["authMode"]?.string ?? short(message.isEmpty ? "Account and sign-in" : message))
        }
        if topic.contains("mcpserver") || topic.contains("mcp ") || topic.contains("handshak") || topic.contains("transport") {
            return ("Connection", short(json?["server"]?.string ?? state ?? (message.isEmpty ? "Tool server" : message)))
        }
        if topic.contains("hook/") { return ("Hook", event.contains("completed") ? "Completed" : "Started") }
        let arguments = json?["arguments"].flatMap { $0.string.flatMap(NativeJSON.parse) ?? $0 }
        if let title = arguments?["title"]?.string ?? json?["title"]?.string {
            return (short(title), [state, arguments.map(objectDetail)].compactMap { $0 }.joined(separator: " · "))
        }
        if let tool = json?["tool"]?.string ?? json?["name"]?.string, ["Tool", "JSON"].contains(kind) {
            return (short(tool.replacingOccurrences(of: "_", with: " ")), [state, objectDetail(arguments ?? json)].compactMap { $0 }.joined(separator: " · "))
        }
        if kind == "Command" || kind == "Python" {
            let command = prefix.components(separatedBy: "\n").first(where: { $0.hasPrefix("$ ") }) ?? prefix
            let lower = command.lowercased()
            let lead = lower.replacingOccurrences(of: #"^\$?\s*(?:(?:/\S*/)?(?:zsh|bash|sh)\s+-[a-z]+\s+)?['\"]?"#, with: "", options: .regularExpression)
            let title: String
            if lead.hasPrefix("cat ") || lead.hasPrefix("sed ") || lead.hasPrefix("head ") || lead.hasPrefix("tail ") { title = "Read files" }
            else if lead.range(of: #"^(?:(?:bash|sh)\s+)?(?:[^\s]+/)?build-and-open\.command(?:\s|$)"#, options: .regularExpression) != nil || lead.hasPrefix("swift build") || lead.hasPrefix("xcodebuild") { title = "Build app" }
            else if lower.contains("npm run") && lower.contains("build") { title = "Build project" }
            else if lower.contains("pytest") || lower.contains("swift test") || lower.contains("npm test") { title = "Run tests" }
            else if lower.range(of: #"\b(ps|pgrep|top|lsof)\b"#, options: .regularExpression) != nil { title = "Check running processes" }
            else if lower.contains("codesign") { title = "Sign and verify app" }
            else if lower.contains("git diff") { title = "Review changes" }
            else if lower.contains("git status") { title = "Check changes" }
            else if lower.contains("npm install") || lower.contains("npm ci") { title = "Install dependencies" }
            else if lower.range(of: #"\b(curl|wget)\b"#, options: .regularExpression) != nil { title = "Fetch URL" }
            else if lower.range(of: #"\b(rg|grep|find)\b"#, options: .regularExpression) != nil { title = "Search files" }
            else if lower.range(of: #"\bls\b"#, options: .regularExpression) != nil { title = "List files" }
            else if lower.contains("cat ") || lower.contains("sed ") { title = "Read files" }
            else if kind == "Python" { title = "Python" }
            else { title = "Run command" }
            return (title, short(command.replacingOccurrences(of: "$ ", with: "")))
        }
        if kind == "HTML" {
            return (htmlTitle(prefix) ?? "HTML preview", "Rendered page and source")
        }
        if kind == "JSON" {
            if let type = json?["type"]?.string { return (short(type.replacingOccurrences(of: "_", with: " ")), objectDetail(json)) }
            return ("Structured data", objectDetail(json))
        }
        if kind == "Output" {
            if prefix.contains("Build complete!") { return ("Build complete", short(prefix.components(separatedBy: "\n").first(where: { $0.contains("Build complete!") }) ?? fallback)) }
            return ("Command output", fallback)
        }
        if kind == "Reasoning" { return ("Reasoning", fallback) }
        if kind == "UI tree" { return ("Inspect app", fallback) }
        if kind == "Code" { return codeDescription(source, language: "Code") }
        if kind == "Changes" {
            let rows = source.components(separatedBy: .newlines)
            let added = rows.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            let removed = rows.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
            let path = rows.first { $0.hasPrefix("+++ ") }.map { String($0.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored) }
                ?? rows.first(where: { !$0.isEmpty && !$0.hasPrefix("diff ") && !$0.hasPrefix("@@") }) ?? "File changes"
            let name = (path as NSString).lastPathComponent
            let sample = added.first(where: { !$0.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty }).map { short(String($0.dropFirst())) }
            return (name, "\(added.count) added · \(removed.count) removed" + (sample.map { "\nAdded: \($0)" } ?? "\nUpdated file contents"))
        }
        if kind == "You" { return ("Your request", fallback) }
        if kind == "Image" { return ("Image", "Preview") }
        if kind == "Reply" {
            let sentence = short(prefix.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? fallback)
            let detail = short(String(prefix.dropFirst(prefix.components(separatedBy: .newlines).first?.count ?? 0)))
            return (sentence, detail.isEmpty ? "Assistant update" : detail)
        }
        if kind == "Session", prefix.hasPrefix("Command status:") { return (prefix.contains("exit 0") ? "Command finished" : "Command status", fallback) }
        return (kind == "Session" ? "Session update" : kind, fallback)
    }
    static func objectDetail(_ json: NativeJSON?) -> String {
        guard let json else { return "Full data" }
        switch json {
        case .object(let fields):
            let names = fields.map(\.0).filter { !["id", "threadId", "turnId", "_meta", "title"].contains($0) }
            let values = fields.filter { names.contains($0.0) }.prefix(3).map { key, value in
                let description: String
                switch value {
                case .string(let text): description = short(text)
                case .number(let number): description = number
                case .boolean(let flag): description = flag ? "yes" : "no"
                case .array(let items): description = "\(items.count) items"
                case .object(let fields): description = "\(fields.count) fields"
                case .null: description = "none"
                }
                return "\(key): \(description)"
            }
            return values.isEmpty ? "Empty object" : values.joined(separator: " · ")
        case .array(let items): return "\(items.count) items in this collection. Open to inspect their values."
        default: return "Value"
        }
    }
    static func codeDescription(_ source: String, language: String) -> (title: String, detail: String) {
        let lines = source.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let declaration = lines.first { $0.range(of: #"\b(?:class|struct|enum|func|def|function|interface|type|const|let)\s+\w+"#, options: .regularExpression) != nil }
        let title = declaration.map(short) ?? (language.isEmpty ? "Code block" : "\(language.uppercased()) code")
        let comment = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }
        let explanation = comment.map { short($0.trimmingCharacters(in: CharacterSet(charactersIn: " /#"))) }
        return (title, "\(lines.count) lines of \(language.isEmpty ? "code" : language)" + (explanation.map { ". \($0)" } ?? ". Open to inspect the implementation."))
    }
    private static func short(_ source: String) -> String {
        let clean = source.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(100))
    }
    private static func htmlTitle(_ source: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"<(?:title|h1)(?:\s[^>]*)?>([^<]+)</(?:title|h1)>"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return short(String(source[range]))
    }
}
