import AppKit

/// Keep semantic badge colors on the canvas they were designed for. A neutral
/// selection fill underneath their translucent tints loses contrast in both
/// appearances; an outline gives selection a stable, separate cue.
@MainActor
final class FeedOverviewRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        FeedPalette.blue.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        outline.lineWidth = 1.5
        outline.stroke()
    }
}

@MainActor
final class FeedOverviewCell: NSView {
    private var entry: FeedHighlight
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    init(entry: FeedHighlight) {
        self.entry = entry
        super.init(frame: .zero)
        name.stringValue = entry.title
        let created = entry.prominence == .created
        let reasoning = entry.prominence == .reasoning
        let activity = entry.prominence == .activity
        name.font = activity ? Typography.caption : Typography.interfaceEmphasis
        name.textColor = entry.prominence == .error ? FeedPalette.red : reasoning ? FeedPalette.purple : activity ? FeedPalette.muted : FeedPalette.text
        name.maximumNumberOfLines = created ? 2 : 1
        name.cell?.wraps = created
        name.lineBreakMode = .byTruncatingTail
        let badge = FeedTypeBadge(kind: entry.overviewBadge, prominent: !activity)
        detail.font = reasoning ? Typography.caption : Typography.metadata
        detail.textColor = reasoning ? FeedPalette.text : FeedPalette.muted
        detail.attributedStringValue = Typography.wrappingText(Self.detail(entry), font: detail.font!, color: detail.textColor!)
        detail.maximumNumberOfLines = reasoning ? 3 : activity ? 1 : 2; detail.lineBreakMode = .byTruncatingTail
        elapsed.font = Typography.timestamp; elapsed.textColor = FeedPalette.muted
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [name, badge, detail, elapsed] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        var titleInset: CGFloat = 8
        if created {
            titleInset = 28
            let symbol = entry.freshCode ? "curlybraces" : entry.kind == "Changes" ? "doc.badge.gearshape" : "doc.richtext"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = FeedPalette.green
            icon.translatesAutoresizingMaskIntoConstraints = false; addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.topAnchor.constraint(equalTo: topAnchor, constant: 9), icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14)])
        }
        if let activity = entry.command {
            titleInset = 25
            let indicator: NSView
            if activity.state == .running {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
                spinner.startAnimation(nil); spinner.setAccessibilityLabel("Running command")
                indicator = spinner
            } else {
                let symbol = activity.state == .succeeded ? "checkmark.circle.fill" : activity.state == .failed ? "xmark.circle.fill" : activity.state == .interrupted ? "stop.circle" : "questionmark.circle"
                let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: activity.state.rawValue) ?? NSImage())
                image.contentTintColor = activity.state == .succeeded ? FeedPalette.green : activity.state == .failed ? FeedPalette.red : FeedPalette.muted
                indicator = image
            }
            indicator.translatesAutoresizingMaskIntoConstraints = false; addSubview(indicator)
            NSLayoutConstraint.activate([indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), indicator.topAnchor.constraint(equalTo: topAnchor, constant: 7), indicator.widthAnchor.constraint(equalToConstant: 12), indicator.heightAnchor.constraint(equalToConstant: 12)])
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleInset), name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), badge.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4), badge.heightAnchor.constraint(equalToConstant: 18),
            elapsed.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6), elapsed.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4), elapsed.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), detail.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 3), detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
        updateClock()
        setAccessibilityLabel("\(entry.overviewBadge): \(entry.title)")
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard entry.prominence == .created || entry.prominence == .reasoning else { return }
        let accent = entry.prominence == .reasoning ? FeedPalette.purple : FeedPalette.green
        accent.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        accent.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 8, width: 3, height: max(0, bounds.height - 16)), xRadius: 1.5, yRadius: 1.5).fill()
    }
    private static func detail(_ entry: FeedHighlight) -> String {
        entry.commandText.map { entry.summary == $0 ? $0 : entry.summary + "\n" + $0 } ?? entry.summary
    }
    /// Text updates keep the card, spinner and selection in place. A visual
    /// category or command-state change needs a different set of controls.
    func update(_ value: FeedHighlight) -> Bool {
        guard entry.prominence == value.prominence, entry.overviewBadge == value.overviewBadge,
              entry.freshCode == value.freshCode, entry.command?.state == value.command?.state else { return false }
        entry = value
        if name.stringValue != value.title { name.stringValue = value.title }
        let description = Self.detail(value)
        if detail.stringValue != description {
            detail.attributedStringValue = Typography.wrappingText(description, font: detail.font!, color: detail.textColor!)
        }
        setAccessibilityLabel("\(value.overviewBadge): \(value.title)")
        updateClock()
        return true
    }
    func updateClock() {
        if let activity = entry.command {
            elapsed.stringValue = activity.state == .unknown ? "Unknown" : activity.elapsed()
            let outcome = activity.state == .running ? "Running" : activity.state == .succeeded ? "Succeeded" : activity.state == .failed ? "Failed" : activity.state == .interrupted ? "Interrupted" : "Status unavailable"
            let exit = activity.exitCode.map { " · exit \($0)" } ?? ""
            elapsed.setAccessibilityLabel("\(outcome), \(elapsed.stringValue)\(exit)")
            toolTip = "\(entry.title) · \(outcome) · \(elapsed.stringValue)\(exit)\n\(entry.commandText ?? entry.summary)"
        } else { toolTip = "\(entry.title) [\(entry.kind)]\n\(entry.commandText ?? entry.summary)" }
    }
}
