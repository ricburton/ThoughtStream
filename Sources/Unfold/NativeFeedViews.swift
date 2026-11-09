import AppKit
import WebKit

extension NSAttributedString.Key {
    static let nativeJSON = NSAttributedString.Key("ThoughtStream.nativeJSON")
}

actor NativeImageStore {
    static let shared = NativeImageStore()
    private var cache: [String: Data] = [:]
    private var bytes = 0
    func data(for reference: NativeImageReference, project: URL?) async throws -> Data {
        let key = (project?.path ?? "") + reference.source
        if let data = cache[key] { return data }
        let source = reference.source
        let data: Data
        if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ",") {
            let value = String(source[source.index(after: comma)...])
            if source[..<comma].contains(";base64"), let decoded = Data(base64Encoded: value, options: .ignoreUnknownCharacters) { data = decoded }
            else if let decoded = value.removingPercentEncoding { data = Data(decoded.utf8) }
            else { throw CocoaError(.fileReadCorruptFile) }
        } else if let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") {
            var request = URLRequest(url: url); request.timeoutInterval = 20
            let (download, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw CocoaError(.fileReadUnknown) }
            data = download
        } else {
            let url: URL
            if source.hasPrefix("file://"), let file = URL(string: source) { url = file }
            else if source.hasPrefix("/") || source.hasPrefix("~/") { url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath) }
            else if let project { url = project.appendingPathComponent(source) }
            else { throw CocoaError(.fileNoSuchFile) }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 80 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard data.count <= 80 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        if bytes + data.count > 128 * 1024 * 1024 { cache.removeAll(); bytes = 0 }
        cache[key] = data; bytes += data.count
        return data
    }
}

@MainActor
final class NativeFeedScrollView: NSScrollView {
    var onScrollUp: (() -> Void)?
    var onUserScroll: (() -> Void)?
    var onWillResize: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { onWillResize?() }
        super.setFrameSize(newSize)
    }
    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        if event.scrollingDeltaY > 0 { onScrollUp?() }
        super.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if [49, 115, 116, 119, 121, 125, 126].contains(event.keyCode) { onUserScroll?() }
        if [115, 116, 126].contains(event.keyCode) { onScrollUp?() }
        super.keyDown(with: event)
    }
}

@MainActor
enum NativeFeedLayout {
    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        // Measure the same glyph layout used by NativeFeedTextView, even for
        // long files. Character-count estimates accumulate blank space below
        // the code (and can underestimate lines that wrap at word boundaries).
        let storage = NSTextStorage(attributedString: text), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(40, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 4
    }
    static func height(_ block: NativeFeedBlock, width: CGFloat, images: [String: NSImage]) -> CGFloat {
        switch block {
        case .header(_, _, _, let size, let rawSource): return max(rawSource == nil ? 18 : 28, size)
        case .text(let text): return textHeight(text, width: width)
        case .prose(let text, let tone): return textHeight(text, width: width - (tone == .user ? 36 : 20)) + (tone == .user ? 24 : 4)
        case .code(let text, _, _): return 42 + textHeight(text, width: width - 24) + 8
        case .html: return 330
        case .image(let reference):
            guard let image = images[reference.source], image.size.width > 0 else { return 240 }
            return 30 + min(width, image.size.width) * image.size.height / image.size.width
        }
    }
}

@MainActor
final class NativeFeedTextView: NSTextView, NSTextViewDelegate {
    private var isJSON: Bool
    private var streamAnimator: StreamTextAnimator?
    private var jsonTracking: NSTrackingArea?
    private var hoverLine: NSRect?
    init(_ text: NSAttributedString, reveal: StreamTextRevealState? = nil) {
        isJSON = text.length > 0 && (text.attribute(.nativeJSON, at: 0, effectiveRange: nil) as? Bool == true)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true; drawsBackground = false
        textContainerInset = .zero; textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false; isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        // Rows are already measured in full. Keep painting contiguous too:
        // partial layout can leave the tail of a long code block undrawn.
        layoutManager?.allowsNonContiguousLayout = false
        textStorage?.setAttributedString(text); delegate = self
        setAccessibilityLabel("Feed text")
        if let reveal {
            streamAnimator = StreamTextAnimator(view: self, state: reveal)
            streamAnimator?.start()
        }
    }
    /// Preserve the text system and selection as a streaming block grows.
    func update(_ text: NSAttributedString, reveal: StreamTextRevealState?) {
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        streamAnimator?.stop()
        let selection = selectedRange()
        let old = Array(storage.string.utf16), new = Array(text.string.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        // Never split a surrogate pair at an edit boundary.
        if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        if suffix > 0, (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.count - prefix - suffix),
            with: text.attributedSubstring(from: NSRange(location: prefix, length: new.count - prefix - suffix)))
        // Syntax highlighting can change before the appended characters.
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            storage.enumerateAttributes(in: range) { existing, span, _ in
                if !NSDictionary(dictionary: existing).isEqual(to: attributes) { storage.setAttributes(attributes, range: span) }
            }
        }
        storage.endEditing()
        let start = min(selection.location, storage.length)
        setSelectedRange(NSRange(location: start, length: min(selection.length, storage.length - start)))
        isJSON = text.length > 0 && text.attribute(.nativeJSON, at: 0, effectiveRange: nil) as? Bool == true
        hoverLine = nil
        streamAnimator = reveal.map { StreamTextAnimator(view: self, state: $0) }
        streamAnimator?.start()
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { streamAnimator?.stop() } else { streamAnimator?.start() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let jsonTracking { removeTrackingArea(jsonTracking) }
        guard isJSON else { return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); jsonTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard isJSON, let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        if glyph < layoutManager.numberOfGlyphs {
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.x = 0; rect.size.width = bounds.width
            if rect != hoverLine { hoverLine = rect; needsDisplay = true }
        }
    }
    override func mouseExited(with event: NSEvent) { hoverLine = nil; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        drawDiff(in: dirtyRect)
        if isJSON, let layoutManager, let textContainer, let textStorage {
            if let hoverLine {
                FeedPalette.jsonHover.setFill()
                NSBezierPath(roundedRect: hoverLine.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
            let source = textStorage.string as NSString
            let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            let step = (" " as NSString).size(withAttributes: [.font: font]).width * 2
            let guides = NSBezierPath(); guides.lineWidth = 0.7
            guides.setLineDash([2, 2], count: 2, phase: 0)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                let character = layoutManager.characterIndexForGlyph(at: range.location)
                let line = source.lineRange(for: NSRange(location: min(character, max(0, source.length - 1)), length: 0))
                var spaces = 0
                while spaces < 48 && line.location + spaces < source.length && source.character(at: line.location + spaces) == 32 { spaces += 1 }
                if spaces >= 2 {
                    for level in 0..<(spaces / 2) {
                        let x = CGFloat(level) * step + step * 0.4
                        guides.move(to: NSPoint(x: x, y: rect.minY)); guides.line(to: NSPoint(x: x, y: rect.maxY))
                    }
                }
            }
            FeedPalette.line.setStroke(); guides.stroke()
        }
        super.draw(dirtyRect)
    }
    private func drawDiff(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0,
              textStorage.attribute(.nativeDiffKind, at: 0, effectiveRange: nil) != nil else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        let source = textStorage.string as NSString
        let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            guard character < textStorage.length else { return }
            let kind = textStorage.attribute(.nativeDiffKind, at: character, effectiveRange: nil) as? String
            let color = kind == "added" ? FeedPalette.diffAdded : kind == "removed" ? FeedPalette.diffRemoved : kind == "hunk" ? FeedPalette.diffHunk : nil
            if let color {
                color.setFill()
                NSRect(x: 0, y: rect.minY, width: self.bounds.width, height: rect.height).fill()
            }
            // A wrapped continuation retains its row color, without repeating numbers.
            let line = source.lineRange(for: NSRange(location: character, length: 0))
            guard character == line.location else { return }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: FeedPalette.muted, .paragraphStyle: paragraph]
            let y = rect.minY + max(0, (rect.height - font.ascender + font.descender) / 2)
            for (key, x) in [(NSAttributedString.Key.nativeDiffOldLine, CGFloat(0)), (.nativeDiffNewLine, CGFloat(35))] {
                if let number = textStorage.attribute(key, at: character, effectiveRange: nil) as? Int {
                    (String(number) as NSString).draw(in: NSRect(x: x, y: y, width: 30, height: rect.height), withAttributes: attributes)
                }
            }
        }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, ["http", "https", "mailto"].contains(url.scheme ?? "") else { return true }
        NSWorkspace.shared.open(url); return true
    }
}

@MainActor
final class NativeCodeView: NativeFeedCard {
    private(set) var source: String
    private let code: NativeFeedTextView
    private let copy: CopyFeedbackButton
    private let diffSummary: NSTextField?
    init(text: NSAttributedString, source: String, label: String, reveal: StreamTextRevealState? = nil) {
        self.source = source
        code = NativeFeedTextView(text, reveal: reveal)
        copy = CopyFeedbackButton(text: source)
        diffSummary = label == "Diff" ? NSTextField(labelWithString: NativeDiff.summary(text)) : nil
        super.init(frame: .zero)
        headerHeight = 42
        let title = NSTextField(labelWithString: label)
        let isPacket = label == "JSON"
        title.font = isPacket ? Typography.metadata : Typography.section
        title.textColor = isPacket ? FeedPalette.muted : FeedPalette.text
        if isPacket { fill = .clear; drawsBorder = false; headerHeight = 0 }
        diffSummary?.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        diffSummary?.textColor = FeedPalette.muted
        code.setAccessibilityLabel(label == "Diff" ? "Git diff: old and new line numbers, additions marked plus, removals marked minus" : "Code")
        let header = NSStackView(views: [title] + (diffSummary.map { [$0] } ?? []) + [NSView(), copy]); header.orientation = .horizontal
        for view in [header, code] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6), header.heightAnchor.constraint(equalToConstant: 30),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            code.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6), code.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), code.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
    func update(text: NSAttributedString, source: String, reveal: StreamTextRevealState?) {
        self.source = source
        copy.updateText(source)
        diffSummary?.stringValue = NativeDiff.summary(text)
        code.update(text, reveal: reveal)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
}

@MainActor
final class NativeFeedHeading: NSView {
    private let color: NSColor
    private let rawSource: String?
    init(title: String, time: String, tone: NativeTextTone, size: CGFloat, rawSource: String?) {
        self.rawSource = rawSource
        color = tone == .reasoning ? FeedPalette.purple : tone == .command ? FeedPalette.green : tone == .error ? FeedPalette.red : FeedPalette.muted
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: title); name.font = Typography.prose(ofSize: max(11, size * 0.75), weight: .medium); name.textColor = color
        name.lineBreakMode = .byTruncatingTail; name.toolTip = title
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let timestamp = NSTextField(labelWithString: time); timestamp.font = .monospacedDigitSystemFont(ofSize: max(11, size * 0.69), weight: .regular); timestamp.textColor = FeedPalette.muted
        let row = NSStackView(views: [name, timestamp, NSView()]); row.orientation = .horizontal; row.spacing = 10
        if let rawSource {
            let copy = CopyFeedbackButton(title: "Copy raw JSON", text: rawSource)
            copy.font = Typography.metadata
            copy.toolTip = "Copy the original tool response, including transport metadata"
            row.addArrangedSubview(copy)
        }
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
    }
}

@MainActor
final class NativeProseView: NativeFeedCard {
    private let tone: NativeTextTone
    private let content: NativeFeedTextView
    init(text: NSAttributedString, tone: NativeTextTone, reveal: StreamTextRevealState? = nil) {
        self.tone = tone
        content = NativeFeedTextView(text, reveal: reveal)
        super.init(frame: .zero)
        drawsBorder = false; radius = 12
        if tone == .reasoning { fill = .clear }
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        let side: CGFloat = tone == .user ? 18 : 18, vertical: CGFloat = tone == .user ? 12 : 2
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: tone == .user ? -18 : -2), content.topAnchor.constraint(equalTo: topAnchor, constant: vertical), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical)])
    }
    func update(_ text: NSAttributedString, reveal: StreamTextRevealState?) {
        content.update(text, reveal: reveal)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if tone == .reasoning { FeedPalette.purple.withAlphaComponent(0.35).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: bounds.height)).fill() }
    }
}

@MainActor
final class NativeFeedRow: NSView {
    private var accent: NSColor?
    private let stack = NSStackView()
    private var blockHeights: [(NativeFeedBlock, NSLayoutConstraint)] = []
    private let openHTML: (String) -> Void
    private let openImage: (NSImage) -> Void
    private var layoutWidth: CGFloat
    private(set) var contentHeight: CGFloat = 20
    init(blocks: [NativeFeedBlock], width: CGFloat, images: [String: NSImage], reveal: StreamTextReveal? = nil, accent: NSColor? = nil, openHTML: @escaping (String) -> Void, openImage: @escaping (NSImage) -> Void) {
        self.accent = accent
        self.openHTML = openHTML; self.openImage = openImage
        layoutWidth = width
        super.init(frame: .zero)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)])
        update(blocks: blocks, width: width, images: images, reveal: reveal, accent: accent)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    /// Reconcile individual blocks instead of discarding an entire live row.
    @discardableResult
    func update(blocks: [NativeFeedBlock], width: CGFloat, images: [String: NSImage],
                reveal: StreamTextReveal?, accent: NSColor?) -> CGFloat {
        let widthUnchanged = abs(width - layoutWidth) <= 0.5
        self.accent = accent; layoutWidth = width; needsDisplay = true
        while blockHeights.count > blocks.count {
            blockHeights.removeLast().1.isActive = false
            let child = stack.arrangedSubviews.last!
            stack.removeArrangedSubview(child); child.removeFromSuperview()
        }
        for (index, block) in blocks.enumerated() {
            let state = { (text: NSAttributedString) in reveal?.state(for: index, text: text.string) }
            var reused = false
            var unchanged = false
            if index < blockHeights.count {
                let old = blockHeights[index].0
                let child = stack.arrangedSubviews[index]
                unchanged = widthUnchanged && Self.sameLayout(old, block)
                switch (old, block) {
                case (.text, .text(let text)):
                    (child as? NativeFeedTextView)?.update(text, reveal: state(text)); reused = true
                case (.prose(_, let a), .prose(let text, let b)) where a == b:
                    (child as? NativeProseView)?.update(text, reveal: state(text)); reused = true
                case (.code(_, _, let a), .code(let text, let source, let b)) where a == b:
                    (child as? NativeCodeView)?.update(text: text, source: source, reveal: state(text)); reused = true
                case (.header(let a, let b, let c, let d, let e), .header(let f, let g, let h, let i, let j)):
                    reused = a == f && b == g && c == h && d == i && e == j
                case (.html, .html(let b)):
                    // Keep one web view while HTML streams in; it reloads once the source settles.
                    if let preview = child as? NativeHTMLBlock { preview.update(html: b); reused = true }
                case (.image(let a), .image(let b)):
                    reused = a == b
                    if reused { (child as? NativeImageBlock)?.update(image: images[b.source], title: b.title) }
                default: break
                }
            }
            if !reused {
                let content: NSView
                switch block {
                case .header(let title, let time, let tone, let size, let rawSource): content = NativeFeedHeading(title: title, time: time, tone: tone, size: size, rawSource: rawSource)
                case .text(let text): content = NativeFeedTextView(text, reveal: state(text))
                case .prose(let text, let tone): content = NativeProseView(text: text, tone: tone, reveal: state(text))
                case .code(let text, let source, let label): content = NativeCodeView(text: text, source: source, label: label, reveal: state(text))
                case .html(let html): content = NativeHTMLBlock(html: html, open: openHTML)
                case .image(let reference): content = NativeImageBlock(image: images[reference.source], title: reference.title, open: openImage)
                }
                if index < blockHeights.count {
                    blockHeights[index].1.isActive = false
                    let old = stack.arrangedSubviews[index]
                    stack.removeArrangedSubview(old); old.removeFromSuperview()
                }
                content.translatesAutoresizingMaskIntoConstraints = false
                stack.insertArrangedSubview(content, at: index)
                content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                let height = content.heightAnchor.constraint(equalToConstant: 0); height.isActive = true
                if index < blockHeights.count { blockHeights[index] = (block, height) }
                else { blockHeights.append((block, height)) }
            }
            blockHeights[index].0 = block
            // Streaming re-renders the whole row, but usually only its last
            // block grows. Skip typesetting blocks whose layout is unchanged.
            if !(reused && unchanged) {
                blockHeights[index].1.constant = NativeFeedLayout.height(block, width: width - 28, images: images)
            }
        }
        updateContentHeight()
        return contentHeight
    }
    private static func sameLayout(_ a: NativeFeedBlock, _ b: NativeFeedBlock) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x.isEqual(to: y)
        case (.prose(let x, let s), .prose(let y, let t)): return s == t && x.isEqual(to: y)
        case (.code(let x, _, let l), .code(let y, _, let m)): return l == m && x.isEqual(to: y)
        case (.header(_, _, _, let s, let r), .header(_, _, _, let t, let q)): return s == t && (r == nil) == (q == nil)
        case (.html, .html): return true
        default: return false
        }
    }
    /// Width changes only invalidate geometry. Keep text storage, selection,
    /// reveal state and embedded previews attached throughout live resizing.
    @discardableResult
    func reflow(width: CGFloat, images: [String: NSImage]) -> CGFloat {
        guard abs(width - layoutWidth) > 0.5 else { return contentHeight }
        layoutWidth = width
        for (block, constraint) in blockHeights {
            constraint.constant = NativeFeedLayout.height(block, width: width - 28, images: images)
        }
        updateContentHeight()
        return contentHeight
    }
    private func updateContentHeight() {
        contentHeight = 20 + blockHeights.reduce(0) { $0 + $1.1.constant } + CGFloat(max(0, blockHeights.count - 1)) * 8
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let accent else { return }
        accent.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: 10, width: 2, height: max(0, bounds.height - 20)), xRadius: 1, yRadius: 1).fill()
    }
}

@MainActor
final class NativeImageBlock: NSView {
    private var image: NSImage?
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Open image ↗", target: nil, action: nil)
    private let open: (NSImage) -> Void
    init(image: NSImage?, title: String, open: @escaping (NSImage) -> Void) {
        self.image = image; self.open = open; super.init(frame: .zero)
        label.stringValue = title.isEmpty ? "Image" : title
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        button.target = self; button.action = #selector(show); button.bezelStyle = .inline; button.isEnabled = image != nil
        let header = NSStackView(views: [label, NSView(), button]); header.orientation = .horizontal
        imageView.image = image; imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.animates = true
        imageView.setAccessibilityLabel(title.isEmpty ? "Feed image" : title)
        for view in [header, imageView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 26), imageView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        if image == nil { label.stringValue = "Loading image…" }
    }
    func update(image: NSImage?, title: String) {
        self.image = image; imageView.image = image; button.isEnabled = image != nil
        label.stringValue = image == nil ? "Loading image…" : title.isEmpty ? "Image" : title
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    @objc private func show() { if let image { open(image) } }
}

@MainActor
final class NativeHTMLBlock: NSView {
    private var html: String
    private let open: (String) -> Void
    private let web = HTMLPreviewWindow.makeWebView()
    private var pendingLoad: DispatchWorkItem?
    init(html: String, open: @escaping (String) -> Void) {
        self.html = html; self.open = open; super.init(frame: .zero)
        let label = NSTextField(labelWithString: "HTML preview"); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open window ↗", target: self, action: #selector(show)); button.bezelStyle = .inline
        let header = NSStackView(views: [label, NSView(), button]); header.orientation = .horizontal
        web.loadHTMLString(HTMLPreviewWindow.document(html), baseURL: nil)
        for view in [header, web] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 26), web.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4), web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    func update(html: String) {
        guard html != self.html else { return }
        self.html = html
        pendingLoad?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.web.loadHTMLString(HTMLPreviewWindow.document(self.html), baseURL: nil)
        }
        pendingLoad = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    @objc private func show() { open(html) }
}
