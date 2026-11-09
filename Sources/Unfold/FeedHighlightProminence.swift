import AppKit

/// Visual priority is based on provenance, not syntax: reading a Python file
/// or receiving HTML from a tool does not make it newly created work.
enum FeedHighlightProminence {
    case created, reasoning, response, activity, error
}

extension FeedHighlight {
    var prominence: FeedHighlightProminence {
        if kind == "Error" || command?.state == .failed { return .error }
        if freshCode || createdOutput || kind == "Changes" { return .created }
        if kind == "Reasoning" { return .reasoning }
        if ["Reply", "Heading", "You"].contains(kind) { return .response }
        return .activity
    }

    var overviewHeight: CGFloat {
        switch prominence {
        case .created, .reasoning: return 116
        case .response, .error: return 96
        case .activity: return 76
        }
    }

    var overviewBadge: String {
        if freshCode { return "Created code" }
        if kind == "Changes" { return "File changes" }
        if createdOutput { return "Created output" }
        return commandText == nil ? kind : "Command"
    }
}
