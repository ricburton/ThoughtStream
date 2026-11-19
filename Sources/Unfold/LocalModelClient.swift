import Foundation

struct LocalToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// One conversation turn in a form both wire protocols can be built from.
enum LocalChatMessage {
    case system(String)
    case user(String, images: [Data])
    case assistant(String, toolCalls: [LocalToolCall])
    case tool(callID: String, name: String, content: String)
}

struct LocalReply {
    var text = ""
    var reasoning = ""
    var toolCalls: [LocalToolCall] = []
}

/// Models that reason inline wrap it in <think> tags. Route that text to the
/// reasoning channel even when a tag is split across streamed fragments.
struct ThinkTagSplitter {
    private var inside = false
    private var pending = ""

    mutating func feed(_ fragment: String) -> (text: String, reasoning: String) {
        var buffer = pending + fragment
        pending = ""
        var text = "", reasoning = ""
        while !buffer.isEmpty {
            let tag = inside ? "</think>" : "<think>"
            if let range = buffer.range(of: tag) {
                if inside { reasoning += buffer[..<range.lowerBound] } else { text += buffer[..<range.lowerBound] }
                inside.toggle()
                buffer = String(buffer[range.upperBound...])
                continue
            }
            // Hold back a tail that could be the start of the tag.
            var held = 0
            for length in stride(from: min(tag.count - 1, buffer.count), to: 0, by: -1) where tag.hasPrefix(buffer.suffix(length)) {
                held = length; break
            }
            let ready = String(buffer.dropLast(held))
            if inside { reasoning += ready } else { text += ready }
            pending = String(buffer.suffix(held))
            buffer = ""
        }
        return (text, reasoning)
    }

    mutating func finish() -> (text: String, reasoning: String) {
        defer { pending = "" }
        return inside ? ("", pending) : (pending, "")
    }
}

struct LocalModelCapabilities: Equatable {
    /// nil when the runtime does not say; tools are then offered and withdrawn on refusal.
    var tools: Bool?
    var contextLength: Int?
}

/// Talks to one local runtime. Ollama uses its native chat API; everything
/// else uses the OpenAI-compatible one. Both stream, and both can call tools.
@MainActor
struct LocalModelClient {
    let runtime: LocalRuntime
    let session: URLSession

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // A large model can take minutes to load before its first token.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "ThoughtStream", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated static func isToolsRefusal(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("tool") && (text.contains("support") || text.contains("not allowed") || text.contains("unknown field") || text.contains("invalid"))
    }

    // MARK: Requests

    nonisolated static func encode(_ message: LocalChatMessage, for kind: LocalRuntime.Kind) -> [String: Any] {
        switch message {
        case .system(let text): return ["role": "system", "content": text]
        case .user(let text, let images):
            if images.isEmpty { return ["role": "user", "content": text] }
            if kind == .ollama { return ["role": "user", "content": text, "images": images.map { $0.base64EncodedString() }] }
            var parts: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
            parts += images.map { ["type": "image_url", "image_url": ["url": "data:image/png;base64," + $0.base64EncodedString()]] }
            return ["role": "user", "content": parts]
        case .assistant(let text, let calls):
            var value: [String: Any] = ["role": "assistant", "content": text]
            guard !calls.isEmpty else { return value }
            value["tool_calls"] = calls.map { call -> [String: Any] in
                if kind == .ollama { return ["function": ["name": call.name, "arguments": call.arguments]] }
                let arguments = (try? JSONSerialization.data(withJSONObject: call.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments]]
            }
            return value
        case .tool(let callID, let name, let content):
            return kind == .ollama ? ["role": "tool", "tool_name": name, "content": content]
                : ["role": "tool", "tool_call_id": callID, "content": content]
        }
    }

    func chatRequest(model: String, messages: [LocalChatMessage], tools: [[String: Any]], contextLength: Int?, stream: Bool = true) throws -> URLRequest {
        var body: [String: Any] = ["model": model, "stream": stream,
                                   "messages": messages.map { Self.encode($0, for: runtime.kind) }]
        if !tools.isEmpty { body["tools"] = tools }
        if runtime.kind == .ollama {
            if let contextLength { body["options"] = ["num_ctx": contextLength] }
            // Keep the model loaded between turns of a conversation.
            body["keep_alive"] = "30m"
        }
        var request = URLRequest(url: runtime.baseURL.appendingPathComponent(runtime.kind == .ollama ? "api/chat" : "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// What Ollama reports about a model. Other runtimes do not say.
    func capabilities(of model: String) async -> LocalModelCapabilities {
        guard runtime.kind == .ollama else { return LocalModelCapabilities() }
        var request = URLRequest(url: runtime.baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return LocalModelCapabilities() }
        return Self.capabilities(json)
    }

    nonisolated static func capabilities(_ show: [String: Any]) -> LocalModelCapabilities {
        let listed = show["capabilities"] as? [String]
        let info = show["model_info"] as? [String: Any] ?? [:]
        let context = info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
        return LocalModelCapabilities(tools: listed.map { $0.contains("tools") }, contextLength: context)
    }

    // MARK: Streaming

    /// Streams one assistant message. Fragments are delivered as they arrive;
    /// the returned reply holds the complete text, reasoning and tool calls.
    func stream(_ request: URLRequest, onText: (String) -> Void, onReasoning: (String) -> Void) async throws -> LocalReply {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 16_384 { break } }
            throw Self.error(Self.failure(data, status: http.statusCode, runtime: runtime))
        }
        var parser = LocalStreamParser(kind: runtime.kind)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let chunk = try parser.consume(line)
            if !chunk.reasoning.isEmpty { onReasoning(chunk.reasoning) }
            if !chunk.text.isEmpty { onText(chunk.text) }
            if parser.isDone { break }
        }
        let tail = parser.finish()
        if !tail.reasoning.isEmpty { onReasoning(tail.reasoning) }
        if !tail.text.isEmpty { onText(tail.text) }
        return parser.reply
    }

    /// A single short answer, without tools or streaming.
    func complete(model: String, messages: [LocalChatMessage]) async throws -> String {
        var request = try chatRequest(model: model, messages: messages, tools: [], contextLength: nil, stream: false)
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Self.error(Self.failure(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, runtime: runtime))
        }
        let message = json["message"] as? [String: Any]
            ?? ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        var splitter = ThinkTagSplitter()
        let first = splitter.feed(message["content"] as? String ?? ""), rest = splitter.finish()
        return first.text + rest.text
    }

    nonisolated static func failure(_ data: Data, status: Int, runtime: LocalRuntime) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(runtime.name) could not answer (status \(status))" + (detail.isEmpty ? "." : ": \(detail)")
    }
}

/// Turns either protocol's streamed lines into text, reasoning and tool calls.
struct LocalStreamParser {
    let kind: LocalRuntime.Kind
    private(set) var reply = LocalReply()
    private(set) var isDone = false
    private var splitter = ThinkTagSplitter()
    private var partialCalls: [Int: (id: String, name: String, arguments: String)] = [:]

    init(kind: LocalRuntime.Kind) { self.kind = kind }

    mutating func consume(_ line: String) throws -> (text: String, reasoning: String) {
        var payload = line.trimmingCharacters(in: .whitespaces)
        if kind == .openAI {
            // Server-sent events: only data lines carry JSON.
            guard payload.hasPrefix("data:") else {
                if payload.hasPrefix("{"), payload.contains("\"error\"") { try raise(payload) }
                return ("", "")
            }
            payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { isDone = true; return ("", "") }
        }
        guard !payload.isEmpty, let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return ("", "") }
        if let error = json["error"] {
            throw LocalModelClient.error((error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "The local model reported an error.")
        }
        var text = "", reasoning = ""
        if kind == .ollama {
            let message = json["message"] as? [String: Any] ?? [:]
            reasoning += message["thinking"] as? String ?? ""
            text += message["content"] as? String ?? ""
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
                reply.toolCalls.append(LocalToolCall(id: call["id"] as? String ?? UUID().uuidString, name: name,
                                                     arguments: Self.arguments(function["arguments"])))
            }
            if json["done"] as? Bool == true { isDone = true }
        } else {
            let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] ?? [:]
            reasoning += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            text += delta["content"] as? String ?? ""
            for (position, call) in (delta["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let index = (call["index"] as? NSNumber)?.intValue ?? position
                var partial = partialCalls[index] ?? ("", "", "")
                if let id = call["id"] as? String, !id.isEmpty { partial.id = id }
                let function = call["function"] as? [String: Any] ?? [:]
                if let name = function["name"] as? String, !name.isEmpty { partial.name = name }
                // Arguments arrive as fragments of one JSON document.
                if let fragment = function["arguments"] as? String { partial.arguments += fragment }
                else if let object = function["arguments"] as? [String: Any],
                        let data = try? JSONSerialization.data(withJSONObject: object) { partial.arguments = String(decoding: data, as: UTF8.self) }
                partialCalls[index] = partial
            }
        }
        let split = splitter.feed(text)
        reply.text += split.text
        reply.reasoning += reasoning + split.reasoning
        return (split.text, reasoning + split.reasoning)
    }

    mutating func finish() -> (text: String, reasoning: String) {
        let tail = splitter.finish()
        reply.text += tail.text; reply.reasoning += tail.reasoning
        for index in partialCalls.keys.sorted() {
            guard let call = partialCalls[index], !call.name.isEmpty else { continue }
            reply.toolCalls.append(LocalToolCall(id: call.id.isEmpty ? UUID().uuidString : call.id, name: call.name,
                                                 arguments: Self.arguments(call.arguments)))
        }
        partialCalls.removeAll()
        return tail
    }

    private func raise(_ payload: String) throws {
        let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        let error = json?["error"]
        throw LocalModelClient.error((error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "The local model reported an error.")
    }

    /// Runtimes send arguments as an object or as a JSON string of one.
    static func arguments(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, !text.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [:] }
        return object
    }
}
