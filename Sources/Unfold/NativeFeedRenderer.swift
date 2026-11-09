import AppKit

enum NativeFeedBlock {
    case header(String, String, NativeTextTone, CGFloat, rawSource: String? = nil)
    case text(NSAttributedString)
    case prose(NSAttributedString, NativeTextTone)
    case code(NSAttributedString, source: String, label: String)
    case image(NativeImageReference)
    case html(String)
}

/// Produces native attributed text and native media blocks; no HTML conversion.
@MainActor
struct NativeFeedRenderer {
    let size: CGFloat
    let analyses: [String: PythonAnalysis]
    var requestedCode: [CodeAnalysisRequest] = []
    private(set) var blocks: [NativeFeedBlock] = []
    private var buffer = NSMutableAttributedString(string: "")
    private var tone = NativeTextTone.plain
    private var jsonSource: String?
    private var font: NSFont { Typography.prose(ofSize: size) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: max(8, size - (tone == .muted ? 4 : 2)), weight: .regular) }
    private let purple = FeedPalette.purple
    private let blue = FeedPalette.blue
    private let green = FeedPalette.green
    init(size: CGFloat, analyses: [String: PythonAnalysis]) { self.size = size; self.analyses = analyses }

    mutating func render(_ record: StreamRecord) -> [NativeFeedBlock] {
        renderContent(record)
        trimPresentation()
        return blocks
    }

    private mutating func renderContent(_ record: StreamRecord) {
        tone = record.kind == "Reasoning summary" ? .reasoning : record.kind == "You" ? .user : record.kind == "Error" ? .error : record.kind == "Session" ? .muted : .plain
        let time = Self.clock.string(from: record.time)
        blocks.append(.header(record.queuedStatus != nil ? "Queued Chat" : record.kind == "Agent" ? "Assistant" : record.kind, time, ["Command", "Code", "File change"].contains(record.kind) ? .command : tone, size))
        if record.isFinalResponse == true {
            markdown(record.text); flush(); return
        }
        let snippets = record.python ?? (record.kind == "Command" ? PythonSnippetExtractor.extract(from: record.text) : [])
        if !snippets.isEmpty { for snippet in snippets { code(snippet.source, language: "python") }; return }
        if let image = NativeImageReference.detect(record.text) { blocks.append(.image(image)); return }
        let raw = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = NativeJSON.parseEmbedded(raw) { renderJSON(json, source: raw); return }
        if let newline = raw.firstIndex(of: "\n"), let json = NativeJSON.parseEmbedded(String(raw[raw.index(after: newline)...])) {
            text(String(raw[..<newline]) + "\n", font: mono, color: FeedPalette.muted); flush(); renderJSON(json, source: String(raw[raw.index(after: newline)...])); return
        }
        if isHTML(raw) { html(raw); return }
        if ["Command", "Output", "File change", "Code"].contains(record.kind) {
            code(record.text, language: record.language ?? (record.kind == "Command" ? "shell" : record.kind == "File change" ? "diff" : "text")); return
        }
        markdown(record.text); flush()
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let lineEndSpaces = try! NSRegularExpression(pattern: #"[\t\p{Zs}]+$"#, options: .anchorsMatchLines)
    private static let lineStartSpaces = try! NSRegularExpression(pattern: #"^[\t\p{Zs}]+"#, options: .anchorsMatchLines)
    private static let terminalFormatting = try! NSRegularExpression(pattern: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#)
    // Rendering runs for the live row on every streaming flush. Compile each
    // pattern once instead of once per line.
    private static let htmlStart = try! NSRegularExpression(pattern: #"^\s*(?:<!doctype\s+html|<(?:html|head|body|main|article|section|div|style|table|svg|form|h[1-6]|p)(?:\s|>))"#, options: .caseInsensitive)
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#)
    private static let tableDivider = try! NSRegularExpression(pattern: #"^\|?\s*:?-{3,}"#)
    private static let listPattern = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]\s+|\d+\.\s+)(.*)$"#)
    private static let inlinePattern = try! NSRegularExpression(pattern: #"`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*\n]+\*|_[^_\n]+_|\[[^\]]+\]\([^)]+\)"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
    private static let codeTokens = try! NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b(?:true|false|null|const|let|var|function|return|if|else|for|in|of|class|import|from|export|async|await|def|print|struct|func|guard|nil|try|throw|as|with|None|True|False)\b)|(\b\d+(?:\.\d+)?\b)|(//[^\n]*|#[^\n]*)"#)
    private struct ParagraphKey: Hashable { let indent, spacing, lineHeight, tab: CGFloat; let code: Bool }
    private static var paragraphs: [ParagraphKey: NSParagraphStyle] = [:]

    /// Presentation only: preserve leading indentation, internal blank lines,
    /// and the original source carried by code cards and stored records.
    private static func trimmedText(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        // Terminal reset/erase sequences after a blank line must not keep that
        // line alive. Only the displayed text changes; copySource stays intact.
        if result.string.contains("\u{1B}") {
            let controls = terminalFormatting.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            for match in controls.reversed() { result.deleteCharacters(in: match.range) }
        }
        let matches = lineEndSpaces.matches(in: result.string, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() { result.deleteCharacters(in: match.range) }
        let leadingLines = result.string.prefix { $0.isNewline }.utf16.count
        if leadingLines > 0 { result.deleteCharacters(in: NSRange(location: 0, length: leadingLines)) }
        let last = (result.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        let end = last.location == NSNotFound ? 0 : NSMaxRange(last)
        if end < result.length { result.deleteCharacters(in: NSRange(location: end, length: result.length - end)) }
        return result
    }

    private mutating func trimPresentation() {
        blocks = blocks.compactMap { block in
            switch block {
            case .text(let text):
                let cleaned = Self.trimmedText(text)
                return cleaned.length == 0 ? nil : .text(cleaned)
            case .prose(let text, let tone):
                let cleaned = Self.trimmedText(text)
                return cleaned.length == 0 ? nil : .prose(cleaned, tone)
            case .code(let text, let source, let label):
                if label == "Diff" { return block }
                let cleaned = Self.trimmedText(text)
                return cleaned.length == 0 ? nil : .code(cleaned, source: source, label: label)
            default: return block
            }
        }
    }
    private func paragraph(indent: CGFloat = 0, spacing: CGFloat = 0, code: Bool = false, font: NSFont? = nil) -> NSParagraphStyle {
        let lineHeight = (font?.pointSize ?? size) * (code ? 1.5 : 1.6)
        let key = ParagraphKey(indent: indent, spacing: spacing, lineHeight: lineHeight, tab: size * 9, code: code)
        if let cached = Self.paragraphs[key] { return cached }
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = spacing
        p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight
        p.headIndent = indent; p.firstLineHeadIndent = indent
        p.lineBreakMode = code ? .byCharWrapping : .byWordWrapping
        p.tabStops = []; p.defaultTabInterval = key.tab
        let style = p.copy() as! NSParagraphStyle
        Self.paragraphs[key] = style
        return style
    }
    private mutating func text(_ value: String, font: NSFont? = nil, color: NSColor? = nil, indent: CGFloat = 0) {
        let chosen = font ?? (tone == .muted ? Typography.prose(ofSize: max(8, size * 0.82)) : self.font)
        let ink = color ?? (tone == .error ? FeedPalette.red : tone == .muted ? FeedPalette.muted : FeedPalette.text)
        buffer.append(NSAttributedString(string: value, attributes: [.font: chosen, .foregroundColor: ink, .paragraphStyle: paragraph(indent: indent, code: chosen.isFixedPitch && !InterfaceStyle.isMatrix, font: chosen)]))
    }
    private mutating func flush() {
        if buffer.length > 0 {
            let value = NSAttributedString(attributedString: buffer)
            if let jsonSource {
                let styled = NSMutableAttributedString(attributedString: value)
                styled.addAttribute(.nativeJSON, value: true, range: NSRange(location: 0, length: styled.length))
                blocks.append(.code(styled, source: jsonSource, label: "JSON"))
            }
            else if tone == .user || tone == .reasoning { blocks.append(.prose(value, tone)) }
            else { blocks.append(.text(value)) }
            buffer = NSMutableAttributedString(string: "")
        }
    }
    private func isHTML(_ source: String) -> Bool {
        firstMatch(Self.htmlStart, source) != nil
    }

    private mutating func renderJSON(_ value: NativeJSON, source: String) {
        if NativeImageReference.containsImage(value),
           case .header(let title, let time, let tone, let size, _) = blocks.first {
            blocks[0] = .header(title, time, tone, size, rawSource: source)
        }
        guard let parts = ToolPayload.unwrap(value) else {
            jsonSource = source; jsonValue(value); flush(); jsonSource = nil; return
        }
        if case .header(let title, let time, let tone, let size, _) = blocks.first {
            blocks[0] = .header(title, time, tone, size, rawSource: source)
        }
        for part in parts {
            switch part {
            case .image(let image): flush(); blocks.append(.image(image))
            case .caption(let caption):
                flush(); text(caption + "\n", font: Typography.prose(ofSize: max(8, size * 0.75), weight: .semibold), color: FeedPalette.muted); flush()
            case .json(let json):
                jsonSource = source; jsonValue(json); flush(); jsonSource = nil
            case .text(let text):
                if NativeDiff.recognizes(text, language: "") {
                    code(text, language: "diff")
                } else if ToolPayload.isUITree(text) {
                    code(text, language: "UI tree")
                } else if isHTML(text) { html(text) }
                else { markdown(text); flush() }
            }
        }
    }

    private mutating func jsonValue(_ value: NativeJSON, depth: Int = 0, key: String? = nil, comma: Bool = false) {
        if var image = NativeImageReference.detect(value) {
            if let key { image.title = key }
            flush(); blocks.append(.image(image)); return
        }
        if depth < 16, let source = value.string,
           let nested = NativeJSON.parseEmbedded(source), nested.string == nil,
           NativeImageReference.containsImage(nested) {
            jsonValue(nested, depth: depth + 1, key: key, comma: comma); return
        }
        if let source = value.string, isHTML(source) {
            flush(); let original = jsonSource; jsonSource = nil; html(source); jsonSource = original; return
        }
        let indent = String(repeating: "  ", count: min(depth, 24))
        text(indent, font: mono)
        if let key { text(NativeJSON.quoted(key), font: mono, color: FeedPalette.jsonKey); text(": ", font: mono, color: FeedPalette.muted) }
        switch value {
        case .object(let fields):
            let flat = fields.count > 1 && fields.allSatisfy { $0.0.count <= 40 && ($0.1.scalar?.count ?? 999) <= 34 && !($0.1.string?.contains("\n") ?? false) }
            if fields.isEmpty { text("{}", font: mono, color: .secondaryLabelColor) }
            else if flat {
                text("{ ", font: mono, color: .secondaryLabelColor)
                for (index, field) in fields.enumerated() {
                    text(NativeJSON.quoted(field.0) + ": ", font: mono, color: FeedPalette.jsonKey)
                    scalar(field.1)
                    if index < fields.count - 1 { text(",  ", font: mono, color: .secondaryLabelColor) }
                }
                text(" }", font: mono, color: .secondaryLabelColor)
            } else {
                text("{", font: mono, color: .secondaryLabelColor); jsonCount(fields.count, noun: "fields"); text("\n", font: mono)
                for (index, field) in fields.enumerated() { jsonValue(field.1, depth: depth + 1, key: field.0, comma: index < fields.count - 1) }
                text(indent + "}", font: mono, color: .secondaryLabelColor)
            }
        case .array(let items):
            if items.isEmpty { text("[]", font: mono, color: .secondaryLabelColor) }
            else {
                text("[", font: mono, color: .secondaryLabelColor); jsonCount(items.count, noun: "items"); text("\n", font: mono)
                for (index, item) in items.enumerated() { jsonValue(item, depth: depth + 1, comma: index < items.count - 1) }
                text(indent + "]", font: mono, color: .secondaryLabelColor)
            }
        default: scalar(value)
        }
        text(comma ? ",\n" : "\n", font: mono, color: .secondaryLabelColor)
    }
    private mutating func scalar(_ value: NativeJSON) {
        let color: NSColor
        switch value { case .string: color = FeedPalette.jsonString; case .number: color = FeedPalette.jsonNumber; case .boolean: color = FeedPalette.jsonBoolean; default: color = FeedPalette.muted }
        let start = buffer.length
        text(value.scalar ?? "", font: mono, color: color)
        if let raw = value.string, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
            buffer.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: start, length: buffer.length - start))
        }
    }

    private mutating func jsonCount(_ count: Int, noun: String) {
        let hint = "  \(count) \(count == 1 ? String(noun.dropLast()) : noun)"
        text(hint, font: NSFontManager.shared.convert(.monospacedSystemFont(ofSize: max(8, size - 4), weight: .regular), toHaveTrait: .italicFontMask), color: FeedPalette.muted)
    }

    private mutating func html(_ source: String) {
        flush(); blocks.append(.html(source)); code(source, language: "html")
    }

    private mutating func markdown(_ source: String) {
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); let marker = String(trimmed.prefix(3)); let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1; var body: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) { body.append(lines[i]); i += 1 }
                let snippet = body.joined(separator: "\n")
                if ["html", "htm"].contains(language.lowercased()) { html(snippet) }
                else if language == "svg" { blocks.append(.html(snippet)); code(snippet, language: "xml") }
                else if let json = NativeJSON.parseEmbedded(snippet), language == "json" || (language.isEmpty && NativeImageReference.containsImage(json)) { renderJSON(json, source: snippet) }
                else { code(snippet, language: language) }
            } else if let json = NativeJSON.parseEmbedded(trimmed), NativeImageReference.containsImage(json) {
                flush(); renderJSON(json, source: trimmed)
            } else if let match = firstMatch(Self.imagePattern, line) {
                inline((line as NSString).substring(to: match.range.location)); flush()
                let destination = (line as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if var image = NativeImageReference.detect(destination, typed: true) { image.title = (line as NSString).substring(with: match.range(at: 1)); blocks.append(.image(image)) }
                inline((line as NSString).substring(from: NSMaxRange(match.range))); text("\n")
            } else if isHTML(trimmed) {
                flush(); var html = [line]; i += 1
                while i < lines.count && !lines[i].isEmpty { html.append(lines[i]); i += 1 }
                self.html(html.joined(separator: "\n")); continue
            } else if let match = firstMatch(Self.headingPattern, line) {
                let level = match.range(at: 1).length
                let headingFont = Typography.prose(ofSize: size * (level == 1 ? 1.65 : level == 2 ? 1.35 : 1.12), weight: .semibold)
                let start = buffer.length
                inline((line as NSString).substring(with: match.range(at: 2)), font: headingFont)
                text("\n", font: headingFont)
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = headingFont.pointSize * 1.2
                style.paragraphSpacing = size * 0.6
                buffer.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: buffer.length - start))
                // Markdown's optional blank separator must not add another
                // full body line on top of the heading's paragraph spacing.
                while i + 1 < lines.count && lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            } else if trimmed == "---" || trimmed == "***" { text("────────────────────────\n", color: .separatorColor) }
            else if firstMatch(Self.tableDivider, trimmed) != nil { /* table divider */ }
            else if trimmed.contains("|") && (trimmed.hasPrefix("|") || (i + 1 < lines.count && lines[i + 1].contains("---"))) {
                let columns = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                inline(columns.joined(separator: "\t"), font: mono); text("\n", font: mono)
            } else if let match = firstMatch(Self.listPattern, line) {
                text("  •  "); inline((line as NSString).substring(with: match.range(at: 1))); text("\n")
            } else if trimmed.hasPrefix(">") { text("│  ", color: .secondaryLabelColor); inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); text("\n") }
            else { inline(line); text("\n") }
            i += 1
        }
    }
    private func firstMatch(_ regex: NSRegularExpression, _ source: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }
    private mutating func inline(_ source: String, font: NSFont? = nil) {
        let chosen = font ?? self.font, ns = source as NSString
        var start = 0
        for match in Self.inlinePattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            text(ns.substring(with: NSRange(location: start, length: match.range.location - start)), font: chosen)
            let token = ns.substring(with: match.range)
            if token.hasPrefix("`") { text(String(token.dropFirst().dropLast()), font: mono, color: purple) }
            else if token.hasPrefix("**") || token.hasPrefix("__") { text(String(token.dropFirst(2).dropLast(2)), font: InterfaceStyle.isMatrix ? .monospacedSystemFont(ofSize: chosen.pointSize, weight: .bold) : .systemFont(ofSize: chosen.pointSize, weight: .semibold)) }
            else if token.hasPrefix("["), let link = firstMatch(Self.linkPattern, token) {
                let part = token as NSString, label = part.substring(with: link.range(at: 1)), destination = part.substring(with: link.range(at: 2))
                let at = buffer.length; text(label, font: chosen, color: blue)
                if let url = URL(string: destination) { buffer.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: at, length: (label as NSString).length)) }
            } else { text(String(token.dropFirst().dropLast()), font: NSFontManager.shared.convert(chosen, toHaveTrait: .italicFontMask)) }
            start = NSMaxRange(match.range)
        }
        text(ns.substring(from: start), font: chosen)
    }

    private mutating func code(_ source: String, language: String) {
        flush()
        if NativeDiff.recognizes(source, language: language) {
            blocks.append(.code(NativeDiff.attributed(source, font: mono), source: source, label: "Diff"))
            return
        }
        let normalized = CodeAnalysisRequest.language(language)
        let request = normalized.map { CodeAnalysisRequest(source: source, language: $0) }
        let analysis = request.flatMap { analyses[$0.key] }
        if let request, analysis == nil { requestedCode.append(request) }
        let copySource = analysis?.formatted ?? source
        let trimmed = Self.trimmedText(NSAttributedString(string: copySource)).string
        // Show every code line flush left; retain indentation in the copyable
        // source and analysis input, where it can affect the code's meaning.
        let display = Self.lineStartSpaces.stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length), withTemplate: "")
        let result = NSMutableAttributedString(string: display, attributes: [.font: mono, .foregroundColor: FeedPalette.text, .paragraphStyle: paragraph(code: true, font: mono)])
        for match in Self.codeTokens.matches(in: display, range: NSRange(location: 0, length: min(result.length, 65_536))) {
            let color: NSColor = match.range(at: 1).location != NSNotFound ? green : match.range(at: 2).location != NSNotFound ? purple : match.range(at: 3).location != NSNotFound ? FeedPalette.orange : FeedPalette.muted
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
        if let analysis {
            for diagnostic in analysis.diagnostics {
                result.append(NSAttributedString(string: "\n\(diagnostic.code)  \(diagnostic.line):\(diagnostic.column)  \(diagnostic.message)", attributes: [.font: NSFont.systemFont(ofSize: max(8, size - 3)), .foregroundColor: NSColor.systemOrange]))
            }
        }
        if let analysis, let message = analysis.message {
            result.append(NSAttributedString(string: "\n\(message)", attributes: [.font: NSFont.systemFont(ofSize: max(8, size - 3)), .foregroundColor: FeedPalette.muted]))
        }
        let name = normalized == "python" ? "Python" : normalized == "javascript" ? "JavaScript" : "HTML"
        let label = request != nil ? (analysis.map { $0.state == "clean" ? "\(name) · Lint clean" : $0.state == "issues" ? "\(name) · \($0.diagnostics.count) lint findings" : "\(name) · Lint unavailable" } ?? "\(name) · Checking…") : (language.isEmpty ? "Code" : language)
        blocks.append(.code(result, source: copySource, label: label))
    }
}
