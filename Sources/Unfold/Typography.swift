import AppKit

enum Typography {
    // SF Pro keeps native controls and custom-drawn content on the same scale.
    static let interface = NSFont.systemFont(ofSize: 13)
    static let interfaceEmphasis = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let section = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let caption = NSFont.systemFont(ofSize: 12)
    static let metadata = NSFont.systemFont(ofSize: 11)
    static let badge = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let counter = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let timestamp = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let pageTitle = NSFont.systemFont(ofSize: 20, weight: .semibold)
    static let welcomeTitle = NSFont.systemFont(ofSize: 28, weight: .semibold)
    static let conversation = NSFont.systemFont(ofSize: 15)

    /// Supporting copy needs the same leading in settings, empty states and
    /// overview cards. Native labels still determine their own wrapping height.
    static func wrappingText(_ string: String, font: NSFont, color: NSColor,
                             alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(font.pointSize * 1.4)
        paragraph.alignment = alignment
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    static func render(_ record: StreamRecord, size: CGFloat) -> NSAttributedString {
        let kind = StreamKind(rawValue: record.kind) ?? .system
        let code = [.command, .code, .output, .change, .tool].contains(kind)
        let color: NSColor
        switch kind {
        case .reasoning: color = .systemPurple
        case .command: color = .systemGreen
        case .change: color = .systemTeal
        case .error: color = .systemRed
        case .compaction: color = .systemOrange
        default: color = .secondaryLabelColor
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = code ? 4 : 7; paragraph.paragraphSpacing = 13
        let heading = "\(record.kind.uppercased())  \(record.language.map { "· \($0)  " } ?? "")\(record.time.formatted(date: .omitted, time: .standard))\n"
        let result = NSMutableAttributedString(string: heading, attributes: [.font: NSFont.monospacedSystemFont(ofSize: max(10, size - 4), weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
        let body = NSMutableAttributedString(string: record.text + "\n\n", attributes: [.font: code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: kind == .error ? NSColor.systemRed : NSColor.labelColor, .paragraphStyle: paragraph])
        if code { highlight(body, language: record.language ?? (kind == .command ? "bash" : "text")) }
        else { highlightFences(body, size: size) }
        result.append(body); return result
    }

    static func highlightFences(_ text: NSMutableAttributedString, size: CGFloat) {
        let source = text.string as NSString
        let re = try? NSRegularExpression(pattern: "```([A-Za-z0-9_-]*)\\n([\\s\\S]*?)(?:```|$)")
        for match in re?.matches(in: text.string, range: NSRange(location: 0, length: source.length)) ?? [] {
            let range = match.range(at: 2), language = source.substring(with: match.range(at: 1))
            text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15)], range: range)
            let code = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range)); highlight(code, language: language); text.replaceCharacters(in: range, with: code)
        }
    }

    static func highlight(_ text: NSMutableAttributedString, language: String) {
        let lang = language.lowercased()
        let keywords: String
        switch lang {
        case "py", "python": keywords = "def|class|return|if|elif|else|for|while|in|is|not|and|or|import|from|as|with|try|except|raise|yield|lambda|async|await|None|True|False|pass"
        case "js", "javascript", "ts", "typescript": keywords = "const|let|var|function|return|if|else|for|while|of|in|class|new|import|export|from|async|await|throw|try|catch|true|false|null|undefined|interface|type|extends"
        case "sh", "shell", "bash", "zsh": keywords = "if|then|else|elif|fi|for|do|done|case|esac|function|export|local|readonly|return|exit|set|source"
        case "swift": keywords = "let|var|func|class|struct|enum|protocol|extension|import|return|if|else|guard|for|in|while|async|await|throws|try|catch|private|public|final|nil|true|false|self"
        case "diff":
            apply(text, pattern: "(?m)^\\+.*$", color: .systemGreen); apply(text, pattern: "(?m)^-.*$", color: .systemRed); return
        default: return
        }
        apply(text, pattern: "\\b(?:" + keywords + ")\\b", color: .systemPurple)
        apply(text, pattern: "\\b[0-9]+(?:\\.[0-9]+)?\\b", color: .systemOrange)
        if ["sh", "shell", "bash", "zsh"].contains(lang) { apply(text, pattern: "\\$[A-Za-z_][A-Za-z0-9_]*|\\$\\{[^}]*\\}", color: .systemTeal) }
        apply(text, pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'", color: .systemGreen)
        apply(text, pattern: ["py", "python", "sh", "shell", "bash", "zsh"].contains(lang) ? "(?m)#.*$" : "(?m)//.*$|/\\*[\\s\\S]*?\\*/", color: .secondaryLabelColor)
    }
    private static func apply(_ text: NSMutableAttributedString, pattern: String, color: NSColor) {
        let re = try? NSRegularExpression(pattern: pattern)
        for match in re?.matches(in: text.string, range: NSRange(location: 0, length: (text.string as NSString).length)) ?? [] { text.addAttribute(.foregroundColor, value: color, range: match.range) }
    }
}
