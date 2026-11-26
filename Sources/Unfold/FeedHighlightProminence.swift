import AppKit

/// Visual priority is based on provenance, not syntax: reading a Python file
/// or receiving HTML from a tool does not make it newly created work.
enum FeedHighlightProminence {
    case created, reasoning, response, activity, error
}

extension FeedHighlight {
    var prominence: FeedHighlightProminence {
        if kind == "Error" || contentOrigin == .error || command?.state == .failed { return .error }
        if freshCode || createdOutput || kind == "Changes" { return .created }
        if kind == "Reasoning" { return .reasoning }
        if ["Reply", "Heading", "You"].contains(kind) { return .response }
        return .activity
    }

    var overviewHeight: CGFloat {
        let height: CGFloat
        switch prominence {
        case .created, .reasoning: height = 116
        case .response, .error: height = 96
        case .activity: height = 76
        }
        return height - (showsOverviewMetadata ? 0 : 22)
    }

    var showsOverviewBadge: Bool { !Self.sameLabel(title, overviewBadge) }
    var showsOverviewMetadata: Bool { showsOverviewBadge || command != nil }
    var overviewAccessibilityLabel: String {
        showsOverviewBadge ? "\(overviewBadge): \(title)" : title
    }
    var overviewDetail: String {
        var lines: [String] = []
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ![title, overviewBadge].contains(where: { Self.sameLabel($0, summary) }) {
            lines.append(summary)
        }
        // Commands are source content: case and whitespace can be meaningful.
        if let commandText, !commandText.isEmpty, !lines.contains(commandText) { lines.append(commandText) }
        return lines.joined(separator: "\n")
    }
    private static func sameLabel(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            == rhs.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    var overviewBadge: String {
        if contentOrigin == .error { return "Error" }
        if kind == "Changes" { return "Project changes" }
        if freshCode { return "Generated code" }
        if createdOutput { return "Created output" }
        if contentOrigin == .apiResponse { return "API / tool response" }
        if contentOrigin == .toolCall { return "Tool call" }
        if contentOrigin == .output { return "Command output" }
        return commandText == nil ? kind : "Command"
    }
}
