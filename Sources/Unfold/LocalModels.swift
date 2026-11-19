import AppKit

/// A model server running on this Mac (or one the user pointed at).
struct LocalRuntime: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Ollama's native API: tool calls, thinking and a chosen context size.
        case ollama
        /// The OpenAI-compatible API served by LM Studio, Jan, llama.cpp and MLX.
        case openAI
    }
    let key: String
    let name: String
    let baseURL: URL
    let kind: Kind

    static let ollama = LocalRuntime(key: "ollama", name: "Ollama", baseURL: URL(string: "http://127.0.0.1:11434")!, kind: .ollama)
    static let lmStudio = LocalRuntime(key: "lmstudio", name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234")!, kind: .openAI)
    static let jan = LocalRuntime(key: "jan", name: "Jan", baseURL: URL(string: "http://127.0.0.1:1337")!, kind: .openAI)
    static let llamaCpp = LocalRuntime(key: "llamacpp", name: "llama.cpp", baseURL: URL(string: "http://127.0.0.1:8080")!, kind: .openAI)
    static let builtIn = [ollama, lmStudio, jan, llamaCpp]

    static let customEndpointsKey = "thoughtstream.local.endpoints"

    /// A server the user added by address. It is spoken to with the OpenAI-compatible API.
    static func custom(_ address: String) -> LocalRuntime? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        let label = host + (url.port.map { ":\($0)" } ?? "")
        return LocalRuntime(key: "custom:" + label, name: label, baseURL: url, kind: .openAI)
    }

    static func all(defaults: UserDefaults = .standard) -> [LocalRuntime] {
        var seen = Set<String>()
        let custom = (defaults.stringArray(forKey: customEndpointsKey) ?? []).compactMap(Self.custom)
        return (builtIn + custom).filter { seen.insert($0.baseURL.absoluteString).inserted }
    }
}

struct LocalModel: Equatable, Sendable {
    let runtime: LocalRuntime
    let name: String
    var sizeBytes: Int64? = nil
    var parameterSize: String? = nil
    /// Stable disk identity is separate from the runtime's loaded instance ID.
    var fileURL: URL? = nil
    var instanceID: String? = nil
    var loadMethod: LoadMethod = .onRequest
    enum LoadMethod: Sendable { case onRequest, lmStudioAPI, lmStudioCLI }
    var inferenceName: String { instanceID ?? name }

    /// Stored as the chat's model, so a chat stays with one runtime's copy.
    var identifier: String { runtime.key + "|" + name }
    var displayName: String { name + " · " + runtime.name }

    var record: [String: Any] {
        var record: [String: Any] = ["model": identifier, "displayName": displayName, "localModel": name, "runtime": runtime.name]
        if let sizeBytes { record["sizeBytes"] = sizeBytes }
        return record
    }

    static func split(_ identifier: String) -> (runtime: String, model: String)? {
        guard let bar = identifier.firstIndex(of: "|") else { return nil }
        let runtime = String(identifier[..<bar]), model = String(identifier[identifier.index(after: bar)...])
        return runtime.isEmpty || model.isEmpty ? nil : (runtime, model)
    }
    /// "llama3.2:latest" from "ollama|llama3.2:latest".
    static func shortName(_ identifier: String) -> String { split(identifier)?.model ?? identifier }
}

struct LocalRuntimeStatus: Equatable, Sendable {
    let runtime: LocalRuntime
    var isRunning: Bool
    var models: [LocalModel]
    /// Present on this Mac but not serving, so it can be started.
    var isInstalled: Bool
}

/// Finds model servers on this Mac. Every request goes to a loopback address
/// (or one the user added), is unauthenticated and times out quickly, so a
/// stopped runtime costs nothing.
enum LocalModelFinder {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    static func discover(runtimes: [LocalRuntime] = LocalRuntime.all(), session: URLSession? = nil,
                         installed: @escaping @Sendable (LocalRuntime) -> Bool = { LocalRuntimeLauncher.isInstalled($0) },
                         downloaded: @escaping @Sendable (LocalRuntime) -> [LocalModel] = { LocalModelDiskScanner.models(for: $0) }) async -> [LocalRuntimeStatus] {
        let session = session ?? makeSession()
        return await withTaskGroup(of: (Int, LocalRuntimeStatus).self) { group in
            for (index, runtime) in runtimes.enumerated() {
                group.addTask {
                    let models = await models(of: runtime, session: session)
                    let disk = downloaded(runtime)
                    var seen = Set<String>()
                    let combined = ((models ?? []) + disk).filter { seen.insert($0.identifier).inserted }
                    return (index, LocalRuntimeStatus(runtime: runtime, isRunning: models != nil, models: combined,
                                                      isInstalled: models != nil || installed(runtime)))
                }
            }
            var result: [(Int, LocalRuntimeStatus)] = []
            for await status in group { result.append(status) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// nil when nothing answers at the runtime's address.
    static func models(of runtime: LocalRuntime, session: URLSession) async -> [LocalModel]? {
        if runtime.key == "lmstudio" {
            let request = URLRequest(url: runtime.baseURL.appendingPathComponent("api/v1/models"))
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let models = parseLMStudio(data, runtime: runtime) { return models }
        }
        let path = runtime.kind == .ollama ? "api/tags" : "v1/models"
        var request = URLRequest(url: runtime.baseURL.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, runtime: runtime)
    }

    /// Native inventory includes downloaded models even when JIT loading is disabled.
    static func parseLMStudio(_ data: Data, runtime: LocalRuntime) -> [LocalModel]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["models"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard row["type"] as? String == "llm", let key = row["key"] as? String, !key.isEmpty else { return nil }
            let instance = (row["loaded_instances"] as? [[String: Any]])?.first?["id"] as? String
            return LocalModel(runtime: runtime, name: key, sizeBytes: (row["size_bytes"] as? NSNumber)?.int64Value,
                              parameterSize: row["params_string"] as? String, instanceID: instance,
                              loadMethod: .lmStudioAPI)
        }
    }

    static func parse(_ data: Data, runtime: LocalRuntime) -> [LocalModel]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let models: [LocalModel]
        if runtime.kind == .ollama {
            guard let rows = json["models"] as? [[String: Any]] else { return nil }
            models = rows.compactMap { row in
                guard let name = row["name"] as? String ?? row["model"] as? String, !name.isEmpty else { return nil }
                let details = row["details"] as? [String: Any]
                return LocalModel(runtime: runtime, name: name, sizeBytes: (row["size"] as? NSNumber)?.int64Value,
                                  parameterSize: details?["parameter_size"] as? String)
            }
        } else {
            guard let rows = json["data"] as? [[String: Any]] else { return nil }
            models = rows.compactMap { row in
                guard let name = row["id"] as? String, !name.isEmpty else { return nil }
                return LocalModel(runtime: runtime, name: name)
            }
        }
        // Embedding models cannot hold a conversation.
        return models.filter { !$0.name.lowercased().contains("embed") }
    }
}

/// Starts an installed runtime that is not serving yet. Nothing is installed
/// or downloaded, and nothing is started unless a local chat needs it or the
/// user asks in Settings.
enum LocalRuntimeLauncher {
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func application(_ runtime: LocalRuntime) -> URL? {
        let name: String
        switch runtime.key {
        case "ollama": name = "Ollama.app"
        case "lmstudio": name = "LM Studio.app"
        case "jan": name = "Jan.app"
        default: return nil
        }
        return ["/Applications/" + name, home + "/Applications/" + name]
            .first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    static func commandLine(_ runtime: LocalRuntime) -> (URL, [String])? {
        func first(_ paths: [String]) -> URL? {
            paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        switch runtime.key {
        case "ollama":
            return first(["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]).map { ($0, ["serve"]) }
        case "lmstudio":
            return first([home + "/.lmstudio/bin/lms", home + "/.cache/lm-studio/bin/lms"]).map { ($0, ["server", "start", "--port", "1234", "--bind", "127.0.0.1"]) }
        default: return nil
        }
    }
    static func isInstalled(_ runtime: LocalRuntime) -> Bool {
        application(runtime) != nil || commandLine(runtime) != nil
    }
    /// Only these serve models without opening a window or changing a setting.
    static func canStart(_ runtime: LocalRuntime) -> Bool {
        switch runtime.key {
        case "ollama": return isInstalled(runtime)
        case "lmstudio": return commandLine(runtime) != nil
        default: return false
        }
    }

    /// Ask the runtime to serve, then wait for it to answer.
    @MainActor
    static func start(_ runtime: LocalRuntime, session: URLSession? = nil, wait: TimeInterval = 12) async -> Bool {
        guard canStart(runtime) else { return false }
        if runtime.key == "ollama", let app = application(runtime) {
            // The app owns its server and menu bar item; open it in the background.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.hides = true; configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else if let (executable, arguments) = commandLine(runtime) {
            let task = Process()
            task.executableURL = executable; task.arguments = arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return false }
        }
        let session = session ?? LocalModelFinder.makeSession()
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if await LocalModelFinder.models(of: runtime, session: session) != nil { return true }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return false }
        }
        return false
    }
}

extension Notification.Name {
    /// Posted on the main actor when the set of local models or runtimes changes.
    static let localModelsDidChange = Notification.Name("ThoughtStream.localModelsDidChange")
}

/// What is available on this Mac right now, shared by every pane and chat.
@MainActor
final class LocalModelRegistry {
    static let shared = LocalModelRegistry()
    static let offlineFallbackKey = "thoughtstream.local.offlineFallback"
    static let contextLengthKey = "thoughtstream.local.contextLength"
    static let contextLengths = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072]

    private(set) var statuses: [LocalRuntimeStatus] = []
    private(set) var lastRefresh: Date?
    private var refreshing: Task<[LocalRuntimeStatus], Never>?
    private let discover: @Sendable () async -> [LocalRuntimeStatus]
    private let start: @MainActor (LocalRuntime) async -> Bool
    private let canStartRuntime: (LocalRuntime) -> Bool
    private let defaults: UserDefaults
    private let load: @MainActor (LocalModel) async throws -> LocalModel
    private var starting: [String: Task<Bool, Never>] = [:]
    private var loading: [String: Task<LocalModel, Error>] = [:]

    init(defaults: UserDefaults = .standard,
         discover: (@Sendable () async -> [LocalRuntimeStatus])? = nil,
         start: (@MainActor (LocalRuntime) async -> Bool)? = nil,
         canStart: ((LocalRuntime) -> Bool)? = nil,
         load: (@MainActor (LocalModel) async throws -> LocalModel)? = nil) {
        self.defaults = defaults
        self.discover = discover ?? { await LocalModelFinder.discover() }
        self.start = start ?? { await LocalRuntimeLauncher.start($0) }
        canStartRuntime = canStart ?? { LocalRuntimeLauncher.canStart($0) }
        self.load = load ?? { try await LocalModelLoader.prepare($0) }
    }

    /// Installed runtimes that are not serving but can be started from here.
    func startableRuntimes(matching key: String? = nil) -> [LocalRuntime] {
        statuses.filter { !$0.isRunning && canStartRuntime($0.runtime) && (key == nil || $0.runtime.key == key) }.map(\.runtime)
    }
    func canStart(_ runtime: LocalRuntime) -> Bool { canStartRuntime(runtime) }

    var models: [LocalModel] { statuses.flatMap(\.models) }
    var records: [[String: Any]] { models.map(\.record) }

    /// Answer the next message with a local model when the Internet is away.
    var usesLocalModelsOffline: Bool {
        get { defaults.object(forKey: Self.offlineFallbackKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.offlineFallbackKey); NotificationCenter.default.post(name: .localModelsDidChange, object: self) }
    }
    /// Tokens of conversation an Ollama model keeps in view.
    var contextLength: Int {
        get {
            let saved = defaults.integer(forKey: Self.contextLengthKey)
            return Self.contextLengths.contains(saved) ? saved : 16_384
        }
        set { defaults.set(newValue, forKey: Self.contextLengthKey) }
    }

    @discardableResult
    func refresh() async -> [LocalRuntimeStatus] {
        if let refreshing { return await refreshing.value }
        let discover = discover
        // The task publishes its own result, so everyone waiting on one scan
        // sees the models it found, whichever of them resumes first.
        let task = Task { @MainActor [weak self] () -> [LocalRuntimeStatus] in
            let found = await discover()
            self?.publish(found)
            return found
        }
        refreshing = task
        return await task.value
    }

    private func publish(_ found: [LocalRuntimeStatus]) {
        refreshing = nil
        let changed = found != statuses
        statuses = found; lastRefresh = Date()
        if changed { NotificationCenter.default.post(name: .localModelsDidChange, object: self) }
    }

    private func refreshIfStale(_ age: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        await refresh()
    }

    /// The model new local chats use: the last one chosen if it is still here.
    func preferredModel() -> LocalModel? {
        let saved = defaults.string(forKey: "thoughtstream.local.model") ?? ""
        let usable = models.filter { model in
            statuses.contains { $0.runtime == model.runtime && $0.isRunning } || canStartRuntime(model.runtime)
        }
        return usable.first { $0.identifier == saved } ?? usable.first
    }

    @discardableResult
    func startRuntime(_ runtime: LocalRuntime) async -> Bool {
        if let task = starting[runtime.key] { return await task.value }
        let task = Task { @MainActor in
            let started = await self.start(runtime)
            await self.refresh()
            self.starting[runtime.key] = nil
            return started
        }
        starting[runtime.key] = task
        return await task.value
    }

    private func prepare(_ model: LocalModel) async throws -> LocalModel {
        try Task.checkCancellation()
        if let task = loading[model.identifier] {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { @MainActor in
            defer { self.loading[model.identifier] = nil }
            let running = self.statuses.contains { $0.runtime == model.runtime && $0.isRunning }
            if !running {
                guard self.canStartRuntime(model.runtime), await self.startRuntime(model.runtime) else {
                    throw CodexConnection.error("Start \(model.runtime.name) to use \(model.name), then send again.")
                }
            }
            // Prefer fresh native inventory, but retain the exact disk model if
            // the server only advertises loaded models or uses a different alias.
            let current = self.models.first { $0.identifier == model.identifier } ?? model
            return try await self.load(current)
        }
        loading[model.identifier] = task
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    /// The runtime and model for a chat's saved choice, starting an installed
    /// runtime if it is not serving. Throws a message that says what to do next.
    func resolve(_ identifier: String) async throws -> LocalModel {
        await refreshIfStale(20)
        if let model = match(identifier) { return try await prepare(model) }
        await refresh()
        if let model = match(identifier) { return try await prepare(model) }
        // The chosen runtime, or any installed one when nothing is chosen yet.
        for runtime in startableRuntimes(matching: LocalModel.split(identifier)?.runtime) {
            if await startRuntime(runtime), let model = match(identifier) { return try await prepare(model) }
        }
        if let (runtimeKey, name) = LocalModel.split(identifier) {
            let runtime = statuses.first { $0.runtime.key == runtimeKey }
            if let runtime, runtime.isRunning {
                throw CodexConnection.error("\(name) is no longer available in \(runtime.runtime.name). Choose another local model.")
            }
            throw CodexConnection.error("\(runtime?.runtime.name ?? "The local runtime") is not running. Start it, then send again.")
        }
        if statuses.contains(where: \.isRunning) {
            throw CodexConnection.error("No local models are downloaded yet. Add one in Ollama, LM Studio or Jan, then choose Refresh Models.")
        }
        throw CodexConnection.error("No local model runtime is running on this Mac. Start Ollama, LM Studio or Jan, then choose Refresh Models.")
    }

    private func match(_ identifier: String) -> LocalModel? {
        if identifier.isEmpty { return preferredModel() }
        if let exact = models.first(where: { $0.identifier == identifier }) { return exact }
        // A model added by bare name runs on whichever runtime has it.
        guard LocalModel.split(identifier) == nil else { return nil }
        return models.first { $0.name == identifier }
    }
}
