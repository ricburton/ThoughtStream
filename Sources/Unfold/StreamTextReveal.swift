import AppKit

/// Arrival times belong to the stream, not its disposable table-row views.
/// Recreating a row therefore never restarts a word that is already appearing.
@MainActor
final class StreamTextReveal {
    private var blocks: [Int: StreamTextRevealState] = [:]
    var lastArrival = ProcessInfo.processInfo.systemUptime

    init(baseline: [NativeFeedBlock] = []) {
        for (index, block) in baseline.enumerated() {
            if let text = Self.text(in: block) { blocks[index] = StreamTextRevealState(text: text.string) }
        }
    }

    func state(for index: Int, text: String) -> StreamTextRevealState {
        let state = blocks[index] ?? StreamTextRevealState(text: "")
        state.append(text, at: lastArrival)
        blocks[index] = state
        return state
    }

    private static func text(in block: NativeFeedBlock) -> NSAttributedString? {
        switch block {
        case .text(let text), .prose(let text, _), .code(let text, _, _): return text
        default: return nil
        }
    }
}

@MainActor
final class StreamTextRevealState {
    struct Word {
        var range: NSRange
        let arrival: TimeInterval
    }
    private(set) var text: String
    private(set) var words: [Word] = []
    /// Matrix words linger as glowing heads long enough to read as rain.
    static var duration: TimeInterval { InterfaceStyle.isMatrix ? 0.85 : 0.28 }

    init(text: String) { self.text = text }

    func append(_ value: String, at now: TimeInterval) {
        words.removeAll { now >= $0.arrival + Self.duration }
        guard value != text else { return }
        defer { text = value }
        // A Markdown reparse or formatter may rewrite earlier text. Settle it
        // immediately rather than replaying an entire paragraph or code block.
        let stable = text.reversed().drop(while: { $0.isNewline }).reversed()
        let prefix = String(stable)
        guard value.hasPrefix(prefix) else { words.removeAll(); return }
        let prefixLength = prefix.utf16.count
        words = words.compactMap { word in
            let length = min(NSMaxRange(word.range), prefixLength) - word.range.location
            guard length > 0 else { return nil }
            return Word(range: NSRange(location: word.range.location, length: length), arrival: word.arrival)
        }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        // Large tool responses should be readable immediately. Only their tail
        // needs a short entrance, never a queued typewriter effect.
        let tail = value[start...].suffix(600)
        var wordStart = tail.startIndex
        var delay: TimeInterval = 0
        for index in tail.indices where tail[index].isWhitespace {
            let end = tail.index(after: index)
            words.append(Word(range: NSRange(wordStart..<end, in: value), arrival: now + delay))
            wordStart = end
            delay = min(0.12, delay + 0.012)
        }
        if wordStart < tail.endIndex {
            words.append(Word(range: NSRange(wordStart..<tail.endIndex, in: value), arrival: now + delay))
        }
    }

    func finish() { words.removeAll() }
}

/// Temporary ink opacity leaves the real attributed string, links, selection,
/// accessibility value and glyph layout intact throughout the reveal.
@MainActor
final class StreamTextAnimator {
    private weak var view: NSTextView?
    private let state: StreamTextRevealState
    private var timer: Timer?
    private var paintedRanges: [NSRange] = []
    private static let matrixHead = NSColor(srgbRed: 0.88, green: 1, blue: 0.9, alpha: 1)

    init(view: NSTextView, state: StreamTextRevealState) {
        self.view = view; self.state = state
    }
    deinit { timer?.invalidate() }

    func start() {
        stop()
        guard paint(), view?.window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.view?.window == nil || !self.paint() { self.stop() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let layout = view?.layoutManager, let length = view?.textStorage?.length {
            for range in paintedRanges where NSMaxRange(range) <= length {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
        }
        paintedRanges.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private func paint() -> Bool {
        guard let view, let layout = view.layoutManager, let storage = view.textStorage else { return false }
        for range in paintedRanges { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
        paintedRanges.removeAll(keepingCapacity: true)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { state.finish(); return false }
        let now = ProcessInfo.processInfo.systemUptime
        for word in state.words {
            let progress = min(1, max(0, (now - word.arrival) / StreamTextRevealState.duration))
            guard progress < 1, NSMaxRange(word.range) <= storage.length else { continue }
            // Ease out to normal ink, with no movement or change in line breaks.
            let eased = 1 - pow(1 - progress, 3)
            let opacity = 0.18 + 0.82 * eased
            let matrix = InterfaceStyle.isMatrix
            storage.enumerateAttribute(.foregroundColor, in: word.range) { value, range, _ in
                var color = value as? NSColor ?? .textColor
                if matrix, let ink = color.usingColorSpace(.sRGB) {
                    // Arriving words land as the rain's white-hot head, then cool to phosphor.
                    color = ink.blended(withFraction: 1 - eased, of: StreamTextAnimator.matrixHead) ?? ink
                }
                layout.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * (matrix ? 0.45 + 0.55 * eased : opacity)), forCharacterRange: range)
            }
            paintedRanges.append(word.range)
        }
        return !paintedRanges.isEmpty
    }
}
