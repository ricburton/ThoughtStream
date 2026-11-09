import Foundation

/// Keep number lexemes intact, including IDs larger than JavaScript's integer range.
indirect enum NativeJSON {
    case object([(String, NativeJSON)]), array([NativeJSON]), string(String), number(String), boolean(Bool), null

    var scalar: String? {
        switch self {
        case .string(let value): return Self.quoted(value)
        case .number(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        default: return nil
        }
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    subscript(_ key: String) -> NativeJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.0 == key }?.1
    }
    static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
        return String(json.dropFirst().dropLast())
    }
    static func parse(_ text: String) -> NativeJSON? {
        guard let first = text.first(where: { !$0.isWhitespace }), "{[\"-0123456789tfn".contains(first) else { return nil }
        guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        var parser = Parser(text: Array(text.utf8))
        return parser.value()
    }
    /// Tool output sometimes JSON-encodes a payload more than once, or omits
    /// the outer quotes while retaining their escapes. Decode whole values only.
    static func parseEmbedded(_ text: String) -> NativeJSON? {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: NativeJSON?
        for _ in 0..<8 {
            if let value = parse(source) {
                if result == nil { result = value }
                switch value {
                case .object, .array: return value
                default: break
                }
                guard let nested = value.string, nested != source else { return result }
                source = nested.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if (source.hasPrefix("{") || source.hasPrefix("[")), source.contains(#"\""#),
                      let decoded = parse("\"" + source + "\"")?.string, decoded != source {
                source = decoded
            } else { return result }
        }
        return result
    }
    private struct Parser {
        let text: [UInt8]
        var index = 0
        mutating func skip() { while index < text.count && [9, 10, 13, 32].contains(text[index]) { index += 1 } }
        mutating func quoted() -> String? {
            let start = index; index += 1
            while index < text.count {
                if text[index] == 92 { index += 2; continue }
                if text[index] == 34 { index += 1; break }
                index += 1
            }
            let raw = String(decoding: text[start..<min(index, text.count)], as: UTF8.self)
            return ((try? JSONSerialization.jsonObject(with: Data("[\(raw)]".utf8))) as? [String])?.first
        }
        mutating func value() -> NativeJSON? {
            skip(); guard index < text.count else { return nil }
            if text[index] == 34 { return quoted().map(NativeJSON.string) }
            if text[index] == 123 {
                index += 1; skip(); var fields: [(String, NativeJSON)] = []
                while index < text.count && text[index] != 125 {
                    guard let key = quoted() else { return nil }; skip(); index += 1
                    guard let item = value() else { return nil }; fields.append((key, item)); skip()
                    if index < text.count && text[index] == 44 { index += 1; skip() } else { break }
                }
                index += 1; return .object(fields)
            }
            if text[index] == 91 {
                index += 1; skip(); var values: [NativeJSON] = []
                while index < text.count && text[index] != 93 {
                    guard let item = value() else { return nil }; values.append(item); skip()
                    if index < text.count && text[index] == 44 { index += 1 } else { break }
                }
                index += 1; return .array(values)
            }
            let start = index
            while index < text.count && ![9, 10, 13, 32].contains(text[index]) && ![44, 125, 93].contains(text[index]) { index += 1 }
            let token = String(decoding: text[start..<index], as: UTF8.self)
            switch token { case "true": return .boolean(true); case "false": return .boolean(false); case "null": return .null; default: return .number(token) }
        }
    }
}

struct NativeImageReference: Hashable {
    let source: String
    var title: String = "Image"
    static func containsImage(_ value: NativeJSON, depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        if detect(value) != nil { return true }
        switch value {
        case .object(let fields): return fields.contains { containsImage($0.1, depth: depth + 1) }
        case .array(let values): return values.contains { containsImage($0, depth: depth + 1) }
        case .string(let source):
            guard let nested = NativeJSON.parseEmbedded(source), nested.string == nil else { return false }
            return containsImage(nested, depth: depth + 1)
        default: return false
        }
    }
    static func detect(_ value: NativeJSON) -> NativeImageReference? {
        if case .string(let text) = value { return detect(text) }
        let type = value["type"]?.string ?? ""
        let mime = value["mimeType"]?.string ?? value["mime_type"]?.string ?? value["media_type"]?.string ?? ""
        let typed = ["image", "input_image", "output_image", "image_url", "local_image"].contains(type) || mime.hasPrefix("image/")
        for key in ["data", "b64_json", "base64", "blob"] {
            if let raw = value[key]?.string {
                if let image = detect(raw) { return image }
                if typed && mime.hasPrefix("image/") { return NativeImageReference(source: "data:\(mime);base64,\(raw)") }
            }
        }
        if typed, let source = value["source"], let image = detect(source) { return image }
        for key in ["image_url", "imageUrl", "image_path", "imagePath", "url", "path", "file_path", "uri"] {
            if let item = value[key], let raw = item.string ?? item["url"]?.string,
               let image = detect(raw, typed: typed || key.hasPrefix("image")) { return image }
        }
        return nil
    }
    static func detect(_ source: String, typed: Bool = false) -> NativeImageReference? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("data:image/") { return NativeImageReference(source: text) }
        let signatures = [("/9j/", "jpeg"), ("iVBORw0KGgo", "png"), ("R0lGOD", "gif"), ("UklGR", "webp"), ("SUkq", "tiff"), ("TU0AK", "tiff")]
        if text.count >= 24, let match = signatures.first(where: { text.hasPrefix($0.0) }) {
            return NativeImageReference(source: "data:image/\(match.1);base64,\(text)")
        }
        let path = text.components(separatedBy: "?").first ?? text
        let extensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "jp2", "jxl"]
        guard typed || extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        guard !text.contains("\n"), !text.isEmpty else { return nil }
        return NativeImageReference(source: text)
    }
}
