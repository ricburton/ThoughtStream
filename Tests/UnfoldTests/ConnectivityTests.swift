import AppKit
import XCTest
@testable import ThoughtStream

final class ConnectivityTests: XCTestCase {
    func testStartupRequiresAnActualSuccessfulProbe() {
        var policy = ConnectivityStability()
        XCTAssertEqual(policy.state, .checking)
        policy.record(success: false, at: 0)
        policy.record(success: false, at: 3)
        XCTAssertEqual(policy.state, .checking)
        policy.record(success: true, at: 4)
        XCTAssertEqual(policy.state, .online)
        XCTAssertEqual(policy.nextDelay, 30)
    }

    func testSustainedFailureIsDebouncedButRecoveryIsImmediate() {
        var policy = ConnectivityStability()
        policy.record(success: true, at: 0)
        for time in [1.0, 2, 3] { policy.record(success: false, at: time) }
        XCTAssertEqual(policy.state, .online, "A rapid burst cannot flip the state")
        policy.record(success: false, at: 7)
        XCTAssertEqual(policy.state, .offline)
        policy.record(success: true, at: 8)
        XCTAssertEqual(policy.state, .online, "Verified traffic releases offline mode immediately")
        policy.record(success: false, at: 9)
        policy.record(success: false, at: 12)
        XCTAssertEqual(policy.state, .online, "Recovery resets the failure window")
        policy.record(success: false, at: 15)
        XCTAssertEqual(policy.state, .offline)
    }

    func testOfflineRetriesStayResponsiveAfterLongOutage() {
        var policy = ConnectivityStability()
        for time in [0.0, 3, 6] { policy.record(success: false, at: time) }
        XCTAssertEqual(policy.state, .offline)
        for index in 0..<100 {
            policy.record(success: false, at: Double(100 + index * 30))
            XCTAssertEqual(policy.nextDelay, 5)
        }
        policy.record(success: true, at: 4000)
        XCTAssertEqual(policy.nextDelay, 30)
        XCTAssertEqual(policy.state, .online)
    }

    func testOnlyLiveProviderFramesCountAsNetworkActivity() {
        for method in ["item/agentMessage/delta", "item/reasoning/summaryTextDelta"] {
            XCTAssertTrue(ProviderNetworkActivity.codex(["method": method, "params": ["delta": "New data"]]))
            XCTAssertFalse(ProviderNetworkActivity.codex(["method": method, "params": ["delta": ""]]))
        }
        for method in ["turn/started", "item/commandExecution/outputDelta", "runtime/stderr", "thread/read"] {
            XCTAssertFalse(ProviderNetworkActivity.codex(["method": method, "params": ["delta": "Local data"]]))
        }
        XCTAssertFalse(ProviderNetworkActivity.codex(["id": 1, "result": ["thread": [:]]]))
        XCTAssertTrue(ProviderNetworkActivity.claude(Self.claudeDelta))
        for type in ["assistant", "system", "user", "control_response", "result"] {
            XCTAssertFalse(ProviderNetworkActivity.claude(["type": type, "message": ["content": "Cached or local data"]]))
        }
    }

    @MainActor
    func testClaudeTransportReportsLiveTrafficButNotInitializationOrToolOutput() {
        let connection = ClaudeConnection()
        var count = 0
        connection.onNetworkActivity = { count += 1 }
        connection.receive(["type": "system", "subtype": "init"])
        connection.receive(["type": "user", "message": ["content": [["type": "tool_result", "content": "Local output"]]]])
        XCTAssertEqual(count, 0)
        connection.receive(Self.claudeDelta)
        XCTAssertEqual(count, 1)
    }

    func testFirstSuccessfulEndpointCancelsSlowAlternative() async {
        let cancelled = expectation(description: "Slow endpoint cancelled")
        let result = await InternetConnectivityProbe.check(endpoints: [URL(string: "https://fast.invalid")!, URL(string: "https://slow.invalid")!]) { url in
            if url.host == "fast.invalid" { return true }
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancelled.fulfill() }
            return false
        }
        XCTAssertTrue(result)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    @MainActor
    func testLiveHTTPSRecoveryAfterSimulatedOutageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THOUGHTSTREAM_LIVE_CONNECTIVITY_TEST"] == "1" else {
            throw XCTSkip("Opt in to real HTTPS connectivity requests")
        }
        let route = SimulatedRoute()
        let monitor = ConnectivityMonitor(usesSystemEvents: false) {
            guard await route.isAvailable else { return false }
            return await InternetConnectivityProbe.check()
        }
        let offline = expectation(description: "Simulated outage detected")
        let online = expectation(description: "Real HTTPS traffic verifies recovery")
        let observer = NotificationCenter.default.addObserver(forName: .connectivityDidChange, object: monitor, queue: .main) { _ in
            MainActor.assumeIsolated {
                if monitor.isOffline { offline.fulfill() }
                if monitor.isOnline { online.fulfill() }
            }
        }
        defer { monitor.stop(); NotificationCenter.default.removeObserver(observer) }
        monitor.start()
        await fulfillment(of: [offline], timeout: 10)
        await route.restore()
        monitor.checkNow()
        await fulfillment(of: [online], timeout: 12)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertNotNil(monitor.lastSuccessfulProbe)
    }

    private static var claudeDelta: [String: Any] {
        ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Fresh response"]]]
    }

    func testPortalRedirectAndNonEmptyResponsesDoNotCountAsConnectivity() throws {
        func response(_ status: Int, scheme: String = "https", length: String = "0") throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: URL(string: "\(scheme)://probe.example/generate_204")!,
                statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": length]))
        }
        XCTAssertTrue(InternetConnectivityProbe.accepts(try response(204)))
        for status in [200, 301, 302, 401, 403, 500, 503] {
            XCTAssertFalse(InternetConnectivityProbe.accepts(try response(status)))
        }
        XCTAssertFalse(InternetConnectivityProbe.accepts(try response(204, scheme: "http")))
        XCTAssertFalse(InternetConnectivityProbe.accepts(try response(204, length: "200")))
    }

    func testHTTPTransportRejectsPortalBodyRedirectAndNetworkFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectivityURLProtocol.self]
        for path in ["ok", "portal", "redirect", "body", "failure"] {
            let result = await EmptyHTTPProbe.check(URL(string: "https://connectivity.invalid/\(path)")!, configuration: configuration)
            XCTAssertEqual(result, path == "ok", path)
        }
    }

    func testCancellationStopsAnUnresponsiveHTTPProbe() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectivityURLProtocol.self]
        let task = Task { await EmptyHTTPProbe.check(URL(string: "https://connectivity.invalid/hang")!, configuration: configuration) }
        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        let success = await task.value
        XCTAssertFalse(success)
    }

    @MainActor
    func testMonitorPublishesVerifiedStateAndStartIsIdempotent() async {
        let online = expectation(description: "Verified online")
        let counter = ProbeCounter()
        let monitor = ConnectivityMonitor(usesSystemEvents: false) { await counter.increment(); return true }
        let token = NotificationCenter.default.addObserver(forName: .connectivityDidChange, object: monitor, queue: .main) { _ in
            online.fulfill()
        }
        defer { monitor.stop(); NotificationCenter.default.removeObserver(token) }
        monitor.start(); monitor.start()
        await fulfillment(of: [online], timeout: 2)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertNotNil(monitor.lastSuccessfulProbe)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testStopDiscardsLateResultAndDoesNotOverlapProbes() async {
        let started = expectation(description: "Probe began")
        let gate = ProbeGate()
        let monitor = ConnectivityMonitor(usesSystemEvents: false) {
            started.fulfill()
            return await gate.wait()
        }
        monitor.start()
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<100 { monitor.checkNow() }
        monitor.stop()
        await gate.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(monitor.state, .checking)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.lastSuccessfulProbe)
    }

    @MainActor
    func testLiveTrafficClearsOfflineAndAutomaticallyResumesQueuedChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ConnectivityMonitor(usesSystemEvents: false, probe: { false })
        let session = Session(project: root, storageRoot: root)
        let offline = expectation(description: "Sustained outage detected")
        let resumed = expectation(description: "Queue reconnects when traffic returns")
        let observer = NotificationCenter.default.addObserver(forName: .connectivityDidChange, object: monitor, queue: .main) { _ in
            MainActor.assumeIsolated {
                if monitor.isOffline { offline.fulfill() }
            }
        }
        defer {
            session.stop(); monitor.stop()
            NotificationCenter.default.removeObserver(observer)
        }
        var attempts = 0
        session.configureMessageQueue(connectivity: monitor) {
            attempts += 1
            resumed.fulfill()
            // Stop at the connection boundary; this test sends no provider request.
            throw CodexConnection.error("Fixture connection rejected")
        }
        try session.enqueueChat("Keep this queued until connectivity returns", attachments: [], settings: .preferred)
        await fulfillment(of: [offline], timeout: 10)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(session.outbox.pending?.state, .queued)
        monitor.recordNetworkActivity()
        XCTAssertTrue(monitor.isOnline)
        XCTAssertNotNil(monitor.lastNetworkActivity)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testOldFailedProbeCannotScheduleFailureRetriesAfterNewTraffic() async {
        let started = expectation(description: "Old probe started")
        let extraProbe = expectation(description: "Stale failure must not schedule a rapid retry")
        extraProbe.isInverted = true
        let gate = ProbeGate(), counter = ProbeCounter()
        let monitor = ConnectivityMonitor(usesSystemEvents: false) {
            await counter.increment()
            if await counter.count == 1 {
                started.fulfill()
                return await gate.wait()
            }
            extraProbe.fulfill()
            return false
        }
        defer { monitor.stop() }
        monitor.start()
        await fulfillment(of: [started], timeout: 2)
        monitor.recordNetworkActivity()
        await gate.finish(false)
        await fulfillment(of: [extraProbe], timeout: 3.3)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertNil(monitor.lastSuccessfulProbe, "Provider traffic is not mislabeled as a probe")
        monitor.stop()
        monitor.recordNetworkActivity()
        monitor.start()
        XCTAssertEqual(monitor.state, .checking)
        XCTAssertNil(monitor.lastNetworkActivity)
    }

    @MainActor
    func testPillPositionRespectsNotchAndExternalDisplayOrigins() {
        let screen = NSRect(x: -1728, y: 200, width: 1728, height: 1117)
        let window = NSRect(x: -1600, y: 400, width: 1000, height: 800)
        let size = NSSize(width: 150, height: 42)
        let notched = OfflineWindowIndicator.pillFrame(window: window, screen: screen, safeTop: 38, size: size)
        XCTAssertEqual(notched.midX, screen.midX)
        XCTAssertEqual(notched.maxY, screen.maxY - 42)
        let external = OfflineWindowIndicator.pillFrame(window: window, screen: screen, safeTop: 0, size: size)
        XCTAssertEqual(external.midX, window.midX)
        XCTAssertEqual(external.maxY, window.maxY - 5)
        XCTAssertTrue(screen.contains(external))
    }

    @MainActor
    func testIndicatorIsNoninteractiveAndRendersBothAppearances() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
            view.wantsLayer = true
            view.layer?.backgroundColor = (name == .aqua ? NSColor.white : NSColor(white: 0.12, alpha: 1)).cgColor
            view.appearance = NSAppearance(named: name)
            let edge = OfflineEdgeView(frame: view.bounds)
            view.addSubview(edge)
            let pill = OfflinePillView(frame: NSRect(x: 175, y: 60, width: 150, height: 42))
            view.addSubview(pill)
            view.layoutSubtreeIfNeeded()
            XCTAssertNil(edge.hitTest(NSPoint(x: 10, y: 10)))
            XCTAssertNil(pill.hitTest(NSPoint(x: 25, y: 25)))
            XCTAssertEqual(pill.accessibilityLabel(), "Offline Mode")
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/thoughtstream-offline-\(name == .aqua ? "light" : "dark").png"))
        }
    }
}

private actor ProbeCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor ProbeGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func finish(_ success: Bool = true) { continuation?.resume(returning: success); continuation = nil }
}

private final class ConnectivityURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        if path == "hang" { return }
        if path == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = path == "portal" ? 200 : path == "redirect" ? 302 : 204
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "body" || path == "portal" { client?.urlProtocol(self, didLoad: Data("Captive portal".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SimulatedRoute {
    private(set) var isAvailable = false
    func restore() { isAvailable = true }
}
