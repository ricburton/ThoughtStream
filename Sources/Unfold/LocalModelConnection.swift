import AppKit

/// A chat with a model running on this Mac. It emits the same semantic events
/// as the Codex and Claude adapters, so local turns share the native feed,
/// the approval prompts and the queue. Each connection is independent: any
/// number of panes can run local models at once, on the same or different models.
@MainActor
final class LocalModelConnection {
    var onEvent: (([String: Any]) -> Void)?
    private let session: URLSession
    private var messages: [LocalChatMessage] = []
    private var task: Task<Void, Never>?
    private var toolbox: LocalToolbox?
    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    private(set) var turnID: String?
    /// Stops a model that keeps calling tools without ever answering.
    static let maximumSteps = 40

    init(session: URLSession? = nil) { self.session = session ?? LocalModelClient.makeSession() }

    var hasContext: Bool { !messages.isEmpty }
    var isBusy: Bool { task != nil }

    /// Rebuild the conversation from saved history after a relaunch, a fork,
    /// or a move from a cloud chat. Tool traffic is summarized by its outcome.
    func seed(from history: [StreamRecord]) {
        guard messages.isEmpty else { return }
        var seeded: [LocalChatMessage] = []
        for record in history where record.queuedMessageID == nil {
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if record.kind == StreamKind.user.rawValue {
                // Attachment placeholders are records of local image paths, not prose.
                if text.hasPrefix("{"), text.contains("\"local_image\"") { continue }
                seeded.append(.user(text, images: []))
            } else if record.kind == StreamKind.prose.rawValue {
                seeded.append(.assistant(text, toolCalls: []))
            }
        }
        // The most recent exchange matters most to a small context window.
        var budget = 48_000
        var kept: [LocalChatMessage] = []
        for message in seeded.reversed() {
            let length: Int
            switch message {
            case .user(let text, _), .assistant(let text, _), .system(let text): length = text.count
            case .tool(_, _, let content): length = content.count
            }
            guard budget - length >= 0 || kept.isEmpty else { break }
            budget -= length
            kept.append(message)
        }
        messages = kept.reversed()
    }

    static func systemPrompt(project: URL, tools: Bool, date: Date = Date()) -> String {
        let day = date.formatted(date: .complete, time: .omitted)
        var text = """
        You are a capable assistant running locally on the user's Mac inside ThoughtStream. No cloud service is involved, and you work with no Internet connection.
        Today is \(day). The working folder is \(project.path). The system is macOS \(ProcessInfo.processInfo.operatingSystemVersionString).

        """
        if tools {
            text += """
            You can act on this Mac with tools: run shell commands, read, write and edit files, list folders, open files, links and apps, and run AppleScript to control apps. When the user asks you to do, change or check something on the Mac, use a tool instead of describing how. Answer directly when no action is needed.
            Relative paths are relative to the working folder. Take one small step at a time and read each result before the next. When you are done, say briefly what you did and what happened. Never claim an action or a result you did not get from a tool. If the user declines an action, stop and ask what they would like instead.

            """
        } else {
            text += "This model cannot use tools, so you cannot run commands or change files. Answer from what you know, and say plainly when something would need to be run to be sure.\n\n"
        }
        return text + AgentInstructions.text
    }

    /// Starts a turn. Progress and the outcome arrive as events.
    func send(text: String, images: [Data], model: LocalModel, project: URL, contextLength: Int) throws {
        guard task == nil else { throw LocalModelClient.error("The local model is still working. Stop it, or wait for it to finish.") }
        messages.append(.user(text, images: images))
        let turn = UUID().uuidString
        turnID = turn
        emit("turn/started", ["turn": ["id": turn]])
        task = Task { @MainActor [weak self] in
            await self?.run(turn: turn, model: model, project: project, contextLength: contextLength)
        }
    }

    private func run(turn: String, model: LocalModel, project: URL, contextLength: Int) async {
        let client = LocalModelClient(runtime: model.runtime, session: session)
        let toolbox = LocalToolbox(project: project)
        toolbox.emit = { [weak self] method, params in self?.emit(method, params) }
        toolbox.approve = { [weak self] call, summary in await self?.requestApproval(call, summary: summary) ?? false }
        self.toolbox = toolbox
        var outcome: [String: Any] = ["id": turn, "status": "completed"]
        do {
            let capabilities = await client.capabilities(of: model.inferenceName)
            var useTools = capabilities.tools ?? true
            let context = capabilities.contextLength.map { min($0, contextLength) } ?? contextLength
            var answered = false
            for _ in 0..<Self.maximumSteps {
                try Task.checkCancellation()
                let itemID = UUID().uuidString
                let prompt = [LocalChatMessage.system(Self.systemPrompt(project: project, tools: useTools))] + messages
                let request = try client.chatRequest(model: model.inferenceName, messages: prompt,
                                                     tools: useTools ? LocalToolbox.schemas : [], contextLength: context)
                let reply: LocalReply
                do {
                    reply = try await client.stream(request,
                        onText: { [weak self] in self?.emit("item/agentMessage/delta", ["itemId": itemID, "delta": $0]) },
                        onReasoning: { [weak self] in self?.emit("item/reasoning/summaryTextDelta", ["itemId": itemID + ":reasoning", "delta": $0]) })
                } catch where useTools && !Task.isCancelled && LocalModelClient.isToolsRefusal(error) {
                    // This model cannot call tools. Carry on as a plain conversation.
                    useTools = false
                    emit("runtime/stderr", ["text": "\(model.name) does not support tools, so it will answer without acting on this Mac. Choose a tool-capable model to run commands and edit files."])
                    continue
                }
                try Task.checkCancellation()
                messages.append(.assistant(reply.text, toolCalls: reply.toolCalls))
                if !reply.reasoning.isEmpty {
                    emit("item/completed", ["item": ["id": itemID + ":reasoning", "type": "reasoning", "summary": [reply.reasoning]]])
                }
                if !reply.text.isEmpty {
                    emit("item/completed", ["item": ["id": itemID, "type": "agentMessage", "text": reply.text,
                                                     "phase": reply.toolCalls.isEmpty ? "final_answer" : "commentary"]])
                }
                if reply.toolCalls.isEmpty { answered = true; break }
                for call in reply.toolCalls {
                    try Task.checkCancellation()
                    let result = await toolbox.run(call)
                    messages.append(.tool(callID: call.id, name: call.name, content: result))
                }
            }
            try Task.checkCancellation()
            if !answered {
                outcome["status"] = "failed"
                outcome["error"] = ["message": "The local model used \(Self.maximumSteps) tool steps without finishing. Send a message to continue."]
            }
        } catch is CancellationError {
            outcome["status"] = "interrupted"
        } catch {
            if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled { outcome["status"] = "interrupted" }
            else {
                outcome["status"] = "failed"
                outcome["error"] = ["message": Self.describe(error, runtime: model.runtime)]
            }
        }
        toolbox.stop()
        if self.toolbox === toolbox { self.toolbox = nil }
        // A stopped turn says nothing more, and must not touch its successor.
        guard turnID == turn else { return }
        cancelApprovals()
        turnID = nil; task = nil
        emit("turn/completed", ["turn": outcome])
    }

    static func describe(_ error: Error, runtime: LocalRuntime) -> String {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            switch value.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return "\(runtime.name) stopped answering at \(runtime.baseURL.absoluteString). Start it again, then resend."
            case NSURLErrorTimedOut:
                return "\(runtime.name) took too long to respond. The model may still be loading; try again."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Approvals

    private func requestApproval(_ call: LocalToolCall, summary: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = "local-" + UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvals[id] = continuation
                onEvent?(["id": id, "method": "local/tool/requestApproval", "_provider": "local",
                          "params": ["tool": call.name, "arguments": call.arguments, "reason": summary]])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle(id, approved: false, announce: true) }
        }
    }

    private func settle(_ id: String, approved: Bool, announce: Bool) {
        guard let continuation = approvals.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
        if announce { emit("serverRequest/resolved", ["requestId": id]) }
    }

    private func cancelApprovals() {
        for id in Array(approvals.keys) { settle(id, approved: false, announce: true) }
    }

    func respond(_ id: String, result: [String: Any]) throws {
        guard approvals[id] != nil else { throw LocalModelClient.error("This request is no longer pending.") }
        settle(id, approved: result["decision"] as? String == "accept", announce: false)
    }

    func interrupt() {
        guard let task else { return }
        toolbox?.stop()
        cancelApprovals()
        task.cancel()
    }

    /// Ends the turn at once and forgets it. Used when the chat or app closes.
    func stop() {
        toolbox?.stop()
        task?.cancel(); task = nil; turnID = nil
        cancelApprovals()
    }

    private func emit(_ method: String, _ params: [String: Any]) {
        onEvent?(["method": method, "params": params, "_provider": "local"])
    }
}
