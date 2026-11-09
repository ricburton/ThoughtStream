import AppKit

/// A passive window edge and nonactivating pill. Neither can intercept a click,
/// take keyboard focus, or keep another application's windows in the background.
@MainActor
final class OfflineWindowIndicator {
    private weak var window: NSWindow?
    private let monitor: ConnectivityMonitor
    private let edge = OfflineEdgeView()
    private let panel: OfflineStatusPanel
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(window: NSWindow, monitor: ConnectivityMonitor? = nil) {
        self.window = window
        let monitor = monitor ?? .shared
        self.monitor = monitor
        panel = OfflineStatusPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 42),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = OfflinePillView(frame: NSRect(x: 0, y: 0, width: 150, height: 42))
        if let content = window.contentView {
            edge.frame = content.bounds
            edge.autoresizingMask = [.width, .height]
            content.addSubview(edge, positioned: .above, relativeTo: nil)
        }
        observe(.connectivityDidChange, object: monitor) { [weak self] in self?.refresh() }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observe(name, object: window) { [weak self] in self?.refresh() }
        }
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            observe(name, object: window) { [weak self] in self?.hidePanel() }
        }
        observe(NSApplication.didBecomeActiveNotification, object: nil) { [weak self] in self?.refresh() }
        observe(NSApplication.didResignActiveNotification, object: nil) { [weak self] in self?.hidePanel() }
        observe(NSApplication.didChangeScreenParametersNotification, object: nil) { [weak self] in self?.refresh() }
        refresh()
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, token))
    }

    private func refresh() {
        edge.isHidden = !monitor.isOffline
        guard monitor.isOffline, let window, window.isVisible, !window.isMiniaturized,
              NSApplication.shared.isActive, let screen = window.screen else { hidePanel(); return }
        let frame = Self.pillFrame(window: window.frame, screen: screen.frame,
                                   safeTop: screen.safeAreaInsets.top, size: panel.frame.size)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        // Child windows move with their parent, so position after attachment.
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
    }

    /// A notched screen uses the physical safe area; external displays use the
    /// window's own top center. Screen origins may be negative on multiple displays.
    static func pillFrame(window: NSRect, screen: NSRect, safeTop: CGFloat, size: NSSize) -> NSRect {
        let centerX = safeTop > 0 ? screen.midX : window.midX
        let top = safeTop > 0 ? screen.maxY - safeTop - 4 : min(window.maxY - 5, screen.maxY - 5)
        let x = min(screen.maxX - size.width - 6, max(screen.minX + 6, centerX - size.width / 2))
        return NSRect(x: x, y: max(screen.minY + 6, top - size.height), width: size.width, height: size.height)
    }

    private func hidePanel() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        hidePanel()
        edge.removeFromSuperview()
    }

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }
}

@MainActor
private final class OfflineStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OfflineEdgeView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let orange = NSColor.systemOrange
        NSGradient(starting: orange.withAlphaComponent(0.34), ending: orange.withAlphaComponent(0))?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: 15), angle: 270)
        orange.withAlphaComponent(0.62).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
final class OfflinePillView: NSView {
    private let label = NSTextField(labelWithString: "Offline Mode")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 1, green: 0.82, blue: 0.57, alpha: 1)
                : NSColor(srgbRed: 0.34, green: 0.16, blue: 0.02, alpha: 1)
        }
        icon.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = label.textColor
        for child in [icon, label] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Offline Mode")
        setAccessibilityHelp("Internet connectivity could not be verified. ThoughtStream will keep checking automatically.")
        label.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = dark ? NSColor(srgbRed: 0.30, green: 0.17, blue: 0.04, alpha: 1)
                        : NSColor(srgbRed: 1, green: 0.88, blue: 0.70, alpha: 1)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 15, yRadius: 15)
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.saveGraphicsState()
        shadow.set(); fill.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.systemOrange.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 1; shape.stroke()
    }
}
