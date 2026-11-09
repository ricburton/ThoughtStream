import Foundation

/// Decode transport envelopes without changing ordinary application JSON.
/// The original record is retained separately for copying and persistence.
enum ToolPayload {
    enum Part {
        case text(String)
        case json(NativeJSON)
        case image(NativeImageReference)
        /// A short label naming the tool that produced the following parts.
        case caption(String)
    }

    static func unwrap(_ value: NativeJSON, depth: Int = 0) -> [Part]? {
        guard depth < 16 else { return nil }
        if let source = value.string, let nested = NativeJSON.parseEmbedded(source), nested.string == nil {
            return unwrap(nested, depth: depth + 1)
        }
        guard case .object(let fields) = value else { return nil }
        if let parts = toolCall(value, depth: depth) { return parts }
        if case .array(let contents) = value["content"],
           !contents.isEmpty, contents.allSatisfy(isContentBlock) {
            var parts = contents.flatMap { content($0, depth: depth + 1) }
            // Keep additional, meaningful fields. Only transport bookkeeping is removed.
            let remaining = fields.filter { key, item in
                if key == "content" { return false }
                if ["_meta", "annotations"].contains(key) && isEmpty(item) { return false }
                if key == "isError", case .boolean(false) = item { return false }
                return true
            }
            if !remaining.isEmpty { parts.append(.json(.object(remaining))) }
            return parts
        }
        if isTextBlock(value), let source = value["text"]?.string {
            var parts = textContent(source, depth: depth + 1)
            let metadata = fields.filter { ["_meta", "annotations"].contains($0.0) && !isEmpty($0.1) }
            if !metadata.isEmpty { parts.append(.json(.object(metadata))) }
            return parts
        }
        return nil
    }

    /// A completed tool-call item (Claude Code's tool results arrive as
    /// `dynamicToolCall`) shows its result as readable text under the tool's name.
    /// Started items carry only arguments and stay structured JSON.
    private static func toolCall(_ value: NativeJSON, depth: Int) -> [Part]? {
        guard let type = value["type"]?.string, ["dynamicToolCall", "mcpToolCall"].contains(type),
              let result = value["result"] else { return nil }
        let name = [value["server"]?.string, value["tool"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var failed = false
        if case .boolean(true) = value["isError"] { failed = true }
        if let status = value["status"]?.string, status == "failed" { failed = true }
        var parts: [Part] = []
        let caption = (name.isEmpty ? "Tool result" : name) + (failed ? " · failed" : "")
        parts.append(.caption(caption))
        switch result {
        case .string(let source):
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts += textContent(source, depth: depth + 1) }
        case .array(let contents) where contents.allSatisfy(isContentBlock):
            parts += contents.flatMap { content($0, depth: depth + 1) }
        case .null: break
        default:
            parts += unwrap(result, depth: depth + 1) ?? [.json(result)]
        }
        if let message = value["error"]?["message"]?.string ?? value["error"]?.string { parts.append(.text(message)) }
        return parts
    }

    private static func isContentBlock(_ value: NativeJSON) -> Bool {
        if isTextBlock(value) || NativeImageReference.detect(value) != nil { return true }
        return value["type"]?.string != nil || value["content"] != nil
    }
    private static func isTextBlock(_ value: NativeJSON) -> Bool {
        guard case .object(let fields) = value, value["text"]?.string != nil else { return false }
        let type = value["type"]?.string
        return (type == nil || ["text", "input_text", "output_text"].contains(type!)) &&
            fields.allSatisfy { ["type", "text", "_meta", "annotations"].contains($0.0) }
    }
    private static func content(_ value: NativeJSON, depth: Int) -> [Part] {
        if let image = NativeImageReference.detect(value) { return [.image(image)] }
        if let parts = unwrap(value, depth: depth) { return parts }
        return [.json(value)]
    }
    private static func textContent(_ source: String, depth: Int) -> [Part] {
        if depth < 16, let nested = NativeJSON.parseEmbedded(source) {
            if let parts = unwrap(nested, depth: depth) { return parts }
            // A string encoded more than once still represents the same tool text.
            if let text = nested.string { return textContent(text, depth: depth + 1) }
            return [.json(nested)]
        }
        if let image = NativeImageReference.detect(source) { return [.image(image)] }
        return [.text(source)]
    }
    private static func isEmpty(_ value: NativeJSON) -> Bool {
        switch value {
        case .null: return true
        case .object(let fields): return fields.isEmpty
        case .array(let values): return values.isEmpty
        default: return false
        }
    }
    static func isUITree(_ source: String) -> Bool {
        let prefix = source.prefix(2048).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("Window:") ||
            prefix.range(of: #"(?m)^\s*\d+ (?:standard window|application|split group|scroll area)\b"#, options: .regularExpression) != nil
    }
}
