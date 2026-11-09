#if UNFOLD_WEB_RENDERER
// Legacy web-renderer checks retained for reference; the feed now uses AppKit.
import AppKit
import WebKit
import XCTest
@testable import ThoughtStream

final class RichRenderingTests: XCTestCase {
    @MainActor
    private func ready(_ web: WKWebView, condition: String = "typeof UnfoldRenderer === 'object'") async throws {
        for _ in 0..<100 {
            if let value = try? await web.evaluateJavaScript(condition), value as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Renderer did not become ready: \(condition)")
    }
    @MainActor
    func testMarkdownJSONAndIsolatedHTMLRenderInWebKit() async throws {
        let pane = StreamPane(); _ = pane.view
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 820, height: 1380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane; window.setContentSize(NSSize(width: 820, height: 1380)); window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await ready(pane.web)
        let html = "<main style='padding:24px;background:#ede9fe;border-radius:16px'><h1>Windlines</h1><p>A small HTML window.</p><button>Explore the timeline</button><script>parent.untrustedScriptRan=true</script></main>"
        let markdown = """
        ## A clearer view
        A **beautiful** stream with `inline code` and [a source](https://example.com).

        - Markdown lists
        - Real tables

        | Feature | Status |
        | --- | --- |
        | Markdown | Ready |
        | JSON | Compact |

        ```javascript
        const greeting = "Hello, world";
        ```

        ```html
        \(html)
        ```
        """
        pane.replace([
            StreamRecord(kind: "Session", text: "turn/moderationMetadata\n{\"metadata\":{\"generation\":{},\"prompt\":{},\"tool_call\":{},\"tool_response\":{}}}", language: nil),
            StreamRecord(kind: "Agent", text: markdown, language: nil, itemID: "message"),
            StreamRecord(kind: "Code", text: "{\"name\":\"Unfold\",\"enabled\":true,\"count\":3,\"items\":[1,2]}", language: "json")
        ])
        try await ready(pane.web, condition: "document.querySelectorAll('article').length === 3 && !!document.querySelector('iframe')")
        let result = try await pane.web.evaluateJavaScript("""
        ({headings:document.querySelectorAll('h2').length, bold:document.querySelector('strong').textContent,
          rows:document.querySelectorAll('table tr').length, inline:document.querySelector('p code').textContent,
          compact:!document.querySelector('.metadata .json-node').open,
          jsonFields:document.querySelectorAll('.json-tree .key').length,
          sandbox:document.querySelector('iframe').getAttribute('sandbox'),
          isolated:document.querySelector('iframe').contentDocument === null,
          noScripts:typeof untrustedScriptRan === 'undefined',
          code:document.querySelector('.code-card code').textContent})
        """) as! [String: Any]
        XCTAssertEqual(result["headings"] as? Int, 1)
        XCTAssertEqual(result["bold"] as? String, "beautiful")
        XCTAssertEqual(result["rows"] as? Int, 3)
        XCTAssertEqual(result["inline"] as? String, "inline code")
        XCTAssertEqual(result["compact"] as? Bool, true)
        XCTAssertEqual(result["jsonFields"] as? Int, 9)
        XCTAssertEqual(result["sandbox"] as? String, "")
        XCTAssertEqual(result["isolated"] as? Bool, true)
        XCTAssertEqual(result["noScripts"] as? Bool, true)
        XCTAssertEqual(result["code"] as? String, "const greeting = \"Hello, world\";")
        if let snapshotPath = ProcessInfo.processInfo.environment["UNFOLD_SNAPSHOT_PATH"] {
            window.setFrameOrigin(NSPoint(x: 80, y: 80)); window.orderBack(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            let image = try await pane.web.takeSnapshot(configuration: configuration)
            var rect = NSRect(origin: .zero, size: image.size)
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: snapshotPath))
        }
        _ = try await pane.web.evaluateJavaScript("document.querySelector('iframe').dataset.retained='yes'")
        // Appending narrative to the same streamed item must preserve an existing preview.
        pane.replace([StreamRecord(kind: "Agent", text: markdown, language: nil, itemID: "message")])
        try await ready(pane.web, condition: "document.querySelectorAll('article').length === 1")
        _ = try await pane.web.evaluateJavaScript("document.querySelector('iframe').dataset.retained='yes'")
        pane.append(StreamRecord(kind: "Agent", text: "\n\nStill streaming.", language: nil), item: "message", delta: true)
        try await ready(pane.web, condition: "document.body.textContent.includes('Still streaming.')")
        let retained = try await pane.web.evaluateJavaScript("document.querySelector('iframe').dataset.retained") as? String
        XCTAssertEqual(retained, "yes")
        // A Markdown event-handler payload cannot execute in the host document.
        pane.append(StreamRecord(kind: "Agent", text: "<img src='x' onerror='window.untrustedScriptRan=true'>", language: nil))
        try await ready(pane.web, condition: "document.querySelectorAll('article').length === 2")
        let sanitized = try await pane.web.evaluateJavaScript("document.querySelectorAll('[onerror]').length === 0 && typeof untrustedScriptRan === 'undefined'") as? Bool
        XCTAssertEqual(sanitized, true)
        pane.append(StreamRecord(kind: "Tool", text: "{\"html\":\"<h2>Embedded HTML</h2>\"}", language: nil))
        try await ready(pane.web, condition: "document.querySelectorAll('.preview-card').length === 2")
        let nested = try await pane.web.evaluateJavaScript("[...document.querySelectorAll('iframe')].some(f=>f.srcdoc.includes('Embedded HTML'))") as? Bool
        XCTAssertEqual(nested, true)
        let fallback = try await pane.web.evaluateJavaScript("UnfoldRenderer.renderBody({kind:'Code',text:'{invalid JSON',language:'json'}).html.includes('{invalid JSON')") as? Bool
        XCTAssertEqual(fallback, true)
        let precision = try await pane.web.evaluateJavaScript("UnfoldRenderer.jsonTree(UnfoldRenderer.parseJSON('{\"id\":123456789012345678901,\"ratio\":1.2300e-12}'))") as? String
        XCTAssertTrue(precision?.contains("123456789012345678901") == true)
        XCTAssertTrue(precision?.contains("1.2300e-12") == true)
    }

    @MainActor
    func testHTMLPopoutLoadsAndJSONEscapesText() async throws {
        let preview = HTMLPreviewWindow(html: "<h1>Pop-out preview</h1>")
        defer { preview.window?.close() }
        try await ready(preview.web, condition: "!!document.querySelector('.preview-card iframe')")
        let source = try await preview.web.evaluateJavaScript("document.querySelector('iframe').srcdoc") as? String
        XCTAssertTrue(source?.contains("Pop-out preview") == true)
        XCTAssertTrue(source?.contains("script-src 'none'") == true)
        let safe = try await preview.web.evaluateJavaScript("UnfoldRenderer.jsonTree({label:'<img onerror=alert(1)>'}).includes('&lt;img')") as? Bool
        XCTAssertEqual(safe, true)
    }
}

#endif
