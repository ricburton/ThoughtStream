import Foundation

/// The optional, separately installed Inkling runtime. Discovery never downloads
/// weights or starts a server; the normal local-chat path starts it on demand.
enum InklingLocalModel {
    static let name = "inkling-2-mini"
    static let displayName = "Inkling 2 Mini"
    static let modelFile = "Inkling-2-Mini-IQ4_NL.gguf"
    static let projectionFile = "mmproj-Inkling-2-Mini-BF16.gguf"
    static let modelBytes: Int64 = 17_627_940_768
    static let projectionBytes: Int64 = 641_805_984

    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ThoughtStream/Inkling")
    }

    static func executable(in directory: URL) -> URL {
        directory.appendingPathComponent("llama-b12608/llama-server")
    }

    /// The installer only gives verified downloads their final filenames.
    static func model(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LocalModel? {
        let root = directory(home: home)
        let weights = root.appendingPathComponent(modelFile)
        let projection = root.appendingPathComponent(projectionFile)
        func complete(_ url: URL, bytes: Int64) -> Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.int64Value == bytes,
                  let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            return (try? file.read(upToCount: 4)) == Data("GGUF".utf8)
        }
        guard FileManager.default.isExecutableFile(atPath: executable(in: root).path),
              complete(weights, bytes: modelBytes), complete(projection, bytes: projectionBytes) else { return nil }
        return LocalModel(runtime: .llamaCpp, name: name, sizeBytes: modelBytes + projectionBytes,
                          parameterSize: "26.4B", fileURL: weights)
    }

    static func arguments(in directory: URL) -> [String] {
        ["--model", directory.appendingPathComponent(modelFile).path,
         "--mmproj", directory.appendingPathComponent(projectionFile).path,
         "--alias", name, "--host", "127.0.0.1", "--port", "8080",
         "--ctx-size", "16384", "--parallel", "1", "--jinja"]
    }

    static func command(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (URL, [String])? {
        guard model(home: home) != nil else { return nil }
        let root = directory(home: home)
        return (executable(in: root), arguments(in: root))
    }
}
