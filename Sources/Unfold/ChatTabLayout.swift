import AppKit

enum ChatTabLayout {
    static func titleLeading(running: Bool) -> CGFloat { running ? 58 : 40 }
    static func reservedWidth(breathe: Bool, running: Bool) -> CGFloat {
        titleLeading(running: running) + (breathe ? 30 : 38)
    }
    /// Keep the first three words intact, including room for a truncation mark
    /// and the close button even when it appears on hover.
    @MainActor
    static func widths(title: String, breathe: Bool, running: Bool) -> (minimum: CGFloat, natural: CGFloat) {
        let words = title.split(whereSeparator: \.isWhitespace)
        let prefix = words.count > 3 ? String(title[..<words[2].endIndex]) + "…" : title
        let font = Typography.interfaceEmphasis
        let chrome = reservedWidth(breathe: breathe, running: running)
        let minimum = max(breathe ? Breathe.tabMinimum : 116,
                          ceil((prefix as NSString).size(withAttributes: [.font: font]).width) + chrome + 4)
        let natural = max(minimum, min(breathe ? Breathe.tabMaximum : 240,
                                      ceil((title as NSString).size(withAttributes: [.font: font]).width) + chrome + 4))
        return (minimum, natural)
    }
}
