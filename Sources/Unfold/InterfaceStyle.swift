import AppKit

/// Whole-window looks. Rounded Panes and Matrix are experimental alternatives;
/// Breathe is the default look with less chrome and more air (see `Breathe`).
enum InterfaceStyle: String, CaseIterable {
    case standard, matrix, roundedPanes, breathe

    static let didChange = Notification.Name("ThoughtStream.interfaceStyleDidChange")
    private static let key = "unfold.interfaceStyle"
    // Dynamic palette colors read this on every resolution; keep it in memory.
    private static var stored = InterfaceStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .breathe

    static var current: InterfaceStyle {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
    static var isMatrix: Bool { stored == .matrix }
    static var isBreathe: Bool { stored == .breathe }
    /// Panes drawn as separate cards on the workspace backdrop.
    static var hasRoundedPanes: Bool { stored == .roundedPanes || stored == .breathe }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .matrix: return "Matrix"
        case .roundedPanes: return "Rounded Panes (Experimental)"
        case .breathe: return "Breathe"
        }
    }
    var keyEquivalent: String {
        switch self {
        case .standard: return "1"
        case .matrix: return "2"
        case .roundedPanes: return "3"
        case .breathe: return "4"
        }
    }
    /// Matrix is always dark; the other styles follow the system.
    var appearance: NSAppearance? { self == .matrix ? NSAppearance(named: .darkAqua) : nil }
}

extension Typography {
    /// Reading text. Matrix sets everything in the terminal's monospace.
    static func prose(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        InterfaceStyle.isMatrix
            ? .monospacedSystemFont(ofSize: max(8, (size * 0.92).rounded()), weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }
}
