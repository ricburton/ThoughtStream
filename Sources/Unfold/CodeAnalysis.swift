import Foundation

struct CodeAnalysisRequest: Hashable, Sendable {
    let source: String
    let language: String
    var key: String { language == "python" ? source : language + "\u{0}" + source }
    static func language(_ value: String) -> String? {
        switch value.lowercased() {
        case "py", "python", "python3": return "python"
        case "js", "javascript", "jsx", "mjs", "cjs": return "javascript"
        case "html", "htm": return "html"
        default: return nil
        }
    }
}

/// Bundled, offline static formatters/linters. Source is stdin, never executed.
actor CodeAnalysisService {
    static let shared = CodeAnalysisService()
    private var cache: [String: PythonAnalysis] = [:]
    private var order: [String] = []
    func analyze(_ request: CodeAnalysisRequest) async -> PythonAnalysis {
        if request.language == "python" { return await PythonAnalysisService.shared.analyze(request.source) }
        if let cached = cache[request.key] { return cached }
        let result = Self.inspect(request)
        cache[request.key] = result; order.append(request.key)
        if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
    private static func inspect(_ request: CodeAnalysisRequest) -> PythonAnalysis {
        func unavailable(_ message: String) -> PythonAnalysis {
            PythonAnalysis(source: request.source, formatted: request.source, diagnostics: [], state: "unavailable", message: message)
        }
        guard request.source.utf8.count <= 262_144 else { return unavailable("Snippet too large for inline linting.") }
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("CodeAnalysis") else { return unavailable("Bundled checker unavailable.") }
        let node = folder.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { return unavailable("Bundled checker unavailable.") }
        do {
            let payload = try JSONEncoder().encode(Input(source: request.source, language: request.language))
            let output = try PythonAnalysisService.run(node, arguments: [folder.appendingPathComponent("analyze-code.cjs").path], source: String(decoding: payload, as: UTF8.self))
            guard output.status == 0 else { return unavailable("Checker could not inspect this snippet.") }
            return try JSONDecoder().decode(PythonAnalysis.self, from: Data(output.output.utf8))
        } catch { return unavailable("Checker failed: \(error.localizedDescription)") }
    }
    private struct Input: Encodable { let source: String; let language: String }
}
