import AppKit
import QuartzCore

/// Small, retargetable springs keep the card attached to the hand while its
/// tilt trails the movement. Stopping the pointer lets it settle naturally.
struct TabCardSpring {
    var value: CGFloat
    var velocity: CGFloat = 0
    mutating func step(toward target: CGFloat, stiffness: CGFloat, damping: CGFloat, dt: CGFloat) {
        velocity += ((target - value) * stiffness - velocity * damping) * dt
        value += velocity * dt
    }
}

struct TabCardMotion {
    private(set) var x: TabCardSpring
    private(set) var y: TabCardSpring
    private(set) var roll = TabCardSpring(value: 0)
    private(set) var pitch = TabCardSpring(value: 0)
    private(set) var yaw = TabCardSpring(value: 0)
    private(set) var scale = TabCardSpring(value: 1)
    var target: NSPoint

    init(center: NSPoint) { x = TabCardSpring(value: center.x); y = TabCardSpring(value: center.y); target = center }
    mutating func advance(_ elapsed: TimeInterval, reducedMotion: Bool = false) {
        if reducedMotion {
            x = TabCardSpring(value: target.x); y = TabCardSpring(value: target.y)
            roll = TabCardSpring(value: 0); pitch = TabCardSpring(value: 0); yaw = TabCardSpring(value: 0)
            scale = TabCardSpring(value: 1)
            return
        }
        var remaining = CGFloat(min(0.05, max(0, elapsed)))
        while remaining > 0 {
            let dt = min(1.0 / 240, remaining); remaining -= dt
            x.step(toward: target.x, stiffness: 1800, damping: 90, dt: dt)
            y.step(toward: target.y, stiffness: 1800, damping: 90, dt: dt)
            let vx = min(1800, max(-1800, x.velocity)), vy = min(1800, max(-1800, y.velocity))
            roll.step(toward: -vx / 22000, stiffness: 210, damping: 25, dt: dt)
            pitch.step(toward: vy / 26000, stiffness: 210, damping: 25, dt: dt)
            yaw.step(toward: vx / 30000, stiffness: 210, damping: 25, dt: dt)
            scale.step(toward: 1.055, stiffness: 320, damping: 32, dt: dt)
        }
    }
}

@MainActor
final class TabDragCardView: NSView {
    private let imageView = NSImageView()
    private var motion: TabCardMotion
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private let grip: NSPoint

    init(frame: NSRect, image: NSImage, grip: NSPoint) {
        self.grip = grip
        motion = TabCardMotion(center: NSPoint(x: frame.midX, y: frame.midY))
        super.init(frame: frame)
        wantsLayer = true; clipsToBounds = false
        layer?.masksToBounds = false
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.20
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        imageView.frame = bounds; imageView.autoresizingMask = [.width, .height]
        imageView.image = image; imageView.wantsLayer = true
        imageView.setAccessibilityElement(false)
        imageView.layer?.cornerRadius = 8; imageView.layer?.masksToBounds = true
        addSubview(imageView)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = ProcessInfo.processInfo.systemUptime
                self.motion.advance(now - self.lastTick, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                self.lastTick = now
                self.renderMotion()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    deinit { timer?.invalidate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func follow(_ point: NSPoint) {
        let lift: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 1.055
        motion.target = NSPoint(x: point.x - (grip.x - bounds.midX) * lift,
                                y: point.y - (grip.y - bounds.midY) * lift)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            motion.advance(0, reducedMotion: true); renderMotion()
        }
    }
    private func renderMotion() {
        setFrameOrigin(NSPoint(x: motion.x.value - bounds.midX, y: motion.y.value - bounds.midY))
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 900
        transform = CATransform3DRotate(transform, motion.pitch.value, 1, 0, 0)
        transform = CATransform3DRotate(transform, motion.yaw.value, 0, 1, 0)
        transform = CATransform3DRotate(transform, motion.roll.value, 0, 0, 1)
        transform = CATransform3DScale(transform, motion.scale.value, motion.scale.value, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = transform
        CATransaction.commit()
    }
    func land(at frame: NSRect) {
        timer?.invalidate(); timer = nil
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
        if let layer {
            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
            settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            settle.duration = duration
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            layer.transform = CATransform3DIdentity; layer.add(settle, forKey: "land")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            animator().frame = frame
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}
