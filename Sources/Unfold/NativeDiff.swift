import AppKit
import GitDiff

extension NSAttributedString.Key {
    static let nativeDiffKind = NSAttributedString.Key("ThoughtStream.diff.kind")
    static let nativeDiffOldLine = NSAttributedString.Key("ThoughtStream.diff.oldLine")
    static let nativeDiffNewLine = NSAttributedString.Key("ThoughtStream.diff.newLine")
}

/// Adapts gitdiff's model to native text without altering the patch being copied.
enum NativeDiff {
    static let gutterWidth: CGFloat = 78

    static func recognizes(_ source: String, language: String) -> Bool {
        if ["diff", "patch", "udiff"].contains(language.lowercased()) { return true }
        return source.hasPrefix("diff --git ") || source.contains("\ndiff --git ")
            || (source.hasPrefix("--- ") && source.contains("\n+++ ") && source.contains("\n@@ "))
    }

    static func attributed(_ source: String, font: NSFont) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = font.pointSize * 1.6
        style.maximumLineHeight = font.pointSize * 1.6
        style.firstLineHeadIndent = gutterWidth
        style.headIndent = gutterWidth
        style.lineBreakMode = .byCharWrapping
        style.tabStops = []; style.defaultTabInterval = font.pointSize * 4
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font, .foregroundColor: FeedPalette.text, .paragraphStyle: style,
            .nativeDiffKind: "metadata"
        ])
        let lines = source.components(separatedBy: "\n")
        var ranges: [NSRange] = []
        var offset = 0
        for line in lines {
            let length = (line as NSString).length
            ranges.append(NSRange(location: offset, length: min(length + 1, result.length - offset)))
            offset += length + 1
        }
        // File-change events can contain just a path and hunks. Supply only the
        // parser's required envelope; presentation and Copy keep the original.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let input = normalized.contains("diff --git ") ? normalized : "diff --git a/Changes b/Changes\n" + normalized
        let files = (try? UnifiedDiffParser().parse(input)) ?? []
        var cursor = 0
        for file in files {
            for hunk in file.hunks {
                guard let start = lines[cursor...].firstIndex(where: { $0.trimmingCharacters(in: .newlines) == hunk.header }) else { continue }
                result.addAttributes([.nativeDiffKind: "hunk", .foregroundColor: FeedPalette.blue], range: ranges[start])
                cursor = start + 1
                for line in hunk.lines {
                    guard cursor < lines.count else { break }
                    let kind: String
                    let color: NSColor
                    switch line.type {
                    case .added: kind = "added"; color = FeedPalette.green
                    case .removed: kind = "removed"; color = FeedPalette.red
                    case .context: kind = "context"; color = FeedPalette.text
                    case .header: kind = "metadata"; color = FeedPalette.muted
                    }
                    var attributes: [NSAttributedString.Key: Any] = [.nativeDiffKind: kind, .foregroundColor: color]
                    if let number = line.oldLineNumber { attributes[.nativeDiffOldLine] = number }
                    if let number = line.newLineNumber { attributes[.nativeDiffNewLine] = number }
                    result.addAttributes(attributes, range: ranges[cursor])
                    cursor += 1
                }
            }
        }
        return result
    }

    static func summary(_ text: NSAttributedString) -> String {
        var added = 0, removed = 0
        let source = text.string as NSString
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let kind = text.attribute(.nativeDiffKind, at: offset, effectiveRange: nil) as? String
            if kind == "added" { added += 1 }
            if kind == "removed" { removed += 1 }
            offset = NSMaxRange(range)
        }
        return "+\(added)  −\(removed)"
    }
}
