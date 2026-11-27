import Foundation

@MainActor
final class CodexConnection {
    // API-key sessions use dedicated stdio processes with memory-only credentials.
    static var sessionAPIKey: String?
    enum AccountType: String { case chatGPT = "chatgpt", apiKey }
    nonisolated static let execAPIKeyVariable = "CODEX_API_KEY"
    private static let accountRead = "account/read"
    private static let accountLogin = "account/login/start"
    private static let memoryOnlyStore = "cli_auth_credentials_store=\"ephemeral\""
    var onEvent: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    var onNetworkActivity: () -> Void = { ConnectivityMonitor.shared.recordNetworkActivity() }
    private var configuringAPIKey = false
    private var process: Process?
    private var persistentID: UUID?
    private var socket: LocalRuntimeSocket?
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]

    func start(executable: URL, project: URL? = nil, persistentID: UUID? = nil) async throws {
        guard process == nil, socket == nil else { return }
        let directory = try project ?? AgentInstructions.runtimeDirectory()
        if let key = Self.sessionAPIKey {
            try await startWithKey(key, executable: executable, directory: directory)
            return
        }
        if let persistentID {
            self.persistentID = persistentID
            let url = try await CodexRuntimeHost.ensure(executable: executable, project: directory, id: persistentID)
            let socket = LocalRuntimeSocket(); self.socket = socket
            socket.onMessage = { [weak self] data in var line = data; line.append(10); self?.receive(line) }
            socket.onDisconnect = { [weak self] in self?.socket = nil; self?.disconnected() }
            do { try await socket.open(url); try await initialize() }
            catch { socket.close(); self.socket = nil; throw error }
            return
        }
        try await startStdio(executable: executable, directory: directory, ephemeral: false)
    }

    func accountType() async throws -> AccountType? {
        let result = try await request(Self.accountRead, ["refreshToken": false])
        guard let type = (result["account"] as? [String: Any])?["type"] as? String else { return nil }
        return AccountType(rawValue: type)
    }

    func startChatGPTLogin() async throws -> URL {
        let result = try await request(Self.accountLogin, ["type": AccountType.chatGPT.rawValue])
        guard let text = result["authUrl"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "auth.openai.com" else {
            throw Self.error("Codex did not provide a ChatGPT sign-in URL.")
        }
        return url
    }

    func startWithKey(_ key: String, executable: URL, directory: URL) async throws {
        configuringAPIKey = true
        defer { configuringAPIKey = false }
        try await startStdio(executable: executable, directory: directory, ephemeral: true)
        do {
            let response = try await request(Self.accountLogin, ["type": AccountType.apiKey.rawValue, "apiKey": key])
            guard response["type"] as? String == AccountType.apiKey.rawValue, try await accountType() == .apiKey else {
                throw Self.error("Codex did not accept API-key mode.")
            }
        } catch {
            stop()
            throw Self.error("Codex could not configure the OpenAI API key.")
        }
    }

    private func startStdio(executable: URL, directory: URL, ephemeral: Bool) async throws {
        let task = Process()
        task.executableURL = executable
        task.currentDirectoryURL = directory
        task.arguments = ephemeral
            ? ["-c", Self.memoryOnlyStore, "app-server"]
            : ["app-server"]
        task.standardInput = input; task.standardOutput = output; task.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: Self.execAPIKeyVariable)
        task.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, !ephemeral else { return }
            Task { @MainActor [weak self] in self?.onEvent?(["method": "runtime/stderr", "params": ["text": String(decoding: data, as: UTF8.self)]]) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.process = nil
                self.disconnected()
            }
        }
        try task.run(); process = task
        do { try await initialize() }
        catch { stop(); throw error }
    }

    private func initialize() async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "thoughtstream_native", "title": "ThoughtStream", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized", "params": [:]])
    }

    private func disconnected() {
        let pending = callbacks; callbacks.removeAll()
        for callback in pending.values { callback(.failure(Self.error("Codex disconnected."))) }
        onDisconnect?()
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            callbacks[id] = { result in
                continuation.resume(with: result.mapError { error in
                    let response = error as NSError
                    guard response.domain == "ThoughtStream.CodexResponse" else { return error }
                    var info = response.userInfo; info["CodexRequestMethod"] = method
                    return NSError(domain: response.domain, code: response.code, userInfo: info)
                })
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch { callbacks.removeValue(forKey: id); continuation.resume(throwing: error) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if let callback = self?.callbacks.removeValue(forKey: id) { callback(.failure(Self.error("\(method) timed out. The requested action may still be running."))) }
            }
        }
    }

    func listModels() async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var parameters: [String: Any] = [:]
            if let cursor { parameters["cursor"] = cursor }
            let page = try await request("model/list", parameters)
            result += page["data"] as? [[String: Any]] ?? []
            let next = page["nextCursor"] as? String
            if let next, !seenCursors.insert(next).inserted {
                throw Self.error("The model list returned a repeated page. Try refreshing again.")
            }
            cursor = next
            try Task.checkCancellation()
        } while cursor != nil
        return result
    }

    func respond(_ id: Any, result: [String: Any]) throws { try send(["id": id, "result": result]) }
    func stop(terminateRuntime: Bool = false) {
        socket?.close(); socket = nil
        buffer = Data()
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        if terminateRuntime, let persistentID { CodexRuntimeHost.stop(id: persistentID) }
        let pending = callbacks; callbacks.removeAll()
        for callback in pending.values { callback(.failure(CancellationError())) }
    }
    private func send(_ message: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: message)
        if let socket { try socket.send(bytes) }
        else {
            guard process?.isRunning == true else { throw Self.error("Codex is not running.") }
            bytes.append(10); try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        guard !configuringAPIKey else { return }
        var event = message; event["_direction"] = "outgoing"; onEvent?(event)
    }
    private func receive(_ data: Data) {
        for line in Self.completeLines(appending: data, to: &buffer) {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if ProviderNetworkActivity.codex(message) { onNetworkActivity() }
            if let id = message["id"] as? Int, message["method"] == nil, let callback = callbacks.removeValue(forKey: id) {
                if let error = message["error"] as? [String: Any] {
                    callback(.failure(NSError(domain: "ThoughtStream.CodexResponse", code: error["code"] as? Int ?? -1,
                                              userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex request failed."])))
                }
                else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
            }
            guard !configuringAPIKey else { continue }
            var event = message; event["_direction"] = "incoming"; onEvent?(event)
        }
    }
    /// Appends a chunk and returns its complete lines. Earlier bytes never
    /// contain a newline, so only the new chunk is scanned, and the buffer is
    /// trimmed once rather than once per line.
    static func completeLines(appending chunk: Data, to buffer: inout Data) -> [Data] {
        buffer.append(chunk)
        guard let newline = chunk.lastIndex(of: 10) else { return [] }
        let end = buffer.endIndex - (chunk.endIndex - newline)
        let lines = buffer[..<end].split(separator: 10).map { Data($0) }
        let remainder = buffer[(end + 1)...]
        buffer = remainder.isEmpty ? Data() : remainder.withUnsafeBytes { Data($0) }
        return lines
    }
    static func error(_ message: String) -> NSError { NSError(domain: "ThoughtStream", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
