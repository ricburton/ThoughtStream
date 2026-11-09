import AppKit
import QuartzCore

@MainActor
private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let distance = delta * (event.hasPreciseScrollingDeltas ? 1 : 10)
        let limit = max(0, documentView.bounds.width - contentSize.width)
        let x = min(limit, max(0, contentView.bounds.minX - distance))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
final class ComposerCard: ComposerGlowSurface {
    var onImageDrop: ((NSPasteboard, NSPoint) -> Bool)?
    var onImageDrag: ((Bool) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = ChatAttachment.accepts(sender.draggingPasteboard)
        onImageDrag?(accepts); return accepts ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onImageDrag?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ChatAttachment.accepts(sender.draggingPasteboard) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onImageDrag?(false)
        return onImageDrop?(sender.draggingPasteboard, sender.draggingLocation) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        FeedPalette.input.setFill(); shape.fill()
        (focused || receivingImages ? FeedPalette.blue.withAlphaComponent(0.8) : FeedPalette.line).setStroke()
        shape.lineWidth = receivingImages ? 2 : focused ? 1.5 : 1; shape.stroke()
    }
}

@MainActor
final class ChatTabButton: NSButton {
    var dragPayload: ChatTabDrag?
    var onDragEnded: (() -> Void)?
    var isRunning = false

    override func mouseDown(with event: NSEvent) {
        guard let payload = dragPayload, let window, let root = window.contentView else {
            super.mouseDown(with: event); return
        }
        var ghost: TabDragCardView?
        let startFrame = root.convert(bounds, from: self)
        let grab = convert(event.locationInWindow, from: nil)
        var destination: (TabSplitHostView, TabSplitSide)?
        var didDrop = false
        defer {
            TabSplitHostView.clearPreviews(in: root)
            alphaValue = 1
            onDragEnded?()
            if let ghost {
                let landing = didDrop ? Self.landingFrame(for: payload.sessionID, in: root) : nil
                ghost.land(at: landing ?? startFrame)
            }
        }
        // Local tracking keeps the preview and drop in the same window and lets
        // Escape cancel without ever changing the workspace model.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown {
                if next.keyCode == 53 { return }
                continue
            }
            if ghost == nil {
                if next.type == .leftMouseUp { performClick(nil); return }
                guard hypot(next.locationInWindow.x - event.locationInWindow.x,
                            next.locationInWindow.y - event.locationInWindow.y) >= 5 else { continue }
                let image = NSImage(size: bounds.size)
                image.lockFocus(); draw(bounds); image.unlockFocus()
                let lifted = TabDragCardView(frame: startFrame, image: image, grip: grab)
                root.addSubview(lifted); ghost = lifted; alphaValue = 0.4
            }
            destination = TabSplitHostView.previewDestination(for: payload, at: next.locationInWindow, in: root)
            let point = root.convert(next.locationInWindow, from: nil)
            ghost?.follow(point)
            // Re-add above the preview when moving between panes.
            if let ghost { root.addSubview(ghost, positioned: .above, relativeTo: nil) }
            if next.type == .leftMouseUp {
                if let (host, side) = destination { didDrop = host.onDrop?(payload, side) == true }
                return
            }
        }
    }

    private static func landingFrame(for sessionID: UUID, in root: NSView) -> NSRect? {
        func find(_ view: NSView) -> ChatTabButton? {
            if let tab = view as? ChatTabButton, tab.dragPayload?.sessionID == sessionID { return tab }
            for child in view.subviews { if let tab = find(child) { return tab } }
            return nil
        }
        guard let tab = find(root) else { return nil }
        root.layoutSubtreeIfNeeded()
        return root.convert(tab.bounds, from: tab)
    }

    var isHovering = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            ChatChrome.drawSelectedTab(in: bounds, flipped: isFlipped)
        } else {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 2), xRadius: ChatChrome.tabRadius, yRadius: ChatChrome.tabRadius)
            FeedPalette.text.withAlphaComponent(isHighlighted ? 0.1 : 0.04).setFill()
            if isHighlighted || isHovering { shape.fill() }
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = .left
        let label = NSAttributedString(string: title, attributes: [.font: state == .on ? Typography.interfaceEmphasis : Typography.interface, .foregroundColor: state == .on ? FeedPalette.text : FeedPalette.muted, .paragraphStyle: style])
        let leading: CGFloat = isRunning ? 27 : 14
        let labelHeight = ceil(label.size().height)
        label.draw(in: NSRect(x: leading, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - leading - 34), height: labelHeight))
        if isRunning {
            FeedPalette.blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3.5), xRadius: ChatChrome.tabRadius - 1.5, yRadius: ChatChrome.tabRadius - 1.5)
            focus.lineWidth = 2; focus.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

@MainActor
final class ChatTabItem: NSView {
    private let tab: ChatTabButton
    private let closeButton = NSButton()
    private var hoverArea: NSTrackingArea?
    private let onSelect: () -> Void
    private let onClose: () -> Void
    init(title: String, selected: Bool, isRunning: Bool = false, dragPayload: ChatTabDrag?, onDragEnded: @escaping () -> Void, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect; self.onClose = onClose
        tab = ChatTabButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        tab.dragPayload = dragPayload; tab.onDragEnded = onDragEnded
        tab.target = self; tab.action = #selector(selectTab); tab.isBordered = false
        tab.setButtonType(.momentaryPushIn); tab.state = selected ? .on : .off
        tab.isRunning = isRunning
        tab.toolTip = title + (dragPayload == nil ? "" : " — drag to a pane edge to split"); tab.setAccessibilityLabel(title + (selected ? ", selected" : ""))
        if isRunning { tab.setAccessibilityLabel(title + (selected ? ", selected, running" : ", running")) }
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        closeButton.isBordered = false; closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self; closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close \(title)"; closeButton.setAccessibilityLabel("Close \(title)")
        closeButton.isHidden = !selected
        for child in [tab, closeButton] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            tab.topAnchor.constraint(equalTo: topAnchor), tab.bottomAnchor.constraint(equalTo: bottomAnchor), tab.leadingAnchor.constraint(equalTo: leadingAnchor), tab.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor), closeButton.widthAnchor.constraint(equalToConstant: 24), closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        if let window { setHover(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
    }
    private func setHover(_ value: Bool) { closeButton.isHidden = !value && tab.state != .on; tab.isHovering = value }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    @objc private func selectTab() { onSelect() }
    @objc private func closeTab() { onClose() }
}

/// A pane owns its own tab strip, feed, draft, and send/stop controls.
@MainActor
final class ChatColumn: NSViewController, NSTextViewDelegate {
    let columnID: UUID
    let tabsOnly: Bool
    init(id: UUID = UUID(), tabsOnly: Bool = false) {
        columnID = id; self.tabsOnly = tabsOnly; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    let stream = StreamPane()
    let conversation = ConversationView(frame: .zero)
    let prompt = ComposerTextView()
    let sendButton = NSButton(title: "Send  ↵", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let tabs = NSStackView()
    private let tabScroll = TabScrollView()
    private var revealedSessionID: UUID?
    private let splitButton = NSButton()
    private let stackButton = NSButton()
    private let closePaneButton = NSButton()
    private let card = ComposerCard()
    private let attachmentStrip = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let attachmentStatus = NSTextField(labelWithString: "")
    private let dropHint = ImageDropHint()
    private var cardHeight: NSLayoutConstraint!
    private var conversationHeight: NSLayoutConstraint!
    private let conversationHandle = ConversationResizeHandle()
    private var conversationDragStart: CGFloat = 0
    private(set) var conversationFraction = ConversationSplit.stored()
    private var attachmentHeight: NSLayoutConstraint!
    private var attachmentTiles: [UUID: AttachmentTile] = [:]
    private(set) var attachments: [ChatAttachment] = []
    private(set) var isImportingImages = false
    var session: Session?
    var tabIDs: [UUID] = []
    var streamStates: [UUID: StreamViewState] = [:]
    var closedTabIDs: [UUID] = []
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSelectChat: ((Int) -> Void)?
    var onCloseChat: ((Int) -> Void)?
    var onSplit: (() -> Void)?
    var onSplitBelow: (() -> Void)?
    var onClosePane: (() -> Void)?
    var onTabDragEnded: (() -> Void)?
    var onDraftChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var onPrepareAttachment: (() -> Void)?
    var onImportedAttachments: ((UUID, [ChatAttachment]) -> Void)?

    override func loadView() {
        view = tabsOnly ? WorkspaceSurface() : PaneSurface(); addChild(stream)
        stream.onConversationAppend = { [weak self] record, merging in
            guard let self else { return }
            self.conversation.append(record, merging: merging, resumeFollowing: self.session?.isDisplayedInMultiplePanes != true)
        }
        stream.onConversationReplace = { [weak self] in self?.conversation.replace($0) }
        stream.onConversationQueueUpdate = { [weak self] in self?.conversation.replace($0, preservingPosition: true) }
        conversation.onRetryQueuedChat = { [weak self] in self?.session?.resumeMessageQueue(retryBlocked: true) }
        stream.onConversationFinalize = { [weak self] in self?.conversation.finalizeResponse($0) }
        tabs.orientation = .horizontal; tabs.spacing = 6
        tabScroll.documentView = tabs; tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false; tabScroll.hasVerticalScroller = false
        let newTitle = tabsOnly ? "New tab" : "New chat in this pane"
        let new = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: newTitle)!, target: self, action: #selector(newChat))
        new.toolTip = newTitle
        new.setAccessibilityLabel(newTitle)
        splitButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split pane")
        splitButton.title = "Split"
        splitButton.target = self; splitButton.action = #selector(splitRight)
        splitButton.toolTip = "Add a pane to the right"
        splitButton.setAccessibilityLabel("Split pane to the right")
        stackButton.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Stack pane")
        stackButton.title = "Stack"
        stackButton.target = self; stackButton.action = #selector(splitBelow)
        stackButton.toolTip = "Add a pane below"
        stackButton.setAccessibilityLabel("Stack pane below")
        closePaneButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
        closePaneButton.target = self; closePaneButton.action = #selector(closePane)
        closePaneButton.toolTip = "Close pane and expand the remaining panes. Chats stay saved."
        closePaneButton.setAccessibilityLabel("Close pane")
        for button in [new, splitButton, stackButton, closePaneButton] {
            button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        new.widthAnchor.constraint(equalToConstant: 36).isActive = true
        closePaneButton.isBordered = false
        closePaneButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        for button in [splitButton, stackButton] {
            button.imagePosition = .imageLeading
            button.font = Typography.caption
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        }
        let tabActions = NSStackView(views: tabsOnly ? [new] : [new, splitButton, stackButton, closePaneButton])
        tabActions.orientation = .horizontal; tabActions.alignment = .centerY; tabActions.spacing = 8
        let tabBar: NSStackView
        if tabsOnly {
            tabBar = NSStackView(views: [tabScroll, tabActions])
            tabBar.orientation = .horizontal; tabBar.alignment = .centerY; tabBar.spacing = 8
            tabActions.setContentHuggingPriority(.required, for: .horizontal)
            tabScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            let paneControls = NSStackView(views: [NSView(), tabActions])
            paneControls.orientation = .horizontal; paneControls.spacing = 0
            tabBar = NSStackView(views: [paneControls, tabScroll])
            tabBar.orientation = .vertical; tabBar.alignment = .leading; tabBar.spacing = 4
            NSLayoutConstraint.activate([
                paneControls.widthAnchor.constraint(equalTo: tabBar.widthAnchor),
                paneControls.heightAnchor.constraint(equalToConstant: 30),
                tabScroll.widthAnchor.constraint(equalTo: tabBar.widthAnchor)
            ])
        }
        tabScroll.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let scroll = NSScrollView(); scroll.documentView = prompt; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        prompt.drawsBackground = false; prompt.font = InterfaceStyle.isMatrix ? Typography.prose(ofSize: Typography.conversation.pointSize) : Typography.conversation; if InterfaceStyle.isMatrix { prompt.insertionPointColor = FeedPalette.green }; prompt.textColor = FeedPalette.text; prompt.isRichText = false
        prompt.delegate = self
        prompt.textContainerInset = NSSize(width: 12, height: 10)
        prompt.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Typography.conversation.pointSize * 1.5
        prompt.defaultParagraphStyle = paragraph
        prompt.typingAttributes[.paragraphStyle] = paragraph
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.allowsUndo = true
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        prompt.setAccessibilityLabel("Message this chat. Enter to send or steer. Shift Enter for a new line.")
        prompt.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.card.focused = focused && self.isActivePane && self.view.window?.isKeyWindow == true
            if focused { self.onFocus?() }
        }
        prompt.onCaretVisibilityChange = { [weak card] visible in card?.caretVisible = visible }
        prompt.onSend = { [weak self] in self?.onSend?() }
        prompt.registerForDraggedTypes(prompt.registeredDraggedTypes + [.fileURL, .png, .tiff])
        let onDrop: (NSPasteboard, NSPoint) -> Bool = { [weak self] pasteboard, location in
            guard let self else { return false }
            let sources = ChatAttachment.sources(from: pasteboard)
            guard !sources.isEmpty else { return false }
            self.importImages(sources, from: location == .zero ? nil : self.view.convert(location, from: nil))
            return true
        }
        card.onImageDrop = onDrop; prompt.onImageDrop = onDrop
        let onDrag: (Bool) -> Void = { [weak self] in self?.showImageDrop($0) }
        card.onImageDrag = onDrag; prompt.onImageDrag = onDrag
        stream.onSelection = { [weak self] selection in
            guard let self else { return }
            self.prompt.string = "Explain this statement and show the evidence behind it:\n\n\(selection)"
            self.view.window?.makeFirstResponder(self.prompt)
        }
        sendButton.target = self; sendButton.action = #selector(send); sendButton.bezelStyle = .rounded; sendButton.bezelColor = .controlAccentColor; sendButton.font = Typography.interface
        stopButton.target = self; stopButton.action = #selector(stop); stopButton.bezelStyle = .inline; stopButton.font = Typography.caption
        attachmentStrip.orientation = .horizontal; attachmentStrip.spacing = 8; attachmentStrip.alignment = .centerY
        attachmentScroll.documentView = attachmentStrip; attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true; attachmentScroll.autohidesScrollers = true
        attachmentStatus.font = Typography.metadata; attachmentStatus.textColor = FeedPalette.muted
        attachmentStatus.lineBreakMode = .byTruncatingTail
        attachmentStatus.allowsExpansionToolTips = true
        attachmentStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        attachmentStatus.stringValue = ""
        let controls = NSStackView(views: [attachmentStatus, NSView(), stopButton, sendButton]); controls.orientation = .horizontal; controls.spacing = 8
        for child in [attachmentScroll, scroll, controls, dropHint] { child.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(child) }
        dropHint.alphaValue = 0
        let conversationDivider = WorkspaceSurface(fill: FeedPalette.line)
        conversationDivider.setAccessibilityElement(false)
        let topDivider = WorkspaceSurface(fill: FeedPalette.line)
        topDivider.setAccessibilityElement(false)
        for child in [topDivider, tabBar, stream.view, conversationDivider, conversation, card, conversationHandle] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        conversationHeight = makeConversationHeight(conversationFraction)
        let conversationMinimum = conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSplit.minimumHeight)
        conversationMinimum.priority = .init(999)
        let streamMinimum = stream.view.heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSplit.minimumStreamHeight)
        streamMinimum.priority = .init(999)
        conversationHandle.onBegin = { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.conversationDragStart = self.conversation.frame.height
            self.onFocus?()
        }
        conversationHandle.onDrag = { [weak self] delta in self?.resizeConversation(toHeight: (self?.conversationDragStart ?? 0) + delta) }
        conversationHandle.onEnd = { [weak self] in
            guard let self else { return }
            ConversationSplit.store(self.conversationFraction)
        }
        conversationHandle.onReset = { [weak self] in
            self?.setConversationFraction(ConversationSplit.defaultFraction)
            ConversationSplit.store(ConversationSplit.defaultFraction)
        }
        cardHeight = card.heightAnchor.constraint(equalToConstant: 120)
        attachmentHeight = attachmentScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: view.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor), topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4), tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PaneSpacing.textInset), tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PaneSpacing.textInset), tabBar.heightAnchor.constraint(equalToConstant: tabsOnly ? 38 : 72),
            stream.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 2), stream.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), stream.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), stream.view.bottomAnchor.constraint(equalTo: conversation.topAnchor, constant: -PaneSpacing.gap),
            conversationDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversationDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationDivider.centerYAnchor.constraint(equalTo: conversation.topAnchor, constant: -2), conversationDivider.heightAnchor.constraint(equalToConstant: 1),
            conversation.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversation.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversation.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -PaneSpacing.gap),
            conversationHeight, conversationMinimum, streamMinimum,
            conversationHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversationHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationHandle.centerYAnchor.constraint(equalTo: conversationDivider.centerYAnchor), conversationHandle.heightAnchor.constraint(equalToConstant: ConversationResizeHandle.thickness),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PaneSpacing.composerInset), card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PaneSpacing.composerInset), card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), cardHeight,
            attachmentScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: PaneSpacing.gap), attachmentScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -PaneSpacing.gap), attachmentScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 2), attachmentHeight,
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2), scroll.topAnchor.constraint(equalTo: attachmentScroll.bottomAnchor, constant: 2), scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -6),
            dropHint.leadingAnchor.constraint(equalTo: card.leadingAnchor), dropHint.trailingAnchor.constraint(equalTo: card.trailingAnchor), dropHint.topAnchor.constraint(equalTo: card.topAnchor), dropHint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), controls.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), controls.heightAnchor.constraint(equalToConstant: 28), controls.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
    }
    private(set) var isActivePane = false

    private func makeConversationHeight(_ fraction: CGFloat) -> NSLayoutConstraint {
        let constraint = conversation.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: fraction)
        // Just below required so a short window squeezes the split instead of breaking layout.
        constraint.priority = .init(998)
        return constraint
    }

    /// Sets the share of the pane height given to the conversation. The split
    /// keeps its proportion as the window resizes.
    func setConversationFraction(_ fraction: CGFloat) {
        loadViewIfNeeded()
        let value = ConversationSplit.clamp(fraction)
        guard value != conversationFraction else { return }
        conversationFraction = value
        conversationHeight.isActive = false
        conversationHeight = makeConversationHeight(value)
        conversationHeight.isActive = true
        view.needsLayout = true
        // Track the pointer in this event, including when the next drag arrives
        // before AppKit's next layout pass.
        view.layoutSubtreeIfNeeded()
    }

    /// Resizes the conversation to a height in points, keeping room for the
    /// stream above and a readable conversation below.
    func resizeConversation(toHeight height: CGFloat) {
        loadViewIfNeeded()
        let total = view.bounds.height
        guard total > 0 else { return }
        let fixed = total - stream.view.frame.height - conversation.frame.height
        let ceiling = max(ConversationSplit.minimumHeight, total - fixed - ConversationSplit.minimumStreamHeight)
        let clamped = min(ceiling, max(ConversationSplit.minimumHeight, height))
        setConversationFraction(clamped / total)
    }

    func updateSplitAvailability(split: Bool, stack: Bool) {
        loadViewIfNeeded()
        splitButton.isEnabled = split
        stackButton.isEnabled = stack
        splitButton.toolTip = split ? "Add a pane to the right" : "No room for another pane (maximum 12 columns)"
        stackButton.toolTip = stack ? "Add a pane below" : "No room for another pane (maximum 6 rows)"
    }

    func updateFocusAppearance(active: Bool) {
        loadViewIfNeeded()
        isActivePane = active
        // Focus belongs to the message box, not a wash over the entire chat.
        let background = FeedPalette.canvas
        (view as? WorkspaceSurface)?.fill = background
        conversation.fill = background
        conversation.needsDisplay = true
        stream.setCanvasColor(background)
        card.focused = active && view.window?.isKeyWindow == true && view.window?.firstResponder === prompt
    }

    func applyInterfaceStyle() {
        loadViewIfNeeded()
        (view as? PaneSurface)?.applyInterfaceStyle()
        prompt.font = InterfaceStyle.isMatrix ? Typography.prose(ofSize: Typography.conversation.pointSize) : Typography.conversation
        prompt.insertionPointColor = InterfaceStyle.isMatrix ? FeedPalette.green : .textColor
        updateFocusAppearance(active: isActivePane)
        stream.applyInterfaceStyle()
        conversation.applyInterfaceStyle()
    }

    func updateTabs(_ chats: [(Int, Session)], isSplit: Bool) {
        loadViewIfNeeded()
        closePaneButton.isEnabled = isSplit
        for child in tabs.arrangedSubviews { tabs.removeArrangedSubview(child); child.removeFromSuperview() }
        var width: CGFloat = 0
        var selectedItem: ChatTabItem?
        for (index, chat) in chats {
            let title = ChatTabTitle.display(chat.title)
            let item = ChatTabItem(title: title, selected: chat === session, isRunning: chat.turn != nil,
                                   dragPayload: tabsOnly ? nil : ChatTabDrag(sessionID: chat.id, columnID: columnID),
                                   onDragEnded: { [weak self] in self?.onTabDragEnded?() },
                                   onSelect: { [weak self] in self?.onSelectChat?(index) },
                                   onClose: { [weak self] in self?.onCloseChat?(index) })
            let titleWidth = (title as NSString).size(withAttributes: [.font: Typography.interfaceEmphasis]).width
            let length = min(240, max(116, ceil(titleWidth) + 46 + (chat.turn == nil ? 0 : 13)))
            tabs.addArrangedSubview(item); item.widthAnchor.constraint(equalToConstant: length).isActive = true; item.heightAnchor.constraint(equalToConstant: 38).isActive = true
            if chat === session { selectedItem = item }
            width += length + tabs.spacing
        }
        tabs.frame = NSRect(x: 0, y: 0, width: max(1, width - tabs.spacing), height: 38)
        if revealedSessionID != session?.id {
            // Reveal newly selected chats immediately, without moving the strip
            // on background status updates while the user browses other tabs.
            view.layoutSubtreeIfNeeded()
            if let selectedItem { selectedItem.scrollToVisible(selectedItem.bounds) }
            revealedSessionID = session?.id
        }
    }
    func display(_ session: Session?, draft: String = "", attachments: [ChatAttachment] = []) {
        loadViewIfNeeded(); self.session?.detach(stream); self.session = session
        prompt.string = draft; prompt.needsDisplay = true
        // Undo history belongs to the previous tab's draft.
        prompt.undoManager?.removeAllActions(withTarget: prompt)
        setAttachments(attachments)
        stream.replace([]); session?.attach(stream); refresh()
    }
    var tabOffset: Double { Double(tabScroll.contentView.bounds.minX) }
    func restoreTabOffset(_ offset: Double) {
        guard offset.isFinite else { return }
        view.layoutSubtreeIfNeeded()
        let limit = max(0, tabs.bounds.width - tabScroll.contentSize.width)
        tabScroll.contentView.scroll(to: NSPoint(x: min(limit, max(0, CGFloat(offset))), y: 0))
        tabScroll.reflectScrolledClipView(tabScroll.contentView)
    }
    func refresh() {
        sendButton.title = session?.turn == nil ? "Send  ↵" : "Steer  ↵"
        stopButton.isEnabled = session?.turn != nil
        prompt.setAccessibilityLabel("Message \(session?.title ?? "this chat"). Enter to send or steer. Shift Enter for a new line.")
    }
    func setAttachments(_ values: [ChatAttachment], animated: Bool = false, from origin: NSPoint? = nil) {
        loadViewIfNeeded()
        let previous = Set(attachments.map(\.id))
        attachments = values
        for child in attachmentStrip.arrangedSubviews { attachmentStrip.removeArrangedSubview(child); child.removeFromSuperview() }
        attachmentTiles.removeAll()
        for item in values {
            let tile = AttachmentTile(item) { [weak self] in
                guard let self else { return }
                self.setAttachments(self.attachments.filter { $0.id != item.id }, animated: true)
                self.onDraftChange?()
            }
            attachmentTiles[item.id] = tile; attachmentStrip.addArrangedSubview(tile)
        }
        let width = CGFloat(values.count) * 108 - (values.isEmpty ? 0 : 8)
        attachmentStrip.frame = NSRect(x: 0, y: 0, width: max(1, width), height: 80)
        attachmentHeight.constant = values.isEmpty ? 0 : 86
        cardHeight.constant = values.isEmpty ? 120 : 206
        attachmentScroll.isHidden = values.isEmpty
        attachmentStatus.stringValue = values.isEmpty ? "" : "\(values.count) image\(values.count == 1 ? "" : "s") attached"
        attachmentStatus.textColor = .secondaryLabelColor
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion ? 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            context.allowsImplicitAnimation = motion
            view.layoutSubtreeIfNeeded()
        }
        guard motion else { return }
        if let last = values.last, let tile = attachmentTiles[last.id] { tile.scrollToVisible(tile.bounds) }
        for item in values where !previous.contains(item.id) {
            guard let tile = attachmentTiles[item.id] else { continue }
            let end = tile.convert(tile.preview.frame, to: view)
            let flight = NSImageView(frame: origin.map { NSRect(x: $0.x - 56, y: $0.y - 42, width: 112, height: 84) } ?? end.offsetBy(dx: 0, dy: -12))
            flight.image = tile.preview.image; flight.imageScaling = .scaleProportionallyUpOrDown
            flight.wantsLayer = true; flight.layer?.cornerRadius = 8; flight.layer?.masksToBounds = true
            flight.alphaValue = origin == nil ? 0 : 1
            tile.preview.alphaValue = 0; view.addSubview(flight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                flight.animator().frame = end; flight.animator().alphaValue = 1
            } completionHandler: {
                tile.preview.alphaValue = 1; flight.removeFromSuperview()
            }
        }
    }
    private func showImageDrop(_ visible: Bool) {
        guard card.receivingImages != visible else { return }
        card.receivingImages = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            dropHint.animator().alphaValue = visible ? 1 : 0
        }
    }
    func importImages(_ sources: [ChatAttachment.Source], from origin: NSPoint? = nil) {
        guard !isImportingImages else { return }
        let remaining = ChatAttachment.maximumCount - attachments.count
        guard remaining > 0 else {
            attachmentStatus.stringValue = "Up to 8 images per message"; attachmentStatus.textColor = .systemOrange; return
        }
        onPrepareAttachment?()
        let target = session?.id
        isImportingImages = true
        attachmentStatus.stringValue = "Adding images…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var items: [ChatAttachment] = [], errors: [String] = []
                for source in sources.prefix(remaining) {
                    do { items.append(try ChatAttachment.importImage(source)) }
                    catch { errors.append(error.localizedDescription) }
                }
                if sources.count > remaining { errors.append("Up to 8 images per message") }
                return (items, errors)
            }.value
            guard let self else { return }
            self.isImportingImages = false
            if self.session?.id == target {
                self.setAttachments(self.attachments + result.0, animated: true, from: origin)
                self.view.window?.makeFirstResponder(self.prompt)
                self.onDraftChange?()
                if let error = result.1.first {
                    self.attachmentStatus.stringValue = error; self.attachmentStatus.textColor = .systemOrange
                    self.attachmentStatus.toolTip = result.1.joined(separator: "\n")
                }
            } else if let target { self.onImportedAttachments?(target, result.0) }
        }
    }
    @objc private func send() { onSend?() }
    @objc private func stop() { onStop?() }
    @objc private func newChat() { onNewChat?() }
    @objc private func selectChat(_ sender: NSButton) { onSelectChat?(sender.tag) }
    @objc private func splitRight() { onSplit?() }
    @objc private func splitBelow() { onSplitBelow?() }
    @objc private func closePane() { onClosePane?() }
    func textDidChange(_ notification: Notification) { onDraftChange?() }
}
