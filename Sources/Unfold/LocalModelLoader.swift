import Foundation

/// Loads only models already discovered on this Mac. Never pulls or downloads.
@MainActor
enum LocalModelLoader {
    static func prepare(_ model: LocalModel, session: URLSession? = nil) async throws -> LocalModel {
        switch model.loadMethod {
        case .onRequest: return model // Ollama loads the requested model at inference time.
        case .lmStudioAPI:
            let network = session ?? LocalModelClient.makeSession()
            // Recheck actual residency: LM Studio may have evicted it since discovery.
            let inventory = await LocalModelFinder.models(of: model.runtime, session: network)
            if let resident = inventory?.first(where: { $0.name == model.name }), resident.instanceID != nil { return resident }
            var request = URLRequest(url: model.runtime.baseURL.appendingPathComponent("api/v1/models/load"))
            request.httpMethod = "POST"; request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.name])
            let (data, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["status"] as? String == "loaded", let instance = json["instance_id"] as? String, !instance.isEmpty else {
                throw LocalModelClient.error(LocalModelClient.failure(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, runtime: model.runtime))
            }
            var ready = model; ready.instanceID = instance
            return ready
        case .lmStudioCLI:
            let network = session ?? LocalModelFinder.makeSession()
            // A CLI load uses the disk key as the explicit serving identifier.
            if let inventory = await LocalModelFinder.models(of: model.runtime, session: network),
               inventory.contains(where: { $0.instanceID == model.name || ($0.loadMethod == .onRequest && $0.name == model.name) }) {
                return model
            }
            guard let (executable, _) = LocalRuntimeLauncher.commandLine(model.runtime) else {
                throw LocalModelClient.error("Enable LM Studio's lms command to load \(model.name) automatically, or load it in LM Studio and refresh models.")
            }
            try await run(executable, arguments: ["load", model.name, "--identifier", model.name, "--ttl", "1800"])
            return model
        }
    }

    /// Polling keeps the main actor responsive and bounds a stuck runtime.
    private static func run(_ executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(600)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw LocalModelClient.error("LM Studio took too long to load the model. Check its memory requirements and try again.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw LocalModelClient.error("LM Studio could not load the downloaded model. Check that its model folder and available memory are correct, then try again.")
        }
    }
}
