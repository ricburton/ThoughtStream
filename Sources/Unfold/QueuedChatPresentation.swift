import AppKit

extension NSAttributedString.Key {
    static let queuedChatBubble = NSAttributedString.Key("ThoughtStream.queuedChatBubble")
}

@MainActor
enum QueuedChatPresentation {
    static func label(status: String, detail: String?, includeRetry: Bool = true) -> NSAttributedString {
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
        if includeRetry, status == "blocked" || status == "uncertain" {
            var link = attributes
            link[.link] = URL(string: "thoughtstream-queue://retry")!
            result.append(NSAttributedString(string: status == "uncertain" ? "Check delivery\n" : "Retry\n", attributes: link))
        } else if detail != nil { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        return result
    }
}
