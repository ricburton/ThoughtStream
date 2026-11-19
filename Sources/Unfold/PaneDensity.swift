import AppKit

/// How much room a pane has. Chrome compacts first; text only shrinks below the
/// comfortable pane width, and returns to the reader's chosen size as soon as
/// the pane has room again.
struct PaneDensity: Equatable {
    enum Width: Int, Comparable {
        case tiny, compact, snug, regular
        static func < (lhs: Width, rhs: Width) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var width: Width = .regular
    /// Too short to show the activity stream and the conversation together.
    var isShort = false

    static let regular = PaneDensity()

    /// Multiplies the reader's chosen text size. Never larger than their choice.
    var textScale: CGFloat {
        switch width {
        case .tiny: return 0.72
        case .compact: return 0.86
        case .snug, .regular: return 1
        }
    }
    /// Icon-only pane buttons and no object navigator.
    var hasCompactChrome: Bool { width < .regular }
    var edgeInset: CGFloat { width == .tiny ? 6 : PaneSpacing.textInset }

    private static let widthSteps: [(limit: CGFloat, width: Width)] = [(205, .tiny), (260, .compact), (340, .snug)]
    private static let shortHeight: CGFloat = 380
    /// A resize that hovers on a threshold must not re-typeset on every frame.
    private static let hysteresis: CGFloat = 10

    static func width(for extent: CGFloat) -> Width {
        widthSteps.first { extent < $0.limit }?.width ?? .regular
    }

    static func resolve(size: NSSize, current: PaneDensity = .regular) -> PaneDensity {
        guard size.width > 0, size.height > 0 else { return current }
        var next = current
        let direct = width(for: size.width)
        if direct != current.width {
            // Only leave the current step once clear of its boundary.
            let settled = width(for: size.width + (direct < current.width ? hysteresis : -hysteresis))
            if settled == direct { next.width = direct }
            else if abs(direct.rawValue - current.width.rawValue) > 1 { next.width = settled }
        }
        if current.isShort { next.isShort = size.height < shortHeight + hysteresis }
        else { next.isShort = size.height < shortHeight - hysteresis }
        return next
    }
}
