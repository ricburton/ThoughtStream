import AppKit

/// The readable exchange stays beside the composer while the full activity
/// stream can be inspected independently. It never owns or mutates session data.
@MainActor
final class ConversationView: NativeFeedCard, NSTextViewDelegate {
    var onRetryQueuedChat: (() -> Void)?
    let transcript: NSTextView
    private var revealState = StreamTextRevealState(text: "")
    private var textAnimator: StreamTextAnimator?
    let scroll = NativeFeedScrollView()
    private lazy var scrollMotion = FeedScrollMotion(scroll)
    private let latest = NSButton(title: "Latest ↓", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "Send a message to start the conversation.")
    private let contentInset = NSSize(width: PaneSpacing.textInset, height: 16)
    private var feed = FeedBuffer()
    private var starts: [Int] = []
    private(set) var followsLatest = true
    private var positionObserver: NSObjectProtocol?
    private var updating = false
    private var lastViewportSize = NSSize.zero
    private var resizeAnchor: FeedTextScrollAnchor?
    private var resizeAnchorExpiry: DispatchWorkItem?
    var records: [StreamRecord] { feed.records }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = ConversationLayoutManager()
        let container = ConversationTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        transcript = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        transcript.delegate = self
        radius = 0; fill = FeedPalette.canvas; drawsBorder = false
        let title = NSTextField(labelWithString: "Conversation")
        title.font = Typography.section
        title.textColor = FeedPalette.muted
        latest.bezelStyle = .inline; latest.controlSize = .small; latest.font = Typography.caption
        latest.target = self; latest.action = #selector(showLatest)
        latest.toolTip = "Follow the latest message in this conversation"
        latest.setAccessibilityLabel("Show latest conversation message")
        latest.isHidden = true
        empty.font = Typography.interface; empty.textColor = FeedPalette.muted
        empty.lineBreakMode = .byWordWrapping; empty.maximumNumberOfLines = 0
        // The empty hint must wrap rather than widen a restored split pane.
        empty.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.minSize = .zero; transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainerInset = contentInset
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.setAccessibilityLabel("Conversation messages and assistant replies")
        scroll.documentView = transcript; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityLabel("Conversation history")
        scroll.onScrollUp = { [weak self] in self?.pauseFollowing() }
        scroll.onUserScroll = { [weak self] in
            self?.resizeAnchor = nil; self?.resizeAnchorExpiry?.cancel(); self?.resizeAnchorExpiry = nil
        }
        scroll.onWillResize = { [weak self] in
            guard let self, !self.updating else { return }
            if self.resizeAnchor?.isAttached(to: self.transcript) == true { return }
            self.resizeAnchor = FeedTextScrollAnchor(document: self.transcript, viewport: self.scroll.documentVisibleRect)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        positionObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self, !self.updating, self.resizeAnchorExpiry == nil, !self.followsLatest {
                    self.resizeAnchor = FeedTextScrollAnchor(document: self.transcript, viewport: self.scroll.documentVisibleRect)
                }
                guard let self, !self.updating, !self.scrollMotion.isAnimating else { return }
                if self.transcript.bounds.height > self.scroll.contentSize.height + 2,
                   self.scroll.documentVisibleRect.maxY < self.transcript.bounds.maxY - 8 {
                    self.pauseFollowing()
                }
            }
        }
        for child in [title, latest, scroll, empty] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset.width), title.topAnchor.constraint(equalTo: topAnchor, constant: contentInset.height),
            latest.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset.width), latest.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset.width), empty.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -contentInset.width), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: contentInset.height)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    deinit { if let positionObserver { NotificationCenter.default.removeObserver(positionObserver) } }

    static func includes(_ record: StreamRecord) -> Bool {
        [StreamKind.user.rawValue, StreamKind.prose.rawValue].contains(record.kind)
    }

    func replace(_ records: [StreamRecord], preservingPosition: Bool = false) {
        guard let storage = transcript.textStorage else { return }
        resizeAnchor = nil; resizeAnchorExpiry?.cancel(); resizeAnchorExpiry = nil
        let oldPosition = scroll.contentView.bounds.origin
        let wasFollowing = followsLatest
        let selection = transcript.selectedRange()
        var updated = FeedBuffer()
        for record in records where Self.includes(record) { updated.append(record, merging: true) }
        let unchanged = zip(feed.records, updated.records).prefix { $0 == $1 }.count
        let contentChanged = unchanged != feed.records.count || unchanged != updated.records.count
        feed = updated
        if !preservingPosition { scrollMotion.cancel() }
        updating = true
        if contentChanged {
            textAnimator?.stop(); textAnimator = nil
            let start = unchanged < starts.count ? starts[unchanged] : storage.length
            starts = Array(starts.prefix(unchanged))
            let suffix = NSMutableAttributedString(string: "")
            for record in feed.records.dropFirst(unchanged) {
                starts.append(start + suffix.length)
                suffix.append(render(record))
            }
            // Never empty the text view between queue updates: that lets AppKit
            // collapse its document and clamp the viewport back to the top.
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: suffix)
            storage.endEditing()
            revealState = StreamTextRevealState(text: transcript.string)
        }
        followsLatest = preservingPosition ? wasFollowing : true
        latest.isHidden = followsLatest
        if preservingPosition, NSMaxRange(selection) <= transcript.string.utf16.count { transcript.setSelectedRange(selection) }
        finishUpdate(animated: preservingPosition)
        if preservingPosition && !wasFollowing {
            scroll.contentView.scroll(to: oldPosition); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func append(_ record: StreamRecord, merging: Bool, resumeFollowing: Bool = true) {
        guard Self.includes(record), let storage = transcript.textStorage else { return }
        textAnimator?.stop()
        let row = feed.append(record, merging: merging)
        let isNew = row >= starts.count
        updating = true
        storage.beginEditing()
        if row < starts.count {
            let start = starts[row]
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: render(feed.records[row]))
        } else {
            starts.append(storage.length); storage.append(render(record))
        }
        storage.endEditing()
        if record.kind == StreamKind.user.rawValue {
            if isNew && resumeFollowing {
                // Sending starts a new exchange, even after reading or selecting
                // older replies. Bring that message and its response into view.
                scrollMotion.cancel()
                followsLatest = true; latest.isHidden = true
                transcript.setSelectedRange(NSRange(location: storage.length, length: 0))
            }
            textAnimator = nil; revealState = StreamTextRevealState(text: transcript.string)
        } else {
            revealState.append(transcript.string, at: ProcessInfo.processInfo.systemUptime)
            textAnimator = StreamTextAnimator(view: transcript, state: revealState)
            textAnimator?.start()
        }
        finishUpdate(animated: true)
    }

    /// Re-typesets every message in the current style, keeping the reading position.
    func applyInterfaceStyle() {
        let all = feed.records
        // Keep the first message's offset so replace() rewrites, not appends.
        feed = FeedBuffer(); starts = Array(starts.prefix(1))
        replace(all, preservingPosition: true)
        needsDisplay = true
    }

    func finalizeResponse(_ response: StreamRecord) {
        var finalized = feed
        finalized.finalizeResponse(response)
        replace(finalized.records, preservingPosition: true)
    }

    private func render(_ record: StreamRecord) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let isUser = record.kind == StreamKind.user.rawValue
        if isUser, let status = record.queuedStatus {
            result.append(QueuedChatPresentation.label(status: status, detail: record.queuedDetail))
        }
        var renderer = NativeFeedRenderer(size: Typography.conversation.pointSize, analyses: [:])
        for block in renderer.render(record) {
            switch block {
            case .text(let text), .prose(let text, _), .code(let text, _, _): result.append(text)
            case .image: result.append(NSAttributedString(string: "[Image — inspect in the stream above]"))
            case .html(let source): result.append(NSAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
            case .header: break
            }
        }
        let messageRange = NSRange(location: 0, length: result.length)
        if isUser {
            // Syntax and links remain readable on the outgoing blue surface.
            result.addAttribute(.foregroundColor, value: NSColor.white, range: messageRange)
        }
        let naturalWidth = result.boundingRect(with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        result.addAttribute(.conversationBubble, value: ConversationBubble(isUser: isUser, naturalWidth: ceil(naturalWidth)), range: messageRange)
        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = ConversationBubble.verticalInset; gap.maximumLineHeight = ConversationBubble.verticalInset
        gap.paragraphSpacing = ConversationBubble.verticalInset
        result.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6), .paragraphStyle: gap]))
        // Reserve layout space above the surface as well as below it, so the
        // first rounded bubble is not clipped by the text container's top edge.
        let top = NSMutableParagraphStyle()
        top.minimumLineHeight = ConversationBubble.verticalInset; top.maximumLineHeight = ConversationBubble.verticalInset
        let padded = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6), .paragraphStyle: top])
        padded.append(result)
        return padded
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "thoughtstream-queue" else { return false }
        onRetryQueuedChat?(); return true
    }
    private func finishUpdate(animated: Bool = false) {
        empty.isHidden = !records.isEmpty
        sizeTranscript()
        if followsLatest && transcript.selectedRange().length == 0 { scrollToLatest(animated: animated) }
        updating = false
    }
    private func pauseFollowing() { scrollMotion.cancel(); followsLatest = false; latest.isHidden = false }
    private func sizeTranscript() {
        guard let layout = transcript.layoutManager as? ConversationLayoutManager,
              let container = transcript.textContainer, let storage = transcript.textStorage else { return }
        layout.ensureLayout(for: container)
        transcript.sizeToFit()
        // The spacer paragraphs separate turns, but their final empty line is
        // not part of the conversation's bottom margin. Match the margin above
        // the first surface instead, keeping the latest reply clear of the edge.
        var first: NSRect?
        var last: NSRect?
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.conversationBubble, in: all) { value, range, stop in
            guard value is ConversationBubble else { return }
            first = layout.bubbleRect(forCharacterRange: range, in: container); stop.pointee = true
        }
        storage.enumerateAttribute(.conversationBubble, in: all, options: .reverse) { value, range, stop in
            guard value is ConversationBubble else { return }
            last = layout.bubbleRect(forCharacterRange: range, in: container); stop.pointee = true
        }
        if let first, let last {
            let margin = transcript.textContainerOrigin.y + first.minY
            let height = ceil(transcript.textContainerOrigin.y + last.maxY + margin)
            transcript.setFrameSize(NSSize(width: transcript.frame.width, height: max(scroll.contentSize.height, height)))
        }
    }
    /// Only the pane submitting a message resumes; other views keep their place.
    func resumeLiveActivity(animated: Bool = false) {
        followsLatest = true; latest.isHidden = true
        transcript.setSelectedRange(NSRange(location: transcript.string.utf16.count, length: 0))
        scrollToLatest(animated: animated)
    }
    @objc private func showLatest() { resumeLiveActivity() }
    private func scrollToLatest(animated: Bool = true) {
        let y = max(0, transcript.bounds.height - scroll.contentSize.height)
        scrollMotion.move(to: y, animated: animated)
    }
    override func layout() {
        super.layout()
        let viewportSize = scroll.contentSize
        guard viewportSize != lastViewportSize else { return }
        lastViewportSize = viewportSize
        updating = true
        scrollMotion.cancel()
        sizeTranscript()
        if followsLatest, transcript.selectedRange().length == 0 {
            scrollToLatest(animated: false)
            resizeAnchor = nil
        } else if let y = resizeAnchor?.position(in: transcript) {
            let limit = max(0, transcript.bounds.height - viewportSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        resizeAnchorExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.resizeAnchorExpiry = nil }
        resizeAnchorExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: expiry)
        updating = false
    }
}
