import AppKit
import QuartzCore

/// Animate pictures of the panes in one coordinate space. The real split tree
/// can settle immediately without clipping moving panes at its new dividers.
@MainActor
final class PaneCloseTransition: NSView {
    static let duration: TimeInterval = 0.32
    private var pictures: [UUID: PaneTransitionPicture] = [:]
    private var completion: (() -> Void)?
    private(set) var isAnimating = false

    static func capture(_ panes: [(UUID, NSView)], in container: NSView,
                        continuing previous: PaneCloseTransition? = nil) -> PaneCloseTransition? {
        guard container.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let transition = PaneCloseTransition(frame: container.bounds)
        for (id, pane) in panes {
            let rect = container.convert(pane.bounds, from: pane)
            // Include the neighboring viewport so a previously offscreen pane
            // can slide in when the canvas shrinks or scroll position clamps.
            let nearby = container.bounds.insetBy(dx: -container.bounds.width, dy: -container.bounds.height)
            guard rect.intersects(nearby), rect.width > 0, rect.height > 0 else { continue }
            let image: NSImage
            let start: NSRect
            if let existing = previous?.pictures[id] {
                image = existing.currentImage
                start = existing.layer?.presentation()?.frame ?? existing.frame
            } else {
                guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { continue }
                pane.cacheDisplay(in: pane.bounds, to: bitmap)
                image = NSImage(size: pane.bounds.size)
                image.addRepresentation(bitmap)
                start = rect
            }
            let picture = PaneTransitionPicture(frame: start, image: image)
            transition.pictures[id] = picture
            transition.addSubview(picture)
        }
        return transition.pictures.isEmpty ? nil : transition
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        (InterfaceStyle.isBreathe ? FeedPalette.backdrop : FeedPalette.canvas).setFill()
        dirtyRect.fill()
    }

    func animate(closing id: UUID, to destinations: [UUID: NSRect],
                 livePanes: [UUID: NSView] = [:],
                 completion: @escaping () -> Void) {
        self.completion = completion
        isAnimating = true
        for (paneID, picture) in pictures where paneID != id {
            if let pane = livePanes[paneID] { picture.prepareIncoming(pane) }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.18, 1)
            for (paneID, picture) in pictures {
                if paneID == id {
                    picture.shrinkAway()
                } else if let destination = destinations[paneID] {
                    picture.animator().frame = destination
                    picture.blendIncoming()
                } else {
                    picture.animator().alphaValue = 0
                }
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.revealLivePanes() }
        })
    }

    private func revealLivePanes() {
        guard isAnimating else { return }
        // Briefly blend resized text into the fully laid-out live panes.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.06
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    func cancel() {
        isAnimating = false
        layer?.removeAllAnimations()
        pictures.values.forEach { $0.layer?.removeAllAnimations() }
        removeFromSuperview()
        let callback = completion
        completion = nil
        callback?()
    }
}

/// Two unscaled images blend as the clipping rectangle changes size. Titles,
/// messages and controls keep their proportions instead of stretching sideways.
@MainActor
final class PaneTransitionPicture: NSView {
    private let outgoing = NSImageView()
    private var incoming: NSImageView?
    var currentImage: NSImage { incoming?.image ?? outgoing.image! }

    init(frame: NSRect, image: NSImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = InterfaceStyle.hasRoundedPanes ? PaneSurface.radius : 0
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        configure(outgoing, image: image)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    private func configure(_ picture: NSImageView, image: NSImage) {
        picture.frame = bounds
        picture.autoresizingMask = [.width, .height]
        picture.image = image
        picture.imageScaling = .scaleNone
        picture.imageAlignment = .alignTopLeft
        picture.wantsLayer = true
        picture.setAccessibilityElement(false)
        addSubview(picture)
    }

    func prepareIncoming(_ pane: NSView) {
        guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return }
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let image = NSImage(size: pane.bounds.size)
        image.addRepresentation(bitmap)
        let picture = NSImageView()
        configure(picture, image: image)
        picture.alphaValue = 0
        incoming = picture
    }

    func blendIncoming() {
        guard let incoming else { return }
        outgoing.animator().alphaValue = 0
        incoming.animator().alphaValue = 1
    }

    func shrinkAway() {
        guard let layer else { return }
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, 0.72, 0.72, 1)
        transform = CATransform3DTranslate(transform, -dx, -dy, 0)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: transform)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let dismissal = CAAnimationGroup()
        dismissal.animations = [shrink, fade]
        dismissal.duration = 0.24
        dismissal.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        dismissal.fillMode = .forwards
        dismissal.isRemovedOnCompletion = false
        layer.add(dismissal, forKey: "paneDismiss")
    }
}
