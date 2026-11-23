import AppKit

/// Identity follows the conversation's provider, never the focused model picker.
enum ModelBrand: String, CaseIterable {
    case openAI, anthropic, gemini, local

    init(provider: AgentProvider) {
        switch provider {
        case .codex: self = .openAI
        case .claude: self = .anthropic
        case .gemini: self = .gemini
        case .local: self = .local
        }
    }

    var name: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .local: return "Local model"
        }
    }

    @MainActor
    var image: NSImage? { Self.images[self] }

    @MainActor
    private static let images: [ModelBrand: NSImage] = {
        var result: [ModelBrand: NSImage] = [:]
        for (brand, file) in [(ModelBrand.openAI, "openai"), (.anthropic, "anthropic"), (.gemini, "googlegemini")] {
            if let url = Bundle.module.url(forResource: file, withExtension: "svg", subdirectory: "ModelBrandIcons"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                result[brand] = image
            }
        }
        result[.local] = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Local model")
        return result
    }()

    /// Retain the SVG representation; AppKit rasterizes at the destination scale.
    @MainActor
    static func draw(_ image: NSImage?, in rect: NSRect, color: NSColor) {
        guard let image else { return }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
