import AppKit

/// Applies the terminal face to native controls as well as custom-drawn text.
/// Keep each control's original font so switching themes restores its exact
/// size, weight, and numeric spacing instead of guessing a system-font match.
@MainActor
enum InterfaceTypography {
    private static let originalFonts = NSMapTable<NSControl, NSFont>.weakToStrongObjects()

    static func font(_ original: NSFont) -> NSFont {
        guard InterfaceStyle.isMatrix else { return original }
        let traits = original.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        return .monospacedSystemFont(ofSize: original.pointSize, weight: NSFont.Weight(rawValue: weight))
    }

    static func apply(to view: NSView) {
        if let control = view as? NSControl, let current = control.font {
            let original = originalFonts.object(forKey: control) ?? current
            if InterfaceStyle.isMatrix {
                originalFonts.setObject(original, forKey: control)
                control.font = font(original)
            } else if originalFonts.object(forKey: control) != nil {
                control.font = original
                originalFonts.removeObject(forKey: control)
            }
            if let label = control as? NSTextField {
                if let placeholder = label.placeholderString, !placeholder.isEmpty {
                    label.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                        .font: control.font ?? Typography.interface, .foregroundColor: FeedPalette.muted
                    ])
                }
                if label.textColor == .labelColor || label.textColor == .controlTextColor {
                    label.textColor = FeedPalette.text
                } else if label.textColor == .secondaryLabelColor {
                    label.textColor = FeedPalette.muted
                }
            }
            if let button = control as? NSButton, !button.title.isEmpty, button.contentTintColor == nil {
                button.contentTintColor = FeedPalette.text
            }
        }
        view.needsDisplay = true
        view.subviews.forEach { apply(to: $0) }
    }
}

/// Native popup cells otherwise keep AppKit's white menu titles in Matrix.
/// Restyle on drawing too: model discovery can replace items after a theme change.
@MainActor
final class ThemedPopUpButton: NSPopUpButton {
    override class var cellClass: AnyClass? {
        get { ThemedPopUpButtonCell.self }
        set {}
    }
    override func viewWillDraw() {
        updateTypography()
        super.viewWillDraw()
    }

    func updateTypography() {
        let desiredFont = InterfaceTypography.font(Typography.interface)
        if font != desiredFont { font = desiredFont }
        if menu?.font != desiredFont { menu?.font = desiredFont }
        if contentTintColor != FeedPalette.text { contentTintColor = FeedPalette.text }
        for item in itemArray where !item.isSeparatorItem {
            let title = InterfaceStyle.isMatrix ? NSAttributedString(string: item.title, attributes: [
                .font: font ?? Typography.interface,
                .foregroundColor: item.isEnabled ? FeedPalette.text : FeedPalette.muted
            ]) : nil
            if item.attributedTitle != title { item.attributedTitle = title }
        }
    }
}

@MainActor
private func matrixTitle(_ title: NSAttributedString, cell: NSButtonCell) -> NSAttributedString {
    let styled = NSMutableAttributedString(attributedString: title)
    // Inline cells substitute a small system face even when the control has a
    // monospace font. Match that compact scale while preserving native layout.
    if cell.bezelStyle == .inline, title.length > 0,
       let measuredFont = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
        styled.addAttribute(.font, value: Typography.prose(ofSize: measuredFont.pointSize, weight: .medium),
                            range: NSRange(location: 0, length: styled.length))
    }
    styled.addAttribute(.foregroundColor, value: cell.isEnabled ? FeedPalette.text : FeedPalette.muted,
                        range: NSRange(location: 0, length: styled.length))
    return styled
}

@MainActor
final class ThemedPopUpButtonCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard InterfaceStyle.isMatrix else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        return super.drawTitle(matrixTitle(title, cell: self), withFrame: frame, in: controlView)
    }
}

@MainActor
final class ThemedButton: NSButton {
    override class var cellClass: AnyClass? {
        get { ThemedButtonCell.self }
        set {}
    }
}

@MainActor
final class ThemedButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        if InterfaceStyle.isMatrix {
            return super.drawTitle(matrixTitle(title, cell: self), withFrame: frame, in: controlView)
        }
        // Inline cells otherwise substitute the system accent color for text.
        if bezelStyle == .inline, let tint = (controlView as? NSButton)?.contentTintColor {
            let styled = NSMutableAttributedString(attributedString: title)
            styled.addAttribute(.foregroundColor, value: isEnabled ? tint : FeedPalette.muted,
                                range: NSRange(location: 0, length: styled.length))
            return super.drawTitle(styled, withFrame: frame, in: controlView)
        }
        return super.drawTitle(title, withFrame: frame, in: controlView)
    }
}
