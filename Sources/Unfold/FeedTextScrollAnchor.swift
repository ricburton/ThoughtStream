import AppKit

/// Split views can resize descendants before the scroll view itself receives
/// its frame. Capture the old text layout at the pane boundary as well.
@MainActor
final class FeedResizeContainer: NSView {
    var onWillResize: (() -> Void)?
    override var frame: NSRect {
        willSet { if newValue.size != frame.size { onWillResize?() } }
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { onWillResize?() }
        super.setFrameSize(newSize)
    }
}

/// A character at the top of a viewport survives line wrapping more reliably
/// than a pixel offset or a fraction of a long message's height.
@MainActor
final class FeedTextScrollAnchor {
    private weak var text: NSTextView?
    private let character: Int
    private let lineOffset: CGFloat

    init?(document: NSView, viewport: NSRect) {
        func textViews(in view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap(textViews)
        }
        let candidates = textViews(in: document).filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.string.isEmpty &&
            $0.convert($0.bounds, to: document).intersects(viewport)
        }.sorted {
            $0.convert($0.bounds, to: document).minY < $1.convert($1.bounds, to: document).minY
        }
        guard let text = candidates.first, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let local = text.convert(viewport, from: document)
        let point = NSPoint(x: 0, y: max(0, local.minY - text.textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        self.text = text
        character = layout.characterIndexForGlyph(at: glyph)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        lineOffset = text.convert(NSPoint(x: 0, y: line.minY + text.textContainerOrigin.y), to: document).y - viewport.minY
    }

    func isAttached(to document: NSView) -> Bool {
        guard let text else { return false }
        return text.isDescendant(of: document) && character < (text.textStorage?.length ?? 0)
    }

    func position(in document: NSView) -> CGFloat? {
        guard let text, text.isDescendant(of: document), let layout = text.layoutManager,
              let storage = text.textStorage, character < storage.length else { return nil }
        let range = NSRange(location: character, length: 1)
        layout.ensureLayout(forCharacterRange: range)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return text.convert(NSPoint(x: 0, y: line.minY + text.textContainerOrigin.y), to: document).y - lineOffset
    }
}
