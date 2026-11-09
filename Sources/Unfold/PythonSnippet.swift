import Foundation

struct PythonSnippet: Codable, Equatable, Sendable {
    let source: String
    let origin: String
}

/// Parses literal shell syntax only. No expansion, execution, or file reads.
enum PythonSnippetExtractor {
    static func extract(from command: String, depth: Int = 0) -> [PythonSnippet] {
        guard depth < 4 else { return [] }
        var text = command.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        if let prompt = lines.prefix(2).firstIndex(where: { $0.hasPrefix("$ ") }) {
            text = ([String(lines[prompt].dropFirst(2))] + Array(lines.dropFirst(prompt + 1))).joined(separator: "\n")
        }
        let words = tokens(text)
        if let first = words.first, ["sh", "bash", "zsh"].contains(URL(fileURLWithPath: first).lastPathComponent),
           let flag = words.indices.dropFirst().first(where: { words[$0].hasPrefix("-") && words[$0].dropFirst().contains("c") }), flag + 1 < words.count {
            return extract(from: words[flag + 1], depth: depth + 1)
        }
        var snippets: [PythonSnippet] = []
        let rows = text.components(separatedBy: "\n")
        var row = 0
        while row < rows.count {
            let header = tokens(rows[row])
            for op in header.indices where header[op] == "<<" || header[op] == "<<-" {
                guard op + 1 < header.count else { continue }
                let start = (header[..<op].lastIndex(where: { [";", "&&", "||", "|"].contains($0) }).map { $0 + 1 }) ?? 0
                let invocation = Array(header[start..<op])
                let delimiter = header[op + 1], stripTabs = header[op] == "<<-"
                var end = row + 1
                while end < rows.count {
                    let candidate = stripTabs ? String(rows[end].drop(while: { $0 == "\t" })) : rows[end]
                    if candidate == delimiter { break }; end += 1
                }
                // An incomplete streamed heredoc is not linted as if it were complete.
                guard end < rows.count else { continue }
                let body = rows[(row + 1)..<end].map { stripTabs ? String($0.drop(while: { $0 == "\t" })) : $0 }.joined(separator: "\n")
                if pythonInvocation(invocation) { snippets.append(PythonSnippet(source: body + "\n", origin: "Python heredoc")) }
                row = end; break
            }
            let inline = tokens(rows[row])
            if pythonInvocation(inline), let flag = inline.firstIndex(of: "-c"), flag + 1 < inline.count {
                snippets.append(PythonSnippet(source: inline[flag + 1], origin: "Python -c"))
            }
            row += 1
        }
        // A literal multi-line -c argument is tokenized across lines as one argument.
        if snippets.isEmpty, pythonInvocation(words), let flag = words.firstIndex(of: "-c"), flag + 1 < words.count {
            return [PythonSnippet(source: words[flag + 1], origin: "Python -c")]
        }
        return snippets
    }

    private static func pythonInvocation(_ words: [String]) -> Bool {
        guard let python = words.firstIndex(where: {
            URL(fileURLWithPath: $0).lastPathComponent.range(of: "^(?:python(?:[0-9]+(?:\\.[0-9]+)*)?|pypy[0-9]*)$", options: .regularExpression) != nil
        }) else { return false }
        let prefix = Array(words[..<python])
        return prefix.isEmpty || prefix.allSatisfy { $0 == "env" || $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil } || prefix == ["uv", "run"]
    }

    static func tokens(_ source: String) -> [String] {
        let chars = Array(source); var result: [String] = [], value = "", index = 0, quote: Character?
        var hasValue = false
        func flush() { if hasValue { result.append(value) }; value = ""; hasValue = false }
        while index < chars.count {
            let char = chars[index]
            if let active = quote {
                if char == active { quote = nil }
                else if char == "\\" && active == "\"" && index + 1 < chars.count && ["$", "`", "\"", "\\", "\n"].contains(chars[index + 1]) {
                    index += 1; if chars[index] != "\n" { value.append(chars[index]) }
                } else { value.append(char) }
                index += 1; continue
            }
            if char == "'" || char == "\"" { quote = char; hasValue = true; index += 1; continue }
            if char == "\\" && index + 1 < chars.count { index += 1; if chars[index] != "\n" { value.append(chars[index]); hasValue = true }; index += 1; continue }
            if char.isWhitespace { flush(); index += 1; continue }
            if ["<", ";", "|", "&", ">"].contains(char) {
                flush(); var op = String(char)
                if index + 1 < chars.count && chars[index + 1] == char { op.append(char); index += 1 }
                if op == "<<", index + 1 < chars.count && chars[index + 1] == "-" { op += "-"; index += 1 }
                result.append(op); index += 1; continue
            }
            value.append(char); hasValue = true; index += 1
        }
        // Unterminated quoting means this is still streaming or ambiguous shell syntax.
        if quote != nil { return [] }
        flush(); return result
    }
}
