import AppKit

enum ChatTabLayout {
    static let titleLeading: CGFloat = 40
    static func reservedWidth(breathe: Bool) -> CGFloat {
        titleLeading + 14
    }
    /// Keep the first three words intact, including room for a truncation mark
    /// and room for the model icon.
    @MainActor
    static func widths(title: String, breathe: Bool) -> (minimum: CGFloat, natural: CGFloat) {
        let words = title.split(whereSeparator: \.isWhitespace)
        let prefix = words.count > 3 ? String(title[..<words[2].endIndex]) + "…" : title
        let font = InterfaceTypography.font(Typography.paneTitle)
        let chrome = reservedWidth(breathe: breathe)
        let minimum = max(breathe ? Breathe.tabMinimum : 116,
                          ceil((prefix as NSString).size(withAttributes: [.font: font]).width) + chrome + 4)
        let natural = max(minimum, min(breathe ? Breathe.tabMaximum : 240,
                                      ceil((title as NSString).size(withAttributes: [.font: font]).width) + chrome + 4))
        return (minimum, natural)
    }
}
