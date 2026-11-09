import AppKit
import CoreText

/// Digital rain behind the feed. Columns are seeded with the characters a model
/// is streaming right now, so while a reply arrives the rain is that reply,
/// falling. Between turns it settles into a sparse drizzle of mirrored katakana.
///
/// Trails come from fading one persistent 1x bitmap a little each frame and
/// drawing only each column's new head, so the cost stays at a few dozen glyphs
/// per frame regardless of how much rain is on screen.
@MainActor
final class MatrixRainView: NSView {
    private struct Drop {
        var head: CGFloat = -1
        var drawnRow = -1
        var speed: CGFloat = 0.5
        var source: [Character] = []
        var cursor = 0
        var headGlyph: (Character, Bool)?
        var active = false

        mutating func next() -> (Character, Bool) {
            if cursor < source.count { defer { cursor += 1 }; return (source[cursor], false) }
            return (MatrixRainView.katakana.randomElement()!, true)
        }
    }

    nonisolated private static let katakana = Array("ｦｱｳｴｵｶｷｹｺｻｼｽｾｿﾀﾂﾃﾅﾆﾇﾈﾊﾋﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ0123457789Z:・.\"=*+-<>¦｜")
    private static let headInk = CGColor(srgbRed: 0.82, green: 1, blue: 0.86, alpha: 1)
    private static let trailInk = CGColor(srgbRed: 0, green: 0.92, blue: 0.27, alpha: 1)
    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    private let cell = CGSize(width: 13, height: 17)
    private var drops: [Drop] = []
    private var bitmap: CGContext?
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var energy: CGFloat = 0
    private var recent: [Character] = []
    private var lines: [Character: (CTLine, CGFloat)] = [:]

    var isRaining = false {
        didSet {
            guard isRaining != oldValue else { return }
            isHidden = !isRaining
            if isRaining { energy = 1; start() } else { stop(); bitmap = nil; layer?.contents = nil; recent.removeAll() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = Self.black
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    // Purely decorative: clicks and scrolls belong to the feed above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isRaining { start() } else { stop() }
    }

    /// Streamed text drives the rain: it brightens and accelerates, then the
    /// newest words start falling down the columns.
    func feed(_ text: String) {
        guard isRaining, !text.isEmpty else { return }
        energy = 1
        var gap = recent.last == " "
        for character in text.suffix(4000) {
            if character.isWhitespace || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                if !gap { recent.append(" "); gap = true }
            } else { recent.append(character); gap = false }
        }
        if recent.count > 3000 { recent.removeFirst(recent.count - 1500) }
    }

    /// A burst of rain, e.g. when the style is first switched on.
    func surge() { energy = 1 }

    private func start() {
        guard timer == nil, window != nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = CGFloat(min(0.1, now - lastTick)); lastTick = now
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let context = prepareBitmap() else { return }
        energy = max(0, energy - delta / 3)
        let height = CGFloat(context.height)
        // Fading the whole frame is what leaves the long phosphor trails.
        context.setFillColor(Self.black.copy(alpha: 0.065)!)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let pace = (0.45 + 2.6 * energy) * delta * 30
        for column in drops.indices {
            var drop = drops[column]
            if !drop.active {
                guard CGFloat.random(in: 0...1) < 0.004 + 0.08 * energy else { continue }
                drop = spawn()
            }
            drop.head += drop.speed * pace
            while drop.drawnRow < Int(drop.head) {
                // Settle the previous head into the trail, then light the next cell.
                if let (glyph, mirrored) = drop.headGlyph { draw(glyph, mirrored: mirrored, column: column, row: drop.drawnRow, head: false, in: context) }
                drop.drawnRow += 1
                let glyph = drop.next()
                drop.headGlyph = glyph
                draw(glyph.0, mirrored: glyph.1, column: column, row: drop.drawnRow, head: true, in: context)
            }
            if CGFloat(drop.drawnRow) * cell.height > height + cell.height { drop.active = false }
            drops[column] = drop
        }
        layer?.contents = context.makeImage()
    }

    private func spawn() -> Drop {
        var drop = Drop()
        drop.active = true
        drop.speed = .random(in: 0.3...0.75)
        // Most drops carry the live reply while it streams; idle rain is pure code.
        if !recent.isEmpty, CGFloat.random(in: 0...1) < 0.25 + 0.65 * energy {
            let window = recent.suffix(500)
            var start = Int.random(in: window.startIndex..<window.endIndex)
            while start > window.startIndex, recent[start - 1] != " " { start -= 1 }
            drop.source = Array(recent[start..<min(recent.count, start + .random(in: 18...54))])
        }
        return drop
    }

    private func draw(_ glyph: Character, mirrored: Bool, column: Int, row: Int, head: Bool, in context: CGContext) {
        guard row >= 0 else { return }
        let origin = CGPoint(x: CGFloat(column) * cell.width, y: CGFloat(context.height) - CGFloat(row + 1) * cell.height)
        context.setFillColor(Self.black)
        context.fill(CGRect(origin: origin, size: cell))
        guard glyph != " " else { return }
        let (line, width) = self.line(for: glyph)
        context.setFillColor(head ? Self.headInk : Self.trailInk)
        let inset = max(0, (cell.width - width) / 2)
        context.textMatrix = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.textPosition = CGPoint(x: origin.x + (mirrored ? cell.width - inset : inset), y: origin.y + 4)
        CTLineDraw(line, context)
    }

    private func line(for glyph: Character) -> (CTLine, CGFloat) {
        if let cached = lines[glyph] { return cached }
        if lines.count > 3000 { lines.removeAll(keepingCapacity: true) }
        let text = NSAttributedString(string: String(glyph), attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(text)
        let entry = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lines[glyph] = entry
        return entry
    }

    /// Rendered at 1x and scaled up: the softness reads as CRT phosphor and
    /// keeps each frame's fade cheap.
    private func prepareBitmap() -> CGContext? {
        let width = Int(bounds.width.rounded(.up)), height = Int(bounds.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }
        if let bitmap, bitmap.width == width, bitmap.height == height { return bitmap }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(Self.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        bitmap = context
        // Start mid-fall rather than from an empty screen.
        let rows = Int(CGFloat(height) / cell.height)
        drops = (0..<Int((CGFloat(width) / cell.width).rounded(.up))).map { _ in
            var drop = spawn()
            drop.active = Bool.random()
            drop.drawnRow = Int.random(in: -1...max(0, rows))
            drop.head = CGFloat(drop.drawnRow)
            return drop
        }
        return context
    }
}
