import AppKit
import QuartzCore

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
final class ChatTitleButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }
    private static let textLeading: CGFloat = 28
    private static let verticalInset: CGFloat = 6
    var dragPayload: ChatTabDrag?
    var onDragEnded: (() -> Void)?
    var isRunning = false
    var modelBrand: ModelBrand = .openAI { didSet { needsDisplay = true } }

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
        func find(_ view: NSView) -> ChatTitleButton? {
            if let tab = view as? ChatTitleButton, tab.dragPayload?.sessionID == sessionID { return tab }
            for child in view.subviews { if let tab = find(child) { return tab } }
            return nil
        }
        guard let tab = find(root) else { return nil }
        root.layoutSubtreeIfNeeded()
        return root.convert(tab.bounds, from: tab)
    }

    var isHovering = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        drawTitle()
        drawModelIdentity()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
    }
    private func drawModelIdentity() {
        let side: CGFloat = modelBrand == .gemini || modelBrand == .local ? 20 : 18
        let top = Self.verticalInset + (20 - side) / 2
        let rect = NSRect(x: (20 - side) / 2,
                          y: isFlipped ? bounds.minY + top : bounds.maxY - top - side,
                          width: side, height: side)
        ModelBrand.draw(modelBrand.image, in: rect,
                        color: state == .on || isHovering ? FeedPalette.text : FeedPalette.muted)
    }
    private var titleLabel: NSAttributedString {
        let font = InterfaceTypography.font(state == .on ? Typography.paneTitle : Typography.paneTitleUnselected)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping; style.alignment = .natural
        return NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: FeedPalette.text, .paragraphStyle: style])
    }
    private func titleHeight(for width: CGFloat) -> CGFloat {
        let font = InterfaceTypography.font(state == .on ? Typography.paneTitle : Typography.paneTitleUnselected)
        let maximum = ceil(NSLayoutManager().defaultLineHeight(for: font) * 2)
        let measured = ceil(titleLabel.boundingRect(with: NSSize(width: max(1, width - Self.textLeading),
                                                                 height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return min(maximum, measured)
    }
    func fittingHeight(for width: CGFloat) -> CGFloat {
        max(20, titleHeight(for: width)) + Self.verticalInset * 2
    }
    private func drawTitle() {
        let width = max(0, bounds.width - Self.textLeading)
        guard width > 0 else { return }
        let height = min(titleHeight(for: bounds.width), max(0, bounds.height - Self.verticalInset * 2))
        let rect = NSRect(x: Self.textLeading,
                          y: isFlipped ? bounds.minY + Self.verticalInset : bounds.maxY - Self.verticalInset - height,
                          width: width, height: height)
        titleLabel.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// One conversation, its title, activity, draft, and send/stop controls.
@MainActor
final class ChatColumn: NSViewController, NSTextViewDelegate {
    let columnID: UUID
    init(id: UUID = UUID()) {
        columnID = id; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    let stream = StreamPane()
    let conversation = ConversationView(frame: .zero)
    let prompt = ComposerTextView()
    let sendButton = ThemedButton(title: "Send  ↵", target: nil, action: nil)
    private let stopButton = ThemedButton(title: "Stop", target: nil, action: nil)
    let chatTitle = ChatTitleButton(title: "New chat", target: nil, action: nil)
    private let splitButton = NSButton()
    private let stackButton = NSButton()
    private let closePaneButton = QuietIconButton()
    private let card = ComposerCard()
    private let attachmentStrip = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let attachmentStatus = NSTextField(labelWithString: "")
    private let dropHint = ImageDropHint()
    private var cardHeight: NSLayoutConstraint!
    private var conversationHeight: NSLayoutConstraint!
    private var conversationMinimum: NSLayoutConstraint!
    private var conversationCollapsed: NSLayoutConstraint!
    private var streamCollapsed: NSLayoutConstraint!
    private var streamMinimum: NSLayoutConstraint!
    private var conversationGap: NSLayoutConstraint!
    private let conversationDivider = WorkspaceSurface(fill: FeedPalette.line)
    private let moreButton = QuietIconButton()
    private let headerActions = NSStackView()
    private let topDivider = WorkspaceSurface(fill: FeedPalette.line)
    private var titleHeaderTop: NSLayoutConstraint!
    private var titleHeaderHeight: NSLayoutConstraint!
    private var streamTop: NSLayoutConstraint!
    private var streamBottom: NSLayoutConstraint!
    private var conversationOnlyTop: NSLayoutConstraint!
    private var conversationOnlyTitleEdge: NSLayoutConstraint!
    private var conversationOnlyActions: [NSLayoutConstraint] = []
    private(set) var displayMode: ChatDisplayMode = .showLogs
    private var cardBottom: NSLayoutConstraint!
    private var paneButtonWidths: [NSLayoutConstraint] = []
    private var edgeInsets: [NSLayoutConstraint] = []
    private var composerInsets: [NSLayoutConstraint] = []
    /// Follows the pane's own size, so a cramped display compacts chrome and
    /// text while a roomy one returns to the reader's chosen sizes.
    private(set) var density = PaneDensity.regular
    private let conversationHandle = ConversationResizeHandle()
    private var conversationDragStart: CGFloat = 0
    private(set) var conversationFraction = ConversationSplit.stored()
    private var attachmentHeight: NSLayoutConstraint!
    private var attachmentTiles: [UUID: AttachmentTile] = [:]
    private(set) var attachments: [ChatAttachment] = []
    private(set) var isImportingImages = false
    var session: Session?
    private(set) var transcriptDeferred = false
    var streamStates: [UUID: StreamViewState] = [:]
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSplit: (() -> Void)?
    var onSplitBelow: (() -> Void)?
    var onSplitAbove: (() -> Void)?
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?
    var canMoveLeft = false
    var canMoveRight = false
    var onClosePane: (() -> Void)?
    var onChatDragEnded: (() -> Void)?
    var onDraftChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var onPrepareAttachment: (() -> Void)?
    var onImportedAttachments: ((UUID, [ChatAttachment]) -> Void)?
    /// Move a waiting message to a model on this Mac.
    var onAnswerLocally: ((UUID) -> Void)?

    /// Take a message that has not been sent back into the composer.
    func cancelQueuedChat(_ id: UUID) {
        guard let session, let message = try? session.withdrawQueuedChat(id) else { return }
        let draft = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.string = draft.isEmpty ? message.text : message.text + "\n\n" + prompt.string
        prompt.needsDisplay = true
        let existing = Set(attachments.map(\.id))
        let restored = message.attachments.filter { !existing.contains($0.id) && FileManager.default.isReadableFile(atPath: $0.path) }
        if !restored.isEmpty { setAttachments(Array((restored + attachments).prefix(ChatAttachment.maximumCount)), animated: true) }
        view.window?.makeFirstResponder(prompt)
        onDraftChange?()
        refresh()
    }

    override func loadView() {
        view = PaneSurface(); addChild(stream)
        stream.onConversationAppend = { [weak self] record, merging in
            guard let self else { return }
            self.conversation.append(record, merging: merging, resumeFollowing: self.session?.isDisplayedInMultiplePanes != true)
        }
        stream.onConversationReplace = { [weak self] in self?.conversation.replace($0) }
        stream.onConversationQueueUpdate = { [weak self] in self?.conversation.replace($0, preservingPosition: true) }
        conversation.onRetryQueuedChat = { [weak self] in self?.session?.resumeMessageQueue(retryBlocked: true) }
        conversation.onCancelQueuedChat = { [weak self] in self?.cancelQueuedChat($0) }
        conversation.onAnswerQueuedChatLocally = { [weak self] in self?.onAnswerLocally?($0) }
        stream.onConversationFinalize = { [weak self] in self?.conversation.finalizeResponse($0) }
        chatTitle.isBordered = false
        chatTitle.target = self; chatTitle.action = #selector(focusChat)
        chatTitle.state = .on
        chatTitle.onDragEnded = { [weak self] in self?.onChatDragEnded?() }
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Chat options")
        moreButton.bezelStyle = .texturedRounded; moreButton.imagePosition = .imageOnly
        moreButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        moreButton.target = self; moreButton.action = #selector(showPaneMenu(_:))
        moreButton.toolTip = "Split, move, text size and more"
        moreButton.setAccessibilityLabel("Chat options")
        moreButton.isQuiet = true; moreButton.isHidden = true
        NSLayoutConstraint.activate([moreButton.widthAnchor.constraint(equalToConstant: 30), moreButton.heightAnchor.constraint(equalToConstant: 30)])
        splitButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split right")
        splitButton.title = "Split"
        splitButton.target = self; splitButton.action = #selector(splitRight)
        splitButton.toolTip = "Open a new chat to the right"
        splitButton.setAccessibilityLabel("Split right")
        stackButton.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Split below")
        stackButton.title = "Stack"
        stackButton.target = self; stackButton.action = #selector(splitBelow)
        stackButton.toolTip = "Open a new chat below"
        stackButton.setAccessibilityLabel("Split below")
        closePaneButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close chat")
        closePaneButton.target = self; closePaneButton.action = #selector(closePane)
        closePaneButton.toolTip = "Close this chat. It stays in Chats so you can reopen it."
        closePaneButton.setAccessibilityLabel("Close chat")
        for button in [splitButton, stackButton, closePaneButton] {
            button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        closePaneButton.isQuiet = true
        // Fixed widths, so a pane narrower than its labelled buttons yields
        // gracefully until the compact chrome takes over.
        paneButtonWidths = [splitButton.widthAnchor.constraint(equalToConstant: 72),
                            stackButton.widthAnchor.constraint(equalToConstant: 72),
                            closePaneButton.widthAnchor.constraint(equalToConstant: 30)]
        for constraint in paneButtonWidths { constraint.priority = .init(999); constraint.isActive = true }
        for button in [splitButton, stackButton] {
            button.imagePosition = .imageLeading
            button.font = Typography.caption
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        for view in [splitButton, stackButton, moreButton] { headerActions.addArrangedSubview(view) }
        headerActions.orientation = .horizontal; headerActions.alignment = .centerY; headerActions.spacing = 8
        headerActions.setContentHuggingPriority(.required, for: .horizontal)
        headerActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        stream.installHeaderActions(headerActions)
        let titleHeader = chatTitle
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
        conversationDivider.setAccessibilityElement(false)
        topDivider.setAccessibilityElement(false)
        for child in [topDivider, titleHeader, closePaneButton, stream.view, conversationDivider, conversation, card, conversationHandle] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        conversationHeight = makeConversationHeight(conversationFraction)
        conversationMinimum = conversation.heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSplit.minimumHeight)
        conversationMinimum.priority = .init(999)
        conversationCollapsed = conversation.heightAnchor.constraint(equalToConstant: 0)
        streamCollapsed = stream.view.heightAnchor.constraint(equalToConstant: 0)
        conversationGap = conversation.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -PaneSpacing.gap)
        edgeInsets = [titleHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PaneSpacing.textInset),
                      titleHeader.trailingAnchor.constraint(equalTo: closePaneButton.leadingAnchor, constant: -8)]
        composerInsets = [card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PaneSpacing.composerInset),
                          card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PaneSpacing.composerInset)]
        streamMinimum = stream.view.heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSplit.minimumStreamHeight)
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
        titleHeaderTop = titleHeader.topAnchor.constraint(equalTo: view.topAnchor, constant: 4)
        titleHeaderHeight = titleHeader.heightAnchor.constraint(equalToConstant: 44)
        streamTop = stream.view.topAnchor.constraint(equalTo: titleHeader.bottomAnchor, constant: 2)
        streamBottom = stream.view.bottomAnchor.constraint(equalTo: conversation.topAnchor, constant: -PaneSpacing.gap)
        conversationOnlyTop = conversation.topAnchor.constraint(equalTo: titleHeader.bottomAnchor, constant: 12)
        conversationOnlyTitleEdge = titleHeader.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -8)
        conversationOnlyActions = [
            moreButton.trailingAnchor.constraint(equalTo: closePaneButton.leadingAnchor, constant: -4),
            moreButton.topAnchor.constraint(equalTo: titleHeader.topAnchor, constant: 1)
        ]
        cardBottom = card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: view.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor), topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),
            titleHeaderTop, edgeInsets[0], edgeInsets[1], titleHeaderHeight,
            closePaneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PaneSpacing.textInset),
            closePaneButton.topAnchor.constraint(equalTo: titleHeader.topAnchor, constant: 1),
            streamTop, stream.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), stream.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), streamBottom,
            conversationDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversationDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationDivider.centerYAnchor.constraint(equalTo: conversation.topAnchor, constant: -2), conversationDivider.heightAnchor.constraint(equalToConstant: 1),
            conversation.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversation.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationGap,
            conversationHeight, conversationMinimum, streamMinimum,
            conversationHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor), conversationHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationHandle.centerYAnchor.constraint(equalTo: conversationDivider.centerYAnchor), conversationHandle.heightAnchor.constraint(equalToConstant: ConversationResizeHandle.thickness),
            composerInsets[0], composerInsets[1], cardBottom, cardHeight,
            attachmentScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: PaneSpacing.gap), attachmentScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -PaneSpacing.gap), attachmentScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 2), attachmentHeight,
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2), scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2), scroll.topAnchor.constraint(equalTo: attachmentScroll.bottomAnchor, constant: 2), scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -6),
            dropHint.leadingAnchor.constraint(equalTo: card.leadingAnchor), dropHint.trailingAnchor.constraint(equalTo: card.trailingAnchor), dropHint.topAnchor.constraint(equalTo: card.topAnchor), dropHint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), controls.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), controls.heightAnchor.constraint(equalToConstant: 28), controls.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        applyChrome()
        applyConversationVisibility()
        InterfaceTypography.apply(to: view)
    }
    private(set) var isActivePane = false

    // MARK: Breathe

    /// Titles stay above the shared status, branch and action row in every style.
    private func applyChrome() {
        let breathe = InterfaceStyle.isBreathe
        topDivider.isHidden = breathe
        for button in [splitButton, stackButton] { button.isHidden = true }
        closePaneButton.isHidden = false
        moreButton.isHidden = false
        titleHeaderTop.constant = PaneSpacing.textInset - 4
        streamTop.constant = 12
        cardBottom.constant = breathe ? -Breathe.composerBottom : -12
        stopButton.isHidden = breathe && session?.turn == nil
        updateHeader()
    }

    @objc private func showPaneMenu(_ sender: NSButton) {
        let menu = makePaneMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    func makePaneMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                 enabled: Bool = true, checked: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self
            item.isEnabled = enabled; item.state = checked ? .on : .off
        }
        add("New Chat", #selector(newChat), key: "n")
        do {
            menu.addItem(.separator())
            add("Split Right", #selector(splitRight), key: "p", enabled: splitButton.isEnabled)
            add("Split Above", #selector(splitAbove), enabled: stackButton.isEnabled)
            add("Split Below", #selector(splitBelow), key: "\\", modifiers: [.command, .shift], enabled: stackButton.isEnabled)
            add("Move Left", #selector(moveCurrentChatLeft), enabled: canMoveLeft)
            add("Move Right", #selector(moveCurrentChatRight), enabled: canMoveRight)
        }
        menu.addItem(.separator())
        if displayMode == .showLogs {
            add("Follow Live Activity", #selector(toggleFollowing), checked: stream.followsLive)
            add("Find in Activity…", #selector(findInActivity), key: "f")
            add("Ask About Selection", #selector(askAboutSelection), enabled: stream.hasTextSelection)
        } else {
            add("Find in Conversation…", #selector(findInActivity), key: "f")
        }
        menu.addItem(.separator())
        add("Larger Text", #selector(largerText), key: "+", enabled: stream.canEnlargeText)
        add("Smaller Text", #selector(smallerText), key: "-", enabled: stream.canShrinkText)
        add("Actual Size", #selector(actualTextSize), key: "0")
        menu.addItem(.separator())
        add("Close Chat", #selector(closeCurrentChat), key: "w", enabled: session != nil)
        return menu
    }
    @objc private func closeCurrentChat() { onClosePane?() }
    @objc private func focusChat() { onFocus?(); view.window?.makeFirstResponder(prompt) }
    @objc private func toggleFollowing() {
        if stream.followsLive { stream.pauseLiveActivity() } else { stream.returnToLatest() }
    }
    @objc private func findInActivity() {
        onFocus?()
        if stream.view.isHidden { conversation.find() } else { stream.find() }
    }
    @objc private func askAboutSelection() { stream.askAboutSelection() }
    @objc private func largerText() { stream.changeFont(1) }
    @objc private func smallerText() { stream.changeFont(-1) }
    @objc private func actualTextSize() { stream.resetFont() }

    override func viewDidLayout() {
        super.viewDidLayout()
        let next = PaneDensity.resolve(size: view.bounds.size, current: density)
        if next != density { setDensity(next) }
        updateTitleHeight()
    }

    private func updateTitleHeight() {
        guard let titleHeaderHeight, view.bounds.width > 0 else { return }
        let actions: CGFloat = displayMode == .justChat ? 72 : 38
        let height = chatTitle.fittingHeight(for: max(1, view.bounds.width - PaneSpacing.textInset * 2 - actions))
        if titleHeaderHeight.constant != height { titleHeaderHeight.constant = height }
    }

    /// Compact the chrome and scale the text for the room this pane has.
    func setDensity(_ value: PaneDensity) {
        loadViewIfNeeded()
        guard value != density else { return }
        let previous = density
        density = value
        let compact = value.hasCompactChrome
        for button in [splitButton, stackButton] { button.imagePosition = compact ? .imageOnly : .imageLeading }
        let tiny = value.width == .tiny
        let widths: [CGFloat] = compact ? [30, 30, 30] : [72, 72, 30]
        for (constraint, width) in zip(paneButtonWidths, widths) { constraint.constant = width }
        headerActions.spacing = tiny ? 4 : 8
        let composerInset = tiny ? 6 : PaneSpacing.composerInset
        composerInsets[0].constant = composerInset; composerInsets[1].constant = -composerInset
        applyComposerMetrics()
        if value.isShort != previous.isShort { applyConversationVisibility() }
        if value.textScale != previous.textScale || compact != previous.hasCompactChrome {
            stream.setDensity(value)
            conversation.textScale = value.textScale
        }
        view.needsLayout = true
    }

    private var composerPointSize: CGFloat {
        max(10, (Typography.conversation.pointSize * density.textScale).rounded())
    }
    private func applyComposerMetrics() {
        let size = composerPointSize
        prompt.font = InterfaceStyle.isMatrix ? Typography.prose(ofSize: size) : .systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * 1.5
        prompt.defaultParagraphStyle = paragraph
        prompt.typingAttributes[.paragraphStyle] = paragraph
        if let storage = prompt.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        prompt.textContainerInset = density.width == .tiny ? NSSize(width: 8, height: 6) : NSSize(width: 12, height: 10)
        cardHeight.constant = composerHeight(hasAttachments: !attachments.isEmpty)
    }
    private func composerHeight(hasAttachments: Bool) -> CGFloat {
        let base: CGFloat = density.isShort || density.width == .tiny ? 92 : 120
        return base + (hasAttachments ? 86 : 0)
    }
    /// A short pane keeps the full activity stream and the composer; the
    /// readable conversation returns as soon as there is height for both.
    private func applyConversationVisibility() {
        let justChat = displayMode == .justChat
        let logsCollapsed = conversationFraction == ConversationSplit.maximumFraction
        let hidden = density.isShort && !justChat && !logsCollapsed
        stream.view.isHidden = justChat || logsCollapsed
        streamBottom.isActive = !justChat
        conversationOnlyTop.isActive = justChat
        streamCollapsed.isActive = !justChat && logsCollapsed
        streamMinimum.isActive = !justChat && !logsCollapsed
        conversation.isHidden = hidden
        conversationDivider.isHidden = hidden || justChat
        conversationHandle.isHidden = hidden || justChat
        if hidden {
            conversationHeight.isActive = false; conversationMinimum.isActive = false
            conversationCollapsed.isActive = true
        } else {
            conversationCollapsed.isActive = false
            conversationMinimum.isActive = !justChat; conversationHeight.isActive = !justChat && !logsCollapsed
        }
        conversationGap.constant = hidden ? 0 : -PaneSpacing.gap
    }

    func setDisplayMode(_ mode: ChatDisplayMode) {
        loadViewIfNeeded()
        guard mode != displayMode else { return }
        displayMode = mode
        let justChat = mode == .justChat
        if justChat {
            headerActions.removeArrangedSubview(moreButton)
            moreButton.removeFromSuperview()
            view.addSubview(moreButton)
            edgeInsets[1].isActive = false
            conversationOnlyTitleEdge.isActive = true
            NSLayoutConstraint.activate(conversationOnlyActions)
        } else {
            NSLayoutConstraint.deactivate(conversationOnlyActions)
            conversationOnlyTitleEdge.isActive = false
            moreButton.removeFromSuperview()
            headerActions.addArrangedSubview(moreButton)
            edgeInsets[1].isActive = true
        }
        applyConversationVisibility()
        updateTitleHeight()
        view.needsLayout = true
    }

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
        applyConversationVisibility()
        view.needsLayout = true
        // Track the pointer in this event, including when the next drag arrives
        // before AppKit's next layout pass.
        view.layoutSubtreeIfNeeded()
    }

    /// Dragging to the top collapses the logs while leaving the handle available
    /// to reveal them again. The endpoint stays collapsed when the pane resizes.
    func resizeConversation(toHeight height: CGFloat) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let total = view.bounds.height
        guard total > 0 else { return }
        let fixed = total - stream.view.frame.height - conversation.frame.height
        let available = total - fixed
        // Snap closed near the top; a visible log pane needs room for its toolbar.
        // Keeping that minimum avoids AppKit enlarging the host during a drag.
        if height >= available - ConversationSplit.minimumStreamHeight / 2 {
            setConversationFraction(ConversationSplit.maximumFraction)
            return
        }
        let ceiling = max(ConversationSplit.minimumHeight, available - ConversationSplit.minimumStreamHeight)
        let clamped = min(ceiling, max(ConversationSplit.minimumHeight, height))
        setConversationFraction(clamped / total)
    }

    func updateSplitAvailability(split: Bool, stack: Bool) {
        loadViewIfNeeded()
        splitButton.isEnabled = split
        stackButton.isEnabled = stack
        splitButton.toolTip = "Open a new chat to the right"
        stackButton.toolTip = "Open a new chat below"
    }

    func updateFocusAppearance(active: Bool) {
        loadViewIfNeeded()
        isActivePane = active
        sendButton.alphaValue = active ? 1 : 0.7
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
        applyChrome()
        applyComposerMetrics()
        prompt.insertionPointColor = InterfaceStyle.isMatrix ? FeedPalette.green : .textColor
        updateFocusAppearance(active: isActivePane)
        stream.applyInterfaceStyle()
        conversation.applyInterfaceStyle()
        InterfaceTypography.apply(to: view)
    }

    func updateHeader() {
        loadViewIfNeeded()
        let title = session.map { ChatTabTitle.display($0.sidebarTitle) } ?? "New chat"
        chatTitle.title = title
        chatTitle.isRunning = session?.turn != nil
        chatTitle.modelBrand = ModelBrand(provider: session?.provider ?? AgentProvider.selected)
        chatTitle.dragPayload = session.map { ChatTabDrag(sessionID: $0.id, columnID: columnID) }
        let identity = session.map { "\(chatTitle.modelBrand.name) · \($0.inferenceSettings.displayName)" } ?? ""
        chatTitle.toolTip = title + (identity.isEmpty ? "" : "\n" + identity) + "\nDrag beside another chat to move"
        chatTitle.setAccessibilityLabel(title + (identity.isEmpty ? "" : ", " + identity) + (chatTitle.isRunning ? ", working" : ""))
        chatTitle.menu = makePaneMenu()
        chatTitle.needsDisplay = true
        updateTitleHeight()
    }
    func display(_ session: Session?, draft: String = "", attachments: [ChatAttachment] = [], deferTranscript: Bool = false) {
        transcriptDeferred = deferTranscript && session != nil
        loadViewIfNeeded(); self.session?.detach(stream); self.session = session
        prompt.string = draft; prompt.needsDisplay = true
        // Undo history belongs to the previous conversation's draft.
        prompt.undoManager?.removeAllActions(withTarget: prompt)
        setAttachments(attachments)
        stream.replace([])
        if !transcriptDeferred { session?.attach(stream) }
        refresh(); updateHeader()
    }
    func attachDeferredTranscript() {
        guard transcriptDeferred else { return }
        transcriptDeferred = false
        session?.attach(stream)
    }
    func refresh() {
        sendButton.title = session?.turn == nil ? "Send  ↵" : "Steer  ↵"
        stopButton.isEnabled = session?.turn != nil
        stopButton.isHidden = InterfaceStyle.isBreathe && session?.turn == nil
        conversation.setWorking(session?.turn != nil) { [weak self] in
            guard let self, self.session?.turn != nil else { return nil }
            return ConversationWorkingIndicator.activity(after: self.stream.records)
        }
        stream.showRepository(of: session?.project)
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
        cardHeight.constant = composerHeight(hasAttachments: !values.isEmpty)
        attachmentScroll.isHidden = values.isEmpty
        attachmentStatus.stringValue = values.isEmpty ? "" : "\(values.count) image\(values.count == 1 ? "" : "s") attached"
        attachmentStatus.textColor = FeedPalette.muted
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
    @objc private func splitRight() { onSplit?() }
    @objc private func splitBelow() { onSplitBelow?() }
    @objc private func splitAbove() { onSplitAbove?() }
    @objc private func moveCurrentChatLeft() { onMoveLeft?() }
    @objc private func moveCurrentChatRight() { onMoveRight?() }
    @objc private func closePane() { onClosePane?() }
    func textDidChange(_ notification: Notification) { onDraftChange?() }
}
