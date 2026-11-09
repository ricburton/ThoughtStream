import Foundation

struct PythonDiagnostic: Codable, Sendable {
    let code: String
    let message: String
    let line: Int
    let column: Int
    let endLine: Int
    let endColumn: Int
}

struct PythonAnalysis: Codable, Sendable {
    let source: String
    let formatted: String
    let diagnostics: [PythonDiagnostic]
    let state: String
    let message: String?
}

/// Runs only Ruff's static formatter/linter against stdin, never Python or a shell.
actor PythonAnalysisService {
    static let shared = PythonAnalysisService()
    private var cache: [String: PythonAnalysis] = [:]
    private var order: [String] = []

    func analyze(_ source: String) -> PythonAnalysis {
        if let result = cache[source] { return result }
        let result = Self.analyze(source, executable: Self.executable)
        cache[source] = result; order.append(source)
        if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
    static var executable: URL? {
        let package = Bundle.main.url(forResource: "ThoughtStream_ThoughtStream", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
        #if arch(arm64)
        let name = "ruff-arm64"
        #else
        let name = "ruff-x86_64"
        #endif
        return package.url(forResource: name, withExtension: nil, subdirectory: "Tools")
    }
    static func analyze(_ source: String, executable: URL?) -> PythonAnalysis {
        func unavailable(_ message: String) -> PythonAnalysis {
            PythonAnalysis(source: source, formatted: source, diagnostics: [], state: "unavailable", message: message)
        }
        guard source.utf8.count <= 262_144 else { return unavailable("Snippet too large for inline linting.") }
        guard let executable = executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return unavailable("Bundled Python checker unavailable.") }
        do {
            let formatting = try run(executable, arguments: ["format", "--isolated", "--no-cache", "--line-length", "88", "--stdin-filename", "snippet.py", "-"], source: source)
            let formatted = formatting.status == 0 ? formatting.output : source
            let lint = try run(executable, arguments: ["check", "--isolated", "--no-cache", "--select", "E4,E7,E9,F", "--output-format", "json", "--stdin-filename", "snippet.py", "-"], source: formatted)
            guard lint.status == 0 || lint.status == 1,
                  let data = lint.output.data(using: .utf8),
                  let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return unavailable("Python checker could not inspect this snippet.")
            }
            let diagnostics = records.map { record -> PythonDiagnostic in
                let start = record["location"] as? [String: Int] ?? [:]
                let end = record["end_location"] as? [String: Int] ?? [:]
                return PythonDiagnostic(code: record["code"] as? String ?? "syntax", message: record["message"] as? String ?? "Invalid syntax", line: start["row"] ?? 1, column: start["column"] ?? 1, endLine: end["row"] ?? start["row"] ?? 1, endColumn: end["column"] ?? start["column"] ?? 1)
            }
            return PythonAnalysis(source: source, formatted: formatted, diagnostics: diagnostics, state: diagnostics.isEmpty ? "clean" : "issues", message: nil)
        } catch { return unavailable("Python checker failed: \(error.localizedDescription)") }
    }
    static func run(_ executable: URL, arguments: [String], source: String) throws -> (status: Int32, output: String) {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        // Drain both streams while the child runs, so large diagnostics cannot fill a pipe.
        let errorDrain = DispatchGroup(); errorDrain.enter()
        DispatchQueue.global(qos: .utility).async { _ = errors.fileHandleForReading.readDataToEndOfFile(); errorDrain.leave() }
        try input.fileHandleForWriting.write(contentsOf: Data(source.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); errorDrain.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
