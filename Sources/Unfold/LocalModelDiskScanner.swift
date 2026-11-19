import Foundation

/// Reads model metadata in known stores, never a recursive scan of the home
/// directory. No model is loaded and no process is launched during discovery.
enum LocalModelDiskScanner {
    static func models(for runtime: LocalRuntime,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> [LocalModel] {
        switch runtime.key {
        case "ollama":
            let configured = environment["OLLAMA_MODELS"].flatMap { $0.isEmpty ? nil : $0 }
            let root = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? home.appendingPathComponent(".ollama/models")
            return ollamaModels(root: root, runtime: runtime)
        case "lmstudio":
            var seen = Set<String>()
            var roots = [".lmstudio/models", ".cache/lm-studio/models"].map { home.appendingPathComponent($0) }
            // LM Studio persists a custom model store here, including folders
            // shared with other local model apps. Read only this setting.
            if let settings = json(home.appendingPathComponent(".lmstudio/settings.json")),
               let path = settings["downloadsFolder"] as? String, path.hasPrefix("/"),
               path != "/", path != home.path {
                roots.insert(URL(fileURLWithPath: path), at: 0)
            }
            return roots.flatMap { studioModels(root: $0, runtime: runtime) }
                .filter { seen.insert($0.identifier).inserted }
        default: return []
        }
    }

    private static func children(_ directory: URL, directories: Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])) ?? []
        return entries.prefix(10_000).filter {
            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
            // Do not traverse directory links into unrelated folders.
            return directories ? values.isDirectory == true && values.isSymbolicLink != true
                : values.isRegularFile == true || values.isSymbolicLink == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 2_000_001), data.count <= 2_000_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    static func ollamaModels(root: URL, runtime: LocalRuntime = .ollama) -> [LocalModel] {
        var result: [LocalModel] = [], seen = Set<String>()
        // New stores may keep manifest symlinks in manifests-v2 and legacy
        // entries in manifests. Both layouts use host/namespace/model/tag.
        for layout in ["manifests-v2", "manifests"] {
            for host in children(root.appendingPathComponent(layout), directories: true) {
                for namespace in children(host, directories: true) {
                    for model in children(namespace, directories: true) {
                        for tag in children(model, directories: false) {
                            guard let manifest = json(tag), let layers = manifest["layers"] as? [[String: Any]],
                                  layers.contains(where: { $0["mediaType"] as? String == "application/vnd.ollama.image.model" }),
                                  let config = manifest["config"] as? [String: Any] else { continue }
                            let blobs = layers + [config]
                            var total: Int64 = 0
                            let complete = blobs.allSatisfy { blob in
                                guard let digest = blob["digest"] as? String,
                                      digest.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                                      let size = (blob["size"] as? NSNumber)?.int64Value, size >= 0,
                                      let actual = try? root.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
                                        .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                                      Int64(actual) == size, total <= Int64.max - size else { return false }
                                total += size
                                return true
                            }
                            guard complete else { continue }
                            let registry = host.lastPathComponent.removingPercentEncoding ?? host.lastPathComponent
                            let isDefault = ["registry.ollama.ai", "ollama.com"].contains(registry.lowercased())
                            let prefix = (isDefault ? "" : registry + "/")
                                + (isDefault && namespace.lastPathComponent == "library" ? "" : namespace.lastPathComponent + "/")
                            let name = prefix + model.lastPathComponent + ":" + tag.lastPathComponent
                            guard !name.lowercased().contains("embed"), seen.insert(name).inserted else { continue }
                            result.append(LocalModel(runtime: runtime, name: name, sizeBytes: total, fileURL: tag))
                        }
                    }
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    static func studioModels(root: URL, runtime: LocalRuntime = .lmStudio) -> [LocalModel] {
        var result: [LocalModel] = []
        for publisher in children(root, directories: true) {
            for repository in children(publisher, directories: true) {
                let key = publisher.lastPathComponent + "/" + repository.lastPathComponent
                guard !key.lowercased().contains("embed") else { continue }
                let files = children(repository, directories: false)
                for file in files where file.pathExtension.lowercased() == "gguf" {
                    guard !file.lastPathComponent.lowercased().contains("mmproj"), isGGUF(file),
                          completeGGUF(file, files: files) else { continue }
                    result.append(LocalModel(runtime: runtime, name: key + "/" + file.lastPathComponent,
                                             sizeBytes: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                                             fileURL: file, loadMethod: .lmStudioCLI))
                }
                // MLX stores have a config plus a complete set of safetensors.
                if let config = json(repository.appendingPathComponent("config.json")),
                   config["model_type"] is String,
                   files.contains(where: { $0.pathExtension == "safetensors" }), completeMLX(repository, files: files) {
                    result.append(LocalModel(runtime: runtime, name: key, fileURL: repository, loadMethod: .lmStudioCLI))
                }
            }
        }
        return result
    }

    private static func isGGUF(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    private static func completeGGUF(_ file: URL, files: [URL]) -> Bool {
        let name = file.lastPathComponent
        guard let range = name.range(of: "-[0-9]{5}-of-[0-9]{5}\\.gguf$", options: .regularExpression) else { return true }
        let suffix = String(name[range]).split(separator: "-")
        guard suffix.count == 3, suffix[0] == "00001", let count = Int(suffix[2].prefix(5)), count > 0, count <= 10_000 else { return false }
        let prefix = String(name[..<range.lowerBound])
        let names = Set(files.map(\.lastPathComponent))
        return (1...count).allSatisfy { index in
            let part = prefix + String(format: "-%05d-of-%05d.gguf", index, count)
            return names.contains(part) && isGGUF(file.deletingLastPathComponent().appendingPathComponent(part))
        }
    }

    private static func completeMLX(_ repository: URL, files: [URL]) -> Bool {
        let names = Set(files.map(\.lastPathComponent))
        let weights = files.filter { $0.pathExtension == "safetensors" }
        guard weights.allSatisfy({ ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 8 }) else { return false }
        if names.contains("model.safetensors.index.json") {
            guard let index = json(repository.appendingPathComponent("model.safetensors.index.json")),
                  let map = index["weight_map"] as? [String: String], !map.isEmpty else { return false }
            return map.values.allSatisfy { names.contains($0) }
        }
        return names.contains("model.safetensors")
    }
}
