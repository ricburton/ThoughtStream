import Foundation

struct QueuedChat: Codable, Identifiable {
    enum State: String, Codable { case queued, submitting, uncertain, blocked, delivered }
    let id: UUID
    let text: String
    let attachments: [ChatAttachment]
    let model: String
    let effort: String
    let tier: String
    let createdAt: Date
    var expectedTurn: String? = nil
    var state: State = .queued
    var detail: String? = nil
    var baselineItems: [String]? = nil

    var itemID: String { "queued-chat:" + id.uuidString }
    @MainActor var records: [StreamRecord] {
        var result: [StreamRecord] = []
        if !text.isEmpty { result.append(StreamRecord(kind: StreamKind.user.rawValue, text: text, time: createdAt, itemID: itemID)) }
        result += attachments.enumerated().map { index, attachment in
            StreamRecord(kind: StreamKind.user.rawValue,
                         text: Session.pretty(["type": "local_image", "path": attachment.path, "name": attachment.name]),
                         time: createdAt, itemID: itemID + ":image:\(index)")
        }
        return result
    }
}

/// An atomic write is required before accepting a message or touching the wire.
/// Delivered receipts also repair a feed snapshot interrupted by a crash.
@MainActor
final class MessageOutbox {
    private(set) var messages: [QueuedChat]
    private let url: URL
    private let loadError: Error?

    init(url: URL) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                messages = try JSONDecoder().decode([QueuedChat].self, from: Data(contentsOf: url))
            } else { messages = [] }
            loadError = nil
        } catch { messages = []; loadError = error }
        for index in messages.indices where messages[index].state == .submitting {
            messages[index].state = .uncertain
            messages[index].detail = "Checking whether this message was delivered."
        }
    }

    var pending: QueuedChat? { messages.first { $0.state != .delivered } }

    static let legacyRestartPrompt = "ThoughtStream restarted while you were working, which interrupted your previous turn. Pick up exactly where you left off and carry on with the task. Check the current state first rather than assuming earlier commands or edits completed."

    static func isLegacyRestartRecord(_ record: StreamRecord) -> Bool {
        record.kind == StreamKind.user.rawValue && record.text == legacyRestartPrompt
    }

    /// Cancel the old automatic input in every state: it must never be retried
    /// during reconnection. This does not alter any provider-side conversation.
    func removeLegacyRestartPrompts() throws -> [String] {
        let cancelled = messages.filter {
            $0.text == Self.legacyRestartPrompt && $0.attachments.isEmpty
        }
        guard !cancelled.isEmpty else { return [] }
        let ids = Set(cancelled.map(\.id))
        try commit(messages.filter { !ids.contains($0.id) })
        return cancelled.map(\.itemID)
    }

    func enqueue(text: String, attachments: [ChatAttachment], settings: InferenceSettings, expectedTurn: String? = nil) throws -> QueuedChat {
        if let loadError { throw loadError }
        let message = QueuedChat(id: UUID(), text: text, attachments: attachments, model: settings.model,
                                 effort: settings.effort, tier: settings.tier, createdAt: Date(), expectedTurn: expectedTurn)
        var updated = messages; updated.append(message)
        try commit(updated)
        return message
    }

    func update(_ id: UUID, state: QueuedChat.State, detail: String? = nil, baselineItems: [String]? = nil) throws {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var updated = messages
        updated[index].state = state; updated[index].detail = detail
        if let baselineItems { updated[index].baselineItems = baselineItems }
        try commit(updated)
    }

    private func commit(_ updated: [QueuedChat]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        messages = updated
    }

    func removeDelivered() throws { try commit(messages.filter { $0.state != .delivered }) }

    func decorate(_ records: [StreamRecord]) -> [StreamRecord] {
        let pending = Dictionary(uniqueKeysWithValues: messages.filter { $0.state != .delivered }.map { ($0.itemID, $0) })
        return records.map { record in
            var record = record
            record.queuedStatus = nil; record.queuedDetail = nil; record.queuedMessageID = nil
            if let id = record.itemID, let message = pending[id] {
                record.queuedMessageID = message.id.uuidString
                // Keep recovery identity while removing the waiting label as sending starts.
                if message.state != .submitting {
                    record.queuedStatus = message.state.rawValue
                    record.queuedDetail = message.detail
                }
            } else if let id = record.itemID, let message = messages.first(where: { id.hasPrefix($0.itemID + ":image:") }), message.state != .delivered {
                record.queuedMessageID = message.id.uuidString
                if message.state != .submitting, message.text.isEmpty, id == message.itemID + ":image:0" {
                    record.queuedStatus = message.state.rawValue; record.queuedDetail = message.detail
                }
            }
            return record
        }
    }

    static func isConnectivityFailure(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                    NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut].contains(error.code)
        }
        let text = error.localizedDescription.lowercased()
        return ["workspace routing discovery failed", "network is unreachable", "network connection", "not connected to the internet",
                "offline", "dns", "failed to fetch", "connection refused", "connection reset", "timed out", "disconnected"].contains { text.contains($0) }
    }
}

