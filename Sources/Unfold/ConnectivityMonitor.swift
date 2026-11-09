import AppKit
import Network

enum ConnectivityState: Equatable {
    case checking, online, offline
}

extension Notification.Name {
    /// Posted on the main actor, with the ConnectivityMonitor as its object.
    static let connectivityDidChange = Notification.Name("ThoughtStream.connectivityDidChange")
}

/// Require sustained failure before going offline. Successful uncached traffic
/// is already evidence of recovery and should release queued messages at once.
struct ConnectivityStability {
    private(set) var state: ConnectivityState = .checking
    private var failures = 0
    private var firstFailure: TimeInterval?

    mutating func record(success: Bool, at time: TimeInterval) {
        if success {
            failures = 0; firstFailure = nil
            state = .online
        } else {
            failures += 1
            if firstFailure == nil { firstFailure = time }
            if failures >= 3 && time - (firstFailure ?? time) >= 6 { state = .offline }
        }
    }

    var nextDelay: TimeInterval {
        if state == .offline { return 5 }
        return failures > 0 ? 3 : 30
    }
}

/// One source of truth for connectivity. Queue consumers should observe
/// .connectivityDidChange and only resume when state == .online. The initial
/// .checking state is intentionally unverified; this state is never persisted.
/// Internet availability does not guarantee that a particular AI service is up.
@MainActor
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()
    private(set) var state: ConnectivityState = .checking
    var isOnline: Bool { state == .online }
    var isOffline: Bool { state == .offline }
    private(set) var lastSuccessfulProbe: Date?
    private(set) var lastNetworkActivity: Date?
    private(set) var isRunning = false

    private var stability = ConnectivityStability()
    private let probe: @Sendable () async -> Bool
    private let usesSystemEvents: Bool
    private let now = { ProcessInfo.processInfo.systemUptime }
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var appObserver: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var generation = UUID()
    private var lastProbeStarted: TimeInterval = -.infinity
    private var scheduledAt: TimeInterval?
    private var activityRevision: UInt64 = 0
    private var recheckRequested = false

    init(usesSystemEvents: Bool = true,
         probe: @escaping @Sendable () async -> Bool = { await InternetConnectivityProbe.check() }) {
        self.usesSystemEvents = usesSystemEvents
        self.probe = probe
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastProbeStarted = -.infinity
        lastSuccessfulProbe = nil; lastNetworkActivity = nil
        recheckRequested = false
        stability = ConnectivityStability()
        publish(.checking)
        if usesSystemEvents {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                // A satisfied route is a hint to probe, never proof of Internet.
                Task { @MainActor in self?.checkNow() }
            }
            monitor.start(queue: DispatchQueue(label: "ThoughtStream.connectivity.path", qos: .utility))
            pathMonitor = monitor
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkNow() }
            })
            // Recheck when ThoughtStream itself becomes active, not whenever
            // any other app on the Mac is activated.
            appObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkNow() }
            }
        }
        schedule(after: 0)
    }

    func stop() {
        isRunning = false; generation = UUID()
        timer?.cancel(); timer = nil; scheduledAt = nil
        inFlight?.cancel(); inFlight = nil
        pathMonitor?.cancel(); pathMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let appObserver { NotificationCenter.default.removeObserver(appObserver); self.appObserver = nil }
    }

    /// Debounced and rate limited even when many callers request a retry.
    func checkNow() {
        guard isRunning else { return }
        guard inFlight == nil else { recheckRequested = true; return }
        schedule(after: max(0, 2 - (now() - lastProbeStarted)))
    }

    /// Only live model stream frames qualify, never local runtime replies,
    /// history reads, outgoing writes, tool output, or interface reachability.
    func recordNetworkActivity() {
        guard isRunning else { return }
        activityRevision &+= 1
        lastNetworkActivity = Date()
        stability.record(success: true, at: now())
        publish(stability.state)
        // Keep the existing check deadline; a busy stream must not postpone it.
        if inFlight == nil { schedule(after: stability.nextDelay) }
    }

    private func schedule(after delay: TimeInterval) {
        let deadline = now() + delay
        if let scheduledAt, scheduledAt <= deadline { return }
        timer?.cancel()
        scheduledAt = deadline
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timer = nil; self?.scheduledAt = nil
            self?.beginProbe()
        }
    }

    private func beginProbe() {
        guard isRunning, inFlight == nil else { return }
        lastProbeStarted = now()
        let token = generation, revision = activityRevision, probe = probe
        inFlight = Task { [weak self] in
            let success = await probe()
            guard !Task.isCancelled, let self, self.isRunning, self.generation == token else { return }
            self.inFlight = nil
            if success { self.lastSuccessfulProbe = Date() }
            // A failed request may have started on the old route before a live
            // stream recovered. It must not override that newer evidence.
            if success || self.activityRevision == revision {
                self.stability.record(success: success, at: self.now())
            }
            self.publish(self.stability.state)
            let delay = self.recheckRequested ? max(0, 2 - (self.now() - self.lastProbeStarted)) : self.stability.nextDelay
            self.recheckRequested = false
            self.schedule(after: delay)
        }
    }

    private func publish(_ newState: ConnectivityState) {
        guard state != newState else { return }
        state = newState
        NotificationCenter.default.post(name: .connectivityDidChange, object: self)
    }
}

enum ProviderNetworkActivity {
    static func codex(_ event: [String: Any]) -> Bool {
        guard let method = event["method"] as? String,
              ["item/agentMessage/delta", "item/reasoning/summaryTextDelta"].contains(method),
              let params = event["params"] as? [String: Any],
              let delta = params["delta"] as? String else { return false }
        return !delta.isEmpty
    }

    static func claude(_ event: [String: Any]) -> Bool {
        guard event["type"] as? String == "stream_event",
              let stream = event["event"] as? [String: Any],
              stream["type"] as? String == "content_block_delta",
              let delta = stream["delta"] as? [String: Any] else { return false }
        switch delta["type"] as? String {
        case "text_delta": return !(delta["text"] as? String ?? "").isEmpty
        case "thinking_delta": return !(delta["thinking"] as? String ?? "").isEmpty
        case "input_json_delta": return !(delta["partial_json"] as? String ?? "").isEmpty
        default: return false
        }
    }
}

enum InternetConnectivityProbe {
    static func accepts(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return response.statusCode == 204 && response.url?.scheme == "https" && response.expectedContentLength <= 0
    }

    static func check(endpoints: [URL] = [URL(string: "https://cp.cloudflare.com/generate_204")!,
                                         URL(string: "https://www.gstatic.com/generate_204")!],
                      probe: @escaping @Sendable (URL) async -> Bool = { await EmptyHTTPProbe.check($0) }) async -> Bool {
        // Independent operators avoid declaring the whole Internet offline when
        // one host fails. HTTPS plus exact empty 204 rejects captive portal HTML.
        return await withTaskGroup(of: Bool.self) { group in
            for endpoint in endpoints { group.addTask { await probe(endpoint) } }
            for await success in group where success {
                group.cancelAll()
                return !Task.isCancelled
            }
            return false
        }
    }
}

/// Accepts no response body or redirect. Each request is uncached, unauthenticated
/// and bounded to 8 seconds (10 seconds total resource time), with cancellation
/// propagated to the underlying URLSession task. No unbounded data buffering.
final class EmptyHTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var session: URLSession?
    private var finished = false
    private var acceptedResponse = false

    init(url: URL, configuration: URLSessionConfiguration) {
        self.url = url
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    static func check(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async -> Bool {
        let operation = EmptyHTTPProbe(url: url, configuration: configuration)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { operation.start($0) }
        } onCancel: { operation.finish(false) }
    }

    private func start(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: false); return }
        self.continuation = continuation
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    private func finish(_ success: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, session = session
        self.continuation = nil; self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(returning: success)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        acceptedResponse = InternetConnectivityProbe.accepts(response)
        completionHandler(acceptedResponse ? .allow : .cancel)
        if !acceptedResponse { finish(false) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !data.isEmpty { finish(false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && acceptedResponse)
    }
}
