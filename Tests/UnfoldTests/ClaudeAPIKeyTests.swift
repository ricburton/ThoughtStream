import XCTest
@testable import ThoughtStream

final class ClaudeAPIKeyTests: XCTestCase {
    @MainActor
    func testModelsCheckAcceptsValidKeyAndRejectsUnauthorizedKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelsFixture.self]
        try await ClaudeConnection.checkAPIKey("accepted-fixture", configuration: configuration)
        do {
            try await ClaudeConnection.checkAPIKey("rejected-fixture", configuration: configuration)
            XCTFail("An unauthorized key should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rejected"))
            XCTAssertFalse(error.localizedDescription.contains("rejected-fixture"))
        }
    }

    func testExplicitKeyUsesAnthropicAndClearsCompetingCredentials() {
        let base = ["ANTHROPIC_BASE_URL": "https://gateway.invalid", "ANTHROPIC_AUTH_TOKEN": "gateway",
                    "CLAUDE_CODE_OAUTH_TOKEN": "login", "CLAUDE_CODE_USE_VERTEX": "1", "CLAUDECODE": "1", "PATH": "/bin"]
        let env = ClaudeConnection.environment(for: "test-only", inheriting: base)
        XCTAssertEqual(env, ["ANTHROPIC_BASE_URL": "https://api.anthropic.com", "ANTHROPIC_API_KEY": "test-only", "PATH": "/bin"])
    }

    func testLocalModePreservesExistingClaudeConfiguration() {
        let base = ["ANTHROPIC_BASE_URL": "https://gateway.invalid", "CLAUDE_CONFIG_DIR": "/custom", "CLAUDECODE": "1"]
        let env = ClaudeConnection.environment(for: nil, inheriting: base)
        XCTAssertEqual(env, ["ANTHROPIC_BASE_URL": "https://gateway.invalid", "CLAUDE_CONFIG_DIR": "/custom"])
    }
}

private final class ModelsFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let status = request.value(forHTTPHeaderField: "x-api-key") == "accepted-fixture" ? 200 : 401
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
