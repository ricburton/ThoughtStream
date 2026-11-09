import AppKit

/// Neutral workspace surfaces, with color reserved for actions and feed meaning.
enum FeedPalette {
    static let canvas = color(0xFFFFFF, dark: 0x1E1E20, matrix: 0x000000)
    static let activePane = color(0xF7FAFE, dark: 0x20242B, matrix: 0x010A04)
    static let sidebar = color(0xF3F3F3, dark: 0x262628, matrix: 0x010603)
    static let surface = color(0xF6F6F6, dark: 0x2B2B2E, matrix: 0x02140A, alpha: 0.82)
    static let input = color(0xF4F4F4, dark: 0x29292C, matrix: 0x03120A)
    static let hover = color(0xE9E9E9, dark: 0x333336, matrix: 0x0A2E14)
    static let selection = color(0xDEDEDE, dark: 0x424246, matrix: 0x0A2C14)
    static let text = color(0x292929, dark: 0xEBEBED, matrix: 0x5CFF85)
    static let muted = color(0x606060, dark: 0xB0B0B5, matrix: 0x2FA352)
    static let line = color(0xDEDEDE, dark: 0x3C3C40, matrix: 0x0D3A1B)
    static let purple = color(0x7552C3, dark: 0xBDA2FA, matrix: 0xA6FFC0)
    static let blue = color(0x215EBB, dark: 0x92B7FF, matrix: 0x6BFFE4)
    static let outgoingMessage = color(0x1769D2, dark: 0x1764C0, matrix: 0x0B4D22)
    static let incomingMessage = color(0xEEEEF0, dark: 0x303034, matrix: 0x041C0D)
    static let green = color(0x1F734C, dark: 0x88C8A3, matrix: 0x00FF41)
    static let orange = color(0xA05B13, dark: 0xE8B36F, matrix: 0xC8FF5C)
    static let red = color(0xBB3443, dark: 0xFF98A3, matrix: 0xFF5A4E)
    static let diffAdded = color(0xDAF5E3, dark: 0x203C2D, matrix: 0x0A3A18)
    static let diffRemoved = color(0xFCE0E3, dark: 0x482B32, matrix: 0x3A0E0E)
    static let diffHunk = color(0xEAF1FC, dark: 0x263448, matrix: 0x072A22)
    // UIW React JSON View's GitHub theme, adapted for native light/dark appearance.
    static let jsonKey = color(0x6F42C1, dark: 0xD2A8FF, matrix: 0xA6FFC0)
    static let jsonString = color(0x032F62, dark: 0xA5D6FF, matrix: 0x5CFF85)
    static let jsonNumber = color(0x005CC5, dark: 0x79C0FF, matrix: 0xC8FF5C)
    static let jsonBoolean = color(0xD73A49, dark: 0xFF7B72, matrix: 0x6BFFE4)
    static let jsonHover = color(0xEEF2F8, dark: 0x303743, matrix: 0x0A2E14)
    /// Matrix overrides both appearances; its surfaces stay slightly translucent
    /// so the rain behind the feed shows through.
    private static func color(_ light: UInt32, dark: UInt32, matrix: UInt32, alpha matrixAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isMatrix = InterfaceStyle.isMatrix
            let value = isMatrix ? matrix : appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: isMatrix ? matrixAlpha : 1)
        }
    }
}

enum NativeTextTone: Equatable { case plain, user, reasoning, muted, error, command }

@MainActor
class NativeFeedCard: NSView {
    var fill = FeedPalette.surface
    var radius: CGFloat = 10
    var headerHeight: CGFloat = 0
    var drawsBorder = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill(); shape.fill()
        if drawsBorder { FeedPalette.line.setStroke(); shape.lineWidth = 1; shape.stroke() }
        if headerHeight > 0 {
            FeedPalette.line.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: headerHeight)); line.line(to: NSPoint(x: bounds.width, y: headerHeight)); line.lineWidth = 1; line.stroke()
        }
    }
}
