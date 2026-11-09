import Foundation

enum ChatTabTitle {
    /// Hide provider decorations without removing references to Codex in the conversation itself.
    /// Apply at display time so restored, imported, and prompt-generated titles behave alike.
    static func display(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"(?i)^codex\s*(?:[·•|:–—]|\s-\s)\s*"#
        let suffix = #"(?i)\s*(?:[·•|–—]|\s-\s)\s*codex$"#
        while true {
            let previous = result
            result = result.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
                .replacingOccurrences(of: suffix, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result == previous { break }
        }
        return result.isEmpty || result.caseInsensitiveCompare("Codex") == .orderedSame ? "New chat" : result
    }
}
