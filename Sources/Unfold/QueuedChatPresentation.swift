import AppKit

extension NSAttributedString.Key {
    static let queuedChatBubble = NSAttributedString.Key("ThoughtStream.queuedChatBubble")
}

@MainActor
enum QueuedChatPresentation {
    /// Set while the Internet is away and a model on this Mac could answer
    /// instead. Waiting messages then offer to move to it.
    static var localModelName: String?

    static func link(_ action: String, messageID: String?) -> URL {
        URL(string: "thoughtstream-queue://\(action)" + (messageID.map { "/" + $0 } ?? ""))!
    }

    static func label(status: String, detail: String?, includeRetry: Bool = true, messageID: String? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 7; style.paragraphSpacingBefore = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Typography.section,
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style
        ]
        let result = NSMutableAttributedString(string: "  Queued Chat  ", attributes: attributes)
        result.addAttribute(.queuedChatBubble, value: true, range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        if let detail, !detail.isEmpty {
            result.append(NSAttributedString(string: detail + " ", attributes: attributes))
        }
        var actions: [(String, URL)] = []
        if includeRetry, status == "blocked" || status == "uncertain" {
            actions.append((status == "uncertain" ? "Check delivery" : "Retry", link("retry", messageID: nil)))
        }
        // A message that has not left yet can be moved or taken back.
        if includeRetry, let messageID, status == "queued" || status == "blocked" {
            if let localModelName { actions.append(("Answer with \(localModelName) on this Mac", link("local", messageID: messageID))) }
            actions.append(("Cancel", link("cancel", messageID: messageID)))
        }
        for (index, action) in actions.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ·  ", attributes: attributes)) }
            var link = attributes
            link[.link] = action.1
            result.append(NSAttributedString(string: action.0, attributes: link))
        }
        if !actions.isEmpty || detail != nil { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        return result
    }
}
