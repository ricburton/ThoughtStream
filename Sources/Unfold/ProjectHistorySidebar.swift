import AppKit

struct ProjectHistoryEntry {
    let title: String
    let provider: AgentProvider
    let thread: String?
    let sessionID: UUID?
    var updatedAt: Date? = nil

    var key: String { provider.rawValue + ":" + (thread ?? sessionID!.uuidString) }
}

enum ProjectHistoryRow {
    case project(URL)
    case conversation(String, ProjectHistoryEntry)
    case status(String, String, retry: Bool)
}

@MainActor
final class ProjectHistoryDisclosureButton: NSButton {
    private let onToggle: () -> Void

    init(name: String, expanded: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self; action = #selector(toggle)
        setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(name) conversation history")
        setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        toolTip = expanded ? "Collapse conversation history" : "Show all conversations"
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    @objc private func toggle() { onToggle() }
}

@MainActor
final class ProjectHistoryCell: NSTableCellView {
    init(title: String, detail: String? = nil, status: Bool = false) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = Typography.interface
        label.textColor = status ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        textField = label
        toolTip = [title, detail].compactMap { $0 }.joined(separator: "\n")
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if let detail { label.setAccessibilityLabel(title + ", " + detail) }
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
}
