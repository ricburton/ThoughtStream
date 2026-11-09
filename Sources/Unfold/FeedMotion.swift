import AppKit

/// Continuously retargetable following: packets arriving mid-scroll keep the
/// current velocity instead of restarting a separate animation for each packet.
@MainActor
final class FeedScrollMotion {
    private weak var scroll: NSScrollView?
    private var timer: Timer?
    private var target: CGFloat = 0
    private var previousTime: TimeInterval = 0
    var isAnimating: Bool { timer != nil }

    init(_ scroll: NSScrollView) { self.scroll = scroll }
    deinit { timer?.invalidate() }

    func move(to y: CGFloat, animated: Bool = true) {
        guard let scroll else { return }
        target = max(0, y)
        let distance = abs(target - scroll.contentView.bounds.minY)
        guard animated, scroll.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              distance < max(600, scroll.contentSize.height * 3), distance > 0.3 else {
            cancel(); position(target); return
        }
        guard timer == nil else { return }
        previousTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard let scroll = self.scroll, scroll.window != nil else { self.cancel(); return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = min(0.05, now - self.previousTime)
                self.previousTime = now
                let current = scroll.contentView.bounds.minY
                let remaining = self.target - current
                if abs(remaining) < 0.3 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.position(self.target); self.cancel()
                } else {
                    self.position(current + remaining * (1 - exp(-24 * delta)))
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() { timer?.invalidate(); timer = nil }
    private func position(_ y: CGFloat) {
        guard let scroll else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

extension NSAttributedString.Key {
    static let conversationBubble = NSAttributedString.Key("ThoughtStream.conversationBubble")
}

/// A distinct value per message keeps adjacent replies in separate bubbles.
final class ConversationBubble: NSObject {
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    let isUser: Bool
    let naturalWidth: CGFloat
    init(isUser: Bool, naturalWidth: CGFloat) {
        self.isUser = isUser; self.naturalWidth = naturalWidth
    }

    func textRect(in width: CGFloat) -> NSRect {
        let padding = Self.horizontalInset
        let bubbleWidth = min(max(0, width * 0.88), min(640, max(64, naturalWidth + padding * 2)))
        return NSRect(x: (isUser ? width - bubbleWidth : 0) + padding, y: 0,
                      width: max(1, bubbleWidth - padding * 2), height: 0)
    }
}

/// Constrains each message independently while retaining native text selection,
/// links, streaming, and character-based scroll anchors across pane resizing.
final class ConversationTextContainer: NSTextContainer {
    override func lineFragmentRect(forProposedRect proposed: NSRect, at index: Int, writingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposed, at: index, writingDirection: writingDirection, remaining: remainingRect)
        guard let layout = layoutManager, let storage = layout.textStorage, index < layout.numberOfGlyphs else { return rect }
        let character = layout.characterIndexForGlyph(at: index)
        guard character < storage.length,
              let bubble = storage.attribute(.conversationBubble, at: character, effectiveRange: nil) as? ConversationBubble else { return rect }
        let text = bubble.textRect(in: containerSize.width)
        rect.origin.x = text.minX; rect.size.width = text.width
        return rect
    }
}

/// Draws message surfaces beneath native text and its selection highlight.
@MainActor
final class ConversationLayoutManager: NSLayoutManager {
    /// TextKit's line boxes include extra leading above the baseline. Use the
    /// first and last lines' font metrics so the surface has even visual insets,
    /// including when a message starts with a heading or ends with code.
    func bubbleRect(forCharacterRange range: NSRange, in container: NSTextContainer) -> NSRect? {
        guard let storage = textStorage, range.length > 0,
              let bubble = storage.attribute(.conversationBubble, at: range.location, effectiveRange: nil) as? ConversationBubble else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        for glyph in [glyphs.location, NSMaxRange(glyphs) - 1] {
            var line = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            let characters = NSIntersectionRange(characterRange(forGlyphRange: line, actualGlyphRange: nil), range)
            storage.enumerateAttribute(.font, in: characters) { value, run, _ in
                let font = value as? NSFont ?? Typography.conversation
                let index = self.glyphIndexForCharacter(at: run.location)
                let baseline = fragment.minY + self.location(forGlyphAt: index).y
                top = min(top, baseline - font.ascender)
                bottom = max(bottom, baseline - font.descender)
            }
        }
        let text = bubble.textRect(in: container.containerSize.width)
        return NSRect(x: text.minX - ConversationBubble.horizontalInset,
                      y: top - ConversationBubble.verticalInset,
                      width: text.width + ConversationBubble.horizontalInset * 2,
                      height: bottom - top + ConversationBubble.verticalInset * 2)
    }

    override func drawBackground(forGlyphRange range: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: range, actualGlyphRange: nil)
        storage.enumerateAttribute(.conversationBubble, in: characters) { value, visibleRange, _ in
            guard let bubble = value as? ConversationBubble else { return }
            // Drawing a clipped portion must still use the whole message's bounds.
            var messageRange = NSRange()
            _ = storage.attribute(.conversationBubble, at: visibleRange.location, longestEffectiveRange: &messageRange, in: NSRange(location: 0, length: storage.length))
            guard let bounds = self.bubbleRect(forCharacterRange: messageRange, in: container) else { return }
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y)
            (bubble.isUser ? FeedPalette.outgoingMessage : FeedPalette.incomingMessage).setFill()
            NSBezierPath(roundedRect: rect, xRadius: ConversationBubble.cornerRadius, yRadius: ConversationBubble.cornerRadius).fill()
        }
        super.drawBackground(forGlyphRange: range, at: origin)
        storage.enumerateAttribute(.queuedChatBubble, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = self.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -2)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
    }
}
