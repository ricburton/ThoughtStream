import AppKit
import QuartzCore

/// A native button keeps keyboard and accessibility behavior while its small,
/// reserved icon slot provides feedback without moving the Copy label.
@MainActor
final class CopyFeedbackButton: NSButton {
    private(set) var textToCopy: String
    private let write: @MainActor (String) -> Bool
    private let reduceMotion: @MainActor () -> Bool
    private let check = CALayer()
    private let copySymbol = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var resetWork: DispatchWorkItem?
    private(set) var isShowingSuccess = false
    /// Breathing room around the label so the hover fill reads as a button, not a highlight.
    static let padding = NSSize(width: 10, height: 5)

    init(title: String = "Copy", text: String,
         write: @escaping @MainActor (String) -> Bool = CopyFeedbackButton.writeToPasteboard,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        textToCopy = text
        self.write = write
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        cell = CopyFeedbackCell(textCell: title)
        self.title = title
        font = Typography.caption
        target = self; action = #selector(copyText)
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        copySymbol.size = NSSize(width: 14, height: 14)
        image = copySymbol
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        check.name = "copy-success"
        check.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        check.contentsGravity = .resizeAspect
        check.opacity = 0
        layer?.addSublayer(check)
        setAccessibilityLabel(title)
        updateColors(animated: false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not implemented") }
    deinit {
        resetWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func updateText(_ text: String) { textToCopy = text }

    // The visible border follows our bounds, not AppKit's hidden bezel margins.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        let textHeight = ceil((font?.ascender ?? 12) - (font?.descender ?? -3))
        return NSSize(width: size.width + Self.padding.width * 2,
                      height: max(28, textHeight + Self.padding.height * 2))
    }

    private static func writeToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    override func layout() {
        super.layout()
        guard let rect = cell?.imageRect(forBounds: bounds) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        check.position = CGPoint(x: rect.midX, y: rect.midY)
        check.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateColors(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; updateColors(animated: true) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors(animated: false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetFeedback(); hovering = false; updateColors(animated: false) }
    }

    private func updateColors(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = isShowingSuccess ? FeedPalette.green : hovering ? FeedPalette.blue : FeedPalette.muted
            contentTintColor = tint
            let color = isShowingSuccess ? FeedPalette.green.cgColor.copy(alpha: 0.10)!
                : hovering ? FeedPalette.blue.cgColor.copy(alpha: 0.08)! : FeedPalette.surface.cgColor
            let previous = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.backgroundColor = color
            layer?.borderColor = isShowingSuccess ? FeedPalette.green.cgColor.copy(alpha: 0.55)
                : hovering ? FeedPalette.blue.cgColor.copy(alpha: 0.5) : FeedPalette.line.cgColor
            let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))?
                .withSymbolConfiguration(.init(paletteColors: [FeedPalette.green]))
            check.contents = symbol?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.commit()
            layer?.removeAnimation(forKey: "copy-hover")
            if animated && !reduceMotion() {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = previous; fade.toValue = color; fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer?.add(fade, forKey: "copy-hover")
            }
        }
    }

    @objc private func copyText() { performCopy() }

    @discardableResult
    func performCopy() -> Bool {
        guard isEnabled else { return false }
        resetFeedback()
        guard write(textToCopy) else {
            setAccessibilityValue("Copy failed")
            announce("Copy failed")
            return false
        }
        isShowingSuccess = true
        needsDisplay = true
        updateColors(animated: false)
        setAccessibilityValue("Copied")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        check.opacity = 1
        CATransaction.commit()
        if !reduceMotion() {
            let times: [NSNumber] = [0, 0.17, 0.83, 1]
            func frames(_ key: String, _ values: [Double]) -> CAKeyframeAnimation {
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values; animation.keyTimes = times
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                return animation
            }
            let feedback = CAAnimationGroup()
            feedback.animations = [frames("opacity", [0, 1, 1, 0]),
                frames("transform.rotation.z", [-.pi / 2, 0, 0, .pi / 2]),
                frames("transform.scale", [0.25, 1, 1, 0.25])]
            feedback.duration = 1.3
            feedback.fillMode = .forwards; feedback.isRemovedOnCompletion = false
            check.add(feedback, forKey: "copy-success")
        }
        let reset = DispatchWorkItem { [weak self] in self?.resetFeedback() }
        resetWork = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: reset)
        announce("Copied")
        return true
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    @objc private func accessibilityOptionsChanged() {
        if reduceMotion() { check.removeAllAnimations(); layer?.removeAnimation(forKey: "copy-hover") }
        updateColors(animated: false)
    }

    private func resetFeedback() {
        resetWork?.cancel(); resetWork = nil
        isShowingSuccess = false
        needsDisplay = true
        check.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        check.opacity = 0
        CATransaction.commit()
        setAccessibilityValue(nil)
        updateColors(animated: false)
    }
}

/// Keep the symbol's exact layout slot while the success layer replaces its drawing.
@MainActor
private final class CopyFeedbackCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        guard (controlView as? CopyFeedbackButton)?.isShowingSuccess != true else { return }
        super.drawImage(image, withFrame: frame, in: controlView)
    }
}
