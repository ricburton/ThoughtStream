import Foundation

/// Syntax describes the payload; origin describes whether it is work we made
/// or information returned while doing that work. Never infer a file edit from
/// a code fence or a diff printed by a tool.
enum FeedContentOrigin: String, Sendable {
    case projectChange, generated, apiResponse, toolCall, output, command, context, error

    init(record: StreamRecord) {
        if record.kind == "Error" || record.command?.state == .failed {
            self = .error; return
        }
        switch record.kind {
        case "File change": self = .projectChange
        case "Agent", "Code": self = .generated
        case "Tool":
            let value = record.text.utf8.count < 262_144 ? NativeJSON.parse(record.text) : nil
            if case .boolean(true) = value?["isError"] { self = .error }
            else if case .boolean(true) = value?["result"]?["isError"] { self = .error }
            else if ["failed", "error"].contains(value?["status"]?.string ?? "") { self = .error }
            else if ["dynamicToolCall", "mcpToolCall"].contains(value?["type"]?.string ?? ""), value?["result"] == nil { self = .toolCall }
            else { self = .apiResponse }
        case "Output": self = .output
        case "Command": self = .command
        default: self = .context
        }
    }

    var opensExpanded: Bool { self == .projectChange || self == .generated || self == .error }

    var title: String {
        switch self {
        case .projectChange: return "Project changes"
        case .generated: return "Generated code"
        case .apiResponse: return "API / tool response"
        case .toolCall: return "Tool call"
        case .output: return "Command output"
        case .command: return "Command"
        case .context: return "Code"
        case .error: return "Error"
        }
    }

    static func read(from text: NSAttributedString) -> Self {
        guard text.length > 0,
              let value = text.attribute(.feedContentOrigin, at: 0, effectiveRange: nil) as? String else { return .context }
        return Self(rawValue: value) ?? .context
    }
}

extension NSAttributedString.Key {
    static let feedContentOrigin = NSAttributedString.Key("ThoughtStream.feedContentOrigin")
}
