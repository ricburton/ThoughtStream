import XCTest
@testable import ThoughtStream

final class LocalModelDiscoveryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ data: Data, _ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func writeJSON(_ value: [String: Any], _ path: String, root: URL) throws {
        try write(JSONSerialization.data(withJSONObject: value), path, root: root)
    }

    func testOllamaFindsCompleteDownloadsWithoutServerAndDeduplicatesLayouts() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "a", count: 64)
        let blob: [String: Any] = ["digest": "sha256:" + digest, "size": 4, "mediaType": "application/vnd.ollama.image.model"]
        let manifest: [String: Any] = ["config": blob, "layers": [blob]]
        try write(Data("GGUF".utf8), "blobs/sha256-" + digest, root: root)
        try writeJSON(manifest, "manifests/registry.ollama.ai/library/qwen3/8b", root: root)
        try writeJSON(manifest, "manifests-v2/ollama.com/library/qwen3/8b", root: root)
        try writeJSON(manifest, "manifests/registry.ollama.ai/alice/code/latest", root: root)
        try writeJSON(manifest, "manifests/registry.ollama.ai/library/nomic-embed/latest", root: root)
        let missing: [String: Any] = ["config": blob, "layers": [["digest": "sha256:" + String(repeating: "b", count: 64), "size": 4, "mediaType": "application/vnd.ollama.image.model"]]]
        try writeJSON(missing, "manifests/registry.ollama.ai/library/incomplete/latest", root: root)
        let models = LocalModelDiskScanner.ollamaModels(root: root)
        XCTAssertEqual(models.map(\.name), ["alice/code:latest", "qwen3:8b"])
        XCTAssertEqual(models.last?.sizeBytes, 8)
        XCTAssertEqual(LocalModelDiskScanner.models(for: .ollama, home: root, environment: ["OLLAMA_MODELS": root.path]), models)
    }

    func testStudioFindsGGUFAndCompleteMLXButSkipsPartialDownloadsAndProjectionFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["chat.gguf", "mmproj-chat.gguf", "split-00001-of-00002.gguf", "split-00002-of-00002.gguf", "missing-00001-of-00002.gguf", "partial.gguf.part"] {
            try write(Data("GGUFweights".utf8), "publisher/chat/" + name, root: root)
        }
        try write(Data("invalid".utf8), "publisher/chat/broken.gguf", root: root)
        try writeJSON(["model_type": "qwen3"], "mlx-community/chat/config.json", root: root)
        try write(Data(repeating: 0, count: 16), "mlx-community/chat/model.safetensors", root: root)
        try writeJSON(["model_type": "qwen3"], "mlx-community/incomplete/config.json", root: root)
        try writeJSON(["weight_map": ["a": "model-1.safetensors", "b": "model-2.safetensors"]], "mlx-community/incomplete/model.safetensors.index.json", root: root)
        try write(Data(repeating: 0, count: 16), "mlx-community/incomplete/model-1.safetensors", root: root)
        let models = LocalModelDiskScanner.studioModels(root: root)
        XCTAssertEqual(Set(models.map(\.name)), Set(["publisher/chat/chat.gguf", "publisher/chat/split-00001-of-00002.gguf", "mlx-community/chat"]))
        XCTAssertTrue(models.allSatisfy { $0.loadMethod == .lmStudioCLI })
    }

    func testStudioUsesItsConfiguredModelFolder() throws {
        let home = try fixture(), store = try fixture()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: store) }
        try writeJSON(["downloadsFolder": store.path], ".lmstudio/settings.json", root: home)
        try write(Data("GGUFweights".utf8), "publisher/chat/model.gguf", root: store)
        let models = LocalModelDiskScanner.models(for: .lmStudio, home: home, environment: [:])
        XCTAssertEqual(models.map(\.name), ["publisher/chat/model.gguf"])
    }

    func testDiskScanDoesNotFollowDirectoryLinksOrInspectUnrelatedFolders() throws {
        let root = try fixture(), elsewhere = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        try write(Data("GGUF".utf8), "model/hidden.gguf", root: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: elsewhere)
        XCTAssertTrue(LocalModelDiskScanner.studioModels(root: root).isEmpty)
        XCTAssertTrue(LocalModelDiskScanner.models(for: .lmStudio, home: elsewhere, environment: [:]).isEmpty)
    }

    func testNativeStudioInventoryKeepsStableKeySeparateFromLoadedInstance() throws {
        let json = #"{"models":[{"type":"llm","key":"pub/chat","size_bytes":123,"loaded_instances":[{"id":"my-chat"}]},{"type":"llm","key":"pub/unloaded","loaded_instances":[]},{"type":"embedding","key":"pub/vector","loaded_instances":[]}]}"#
        let models = try XCTUnwrap(LocalModelFinder.parseLMStudio(Data(json.utf8), runtime: .lmStudio))
        XCTAssertEqual(models.map(\.identifier), ["lmstudio|pub/chat", "lmstudio|pub/unloaded"])
        XCTAssertEqual(models.first?.inferenceName, "my-chat")
        XCTAssertEqual(models.last?.loadMethod, .lmStudioAPI)
    }

    @MainActor
    func testRefreshDoesNotStartOrLoadButConcurrentResolvesShareBoth() async throws {
        let model = LocalModel(runtime: .lmStudio, name: "pub/chat", loadMethod: .lmStudioAPI)
        let box = DiscoveryRuntimeBox(model: model)
        var loads = 0
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = LocalModelRegistry(defaults: defaults, discover: { await box.statuses() },
            start: { _ in await box.start(); return true }, canStart: { _ in true },
            load: { value in loads += 1; try await Task.sleep(nanoseconds: 50_000_000); var ready = value; ready.instanceID = "loaded"; return ready })
        await registry.refresh()
        XCTAssertEqual(registry.models, [model])
        XCTAssertEqual(loads, 0)
        let initialStarts = await box.starts
        XCTAssertEqual(initialStarts, 0)
        async let first = registry.resolve(model.identifier)
        async let second = registry.resolve(model.identifier)
        let results = try await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.inferenceName == "loaded" })
        XCTAssertEqual(loads, 1)
        let starts = await box.starts
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testUnavailableDiskModelIsVisibleButNotAnAutomaticFallback() async throws {
        let model = LocalModel(runtime: .lmStudio, name: "pub/chat", loadMethod: .lmStudioCLI)
        let registry = LocalModelRegistry(discover: { [LocalRuntimeStatus(runtime: .lmStudio, isRunning: false, models: [model], isInstalled: false)] },
                                          start: { _ in XCTFail("Should not start"); return false }, canStart: { _ in false },
                                          load: { _ in XCTFail("Should not load"); return model })
        await registry.refresh()
        XCTAssertEqual(registry.models, [model])
        XCTAssertNil(registry.preferredModel())
        do { _ = try await registry.resolve(model.identifier); XCTFail("Expected missing runtime error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Start LM Studio")) }
    }

    @MainActor
    func testStudioLoadsUnloadedModelAndReturnsActualServingInstance() async throws {
        defer { LocalRuntimeStub.reset() }
        var loads = 0
        LocalRuntimeStub.respond = { request, body in
            if request.url?.path == "/api/v1/models" {
                return (200, [Data(#"{"models":[{"type":"llm","key":"pub/chat","loaded_instances":[]}]}"#.utf8)])
            }
            XCTAssertEqual(request.url?.path, "/api/v1/models/load")
            XCTAssertEqual(body["model"] as? String, "pub/chat")
            loads += 1
            return (200, [Data(#"{"status":"loaded","instance_id":"actual-instance"}"#.utf8)])
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocalRuntimeStub.self]
        let ready = try await LocalModelLoader.prepare(LocalModel(runtime: .lmStudio, name: "pub/chat", loadMethod: .lmStudioAPI), session: URLSession(configuration: config))
        XCTAssertEqual(ready.identifier, "lmstudio|pub/chat")
        XCTAssertEqual(ready.inferenceName, "actual-instance")
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testStudioReusesResidentModelAndReportsLoadFailure() async throws {
        defer { LocalRuntimeStub.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocalRuntimeStub.self]
        let session = URLSession(configuration: config)
        let model = LocalModel(runtime: .lmStudio, name: "pub/chat", loadMethod: .lmStudioAPI)
        LocalRuntimeStub.respond = { request, _ in
            XCTAssertEqual(request.url?.path, "/api/v1/models")
            return (200, [Data(#"{"models":[{"type":"llm","key":"pub/chat","loaded_instances":[{"id":"resident"}]}]}"#.utf8)])
        }
        let resident = try await LocalModelLoader.prepare(model, session: session)
        XCTAssertEqual(resident.inferenceName, "resident")
        LocalRuntimeStub.respond = { request, _ in
            if request.url?.path == "/api/v1/models" { return (200, [Data(#"{"models":[]}"#.utf8)]) }
            return (500, [Data(#"{"error":"Insufficient memory"}"#.utf8)])
        }
        do { _ = try await LocalModelLoader.prepare(model, session: session); XCTFail("Expected load error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Insufficient memory")) }
    }
}

private actor DiscoveryRuntimeBox {
    let model: LocalModel
    private var running = false
    private(set) var starts = 0
    init(model: LocalModel) { self.model = model }
    func statuses() -> [LocalRuntimeStatus] { [LocalRuntimeStatus(runtime: model.runtime, isRunning: running, models: [model], isInstalled: true)] }
    func start() async {
        starts += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        running = true
    }
}
