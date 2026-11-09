import AppKit

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onCaretVisibilityChange: ((Bool) -> Void)?
    var onImageDrop: ((NSPasteboard, NSPoint) -> Bool)?
    var onImageDrag: ((Bool) -> Void)?
    var placeholder = "Message this chat…"
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { onFocusChange?(true) }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { onFocusChange?(false) }; return result }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        onCaretVisibilityChange?(flag)
    }
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isReturn && modifiers.isEmpty && !hasMarkedText() { onSend?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor])
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ChatAttachment.accepts(sender.draggingPasteboard) { onImageDrag?(true); return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ChatAttachment.accepts(sender.draggingPasteboard) { onImageDrag?(true); return .copy }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onImageDrag?(false); super.draggingExited(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ChatAttachment.accepts(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onImageDrag?(false)
        if ChatAttachment.accepts(sender.draggingPasteboard) { return onImageDrop?(sender.draggingPasteboard, sender.draggingLocation) ?? false }
        return super.performDragOperation(sender)
    }
    override func paste(_ sender: Any?) {
        if ChatAttachment.accepts(.general), onImageDrop?(.general, .zero) == true { return }
        super.paste(sender)
    }
}

@MainActor
final class WelcomePane: NSViewController {
    var onNewChat: (() -> Void)?
    var onOpenProject: (() -> Void)?
    override func loadView() {
        view = WorkspaceSurface()
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(wrappingLabelWithString: "See the work unfold.")
        title.font = Typography.welcomeTitle; title.textColor = FeedPalette.text; title.alignment = .center
        let description = NSTextField(wrappingLabelWithString: "Chat with a clear, live view of progress, reasoning summaries, commands and results.")
        description.attributedStringValue = Typography.wrappingText(description.stringValue, font: Typography.conversation, color: FeedPalette.muted, alignment: .center)
        let start = NSButton(title: "New chat", target: self, action: #selector(newChat)); start.bezelStyle = .rounded
        start.bezelColor = .controlAccentColor
        let project = NSButton(title: "Open project…", target: self, action: #selector(openProject)); project.bezelStyle = .rounded
        for button in [start, project] { button.font = Typography.interface }
        let actions = NSStackView(views: [start, project]); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 12
        let note = NSTextField(wrappingLabelWithString: "Use Codex with ChatGPT or your signed-in Claude Code account.\nChats and shared activity are saved on this Mac.")
        note.attributedStringValue = Typography.wrappingText(note.stringValue, font: Typography.caption, color: FeedPalette.muted, alignment: .center)
        let stack = NSStackView(views: [icon, title, description, actions, note]); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 24
        stack.setCustomSpacing(12, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        for label in [title, description, note] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440), stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24), icon.heightAnchor.constraint(equalToConstant: 44), icon.widthAnchor.constraint(equalToConstant: 48)])
    }
    @objc private func newChat() { onNewChat?() }
    @objc private func openProject() { onOpenProject?() }
}
