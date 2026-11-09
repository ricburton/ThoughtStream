import XCTest
@testable import ThoughtStream

final class ToolCallResultTests: XCTestCase {
    private let item = """
    {
      "id": "toolu_01MdjtRdK3k2FRbLRAAMzBUq",
      "isError": false,
      "result": "Here is a summary:\\n\\n- **Members:** Finn Milburn and Gemini Fowler.\\n- **Origin story:** The page doesn't include one.",
      "tool": "WebFetch",
      "type": "dynamicToolCall"
    }
    """

    @MainActor
    func testCompletedToolCallRendersResultAsPlainText() throws {
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Tool", text: item, language: nil))
        XCTAssertFalse(blocks.contains { if case .code = $0 { return true }; return false })
        let text = blocks.compactMap { if case .text(let value) = $0 { return value.string }; return nil }.joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("WebFetch"))
        XCTAssertTrue(text.contains("Members: Finn Milburn"))
        XCTAssertFalse(text.contains("toolu_01"))
        XCTAssertFalse(text.contains("**"))
        guard case .header(_, _, _, _, let rawSource) = blocks.first else { return XCTFail("Missing header") }
        XCTAssertNotNil(rawSource)
    }

    @MainActor
    func testFailedAndContentBlockResults() throws {
        let failed = #"{"type":"dynamicToolCall","tool":"Read","isError":true,"result":[{"type":"text","text":"File not found"}]}"#
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let text = renderer.render(StreamRecord(kind: "Tool", text: failed, language: nil))
            .compactMap { if case .text(let value) = $0 { return value.string }; return nil }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Read · failed"))
        XCTAssertTrue(text.contains("File not found"))
    }

    @MainActor
    func testStartedToolCallStaysStructured() throws {
        let started = #"{"type":"dynamicToolCall","tool":"WebFetch","arguments":{"url":"https://example.com"}}"#
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Tool", text: started, language: nil))
        XCTAssertTrue(blocks.contains { if case .code(_, _, let label) = $0 { return label == "JSON" }; return false })
    }

    func testHighlightDescribesResultText() {
        let entries = FeedHighlightIndex.entries(for: StreamRecord(kind: "Tool", text: item, language: nil), at: 0)
        XCTAssertFalse(entries.contains { $0.kind == "JSON" })
        XCTAssertFalse(entries.isEmpty)
    }
}
