#if UNFOLD_WEB_RENDERER
// Legacy web-renderer checks retained for reference; the feed now uses AppKit.
import AppKit
import WebKit
import XCTest
@testable import ThoughtStream

final class PythonRenderingTests: XCTestCase {
    @MainActor
    func testHeredocAndMarkdownRenderFormattedPythonWithRealLintResults() async throws {
        let pane = StreamPane(); _ = pane.view
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 840, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = pane
        window.setContentSize(NSSize(width: 840, height: 1000)); window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let command = "/example/project\n$ python3 - <<'PY'\nfrom pathlib import Path\nimport os\np=Path('example.txt'); print(p)\nPY"
        pane.replace([
            StreamRecord(kind: "Command", text: command, language: "bash"),
            StreamRecord(kind: "Agent", text: "```python\nx=1; print(x)\n```", language: nil)
        ])
        for _ in 0..<100 {
            let done = try? await pane.web.evaluateJavaScript("document.querySelectorAll('.python-card').length===2 && document.querySelectorAll('.lint-status.pending').length===0")
            if done as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try await pane.web.evaluateJavaScript("""
        ({count:document.querySelectorAll('.python-card').length,
          formatted:document.querySelector('.python-card .python-rendered code').textContent,
          diagnostic:document.querySelector('.lint-code').textContent,
          lineMarkers:document.querySelectorAll('.line-number.has-diagnostic').length,
          originalClosed:!document.querySelector('.shell-wrapper').open,
          original:document.querySelector('.shell-wrapper code').textContent,
          highlighted:document.querySelectorAll('.python-card .hljs-keyword').length,
          clean:document.querySelectorAll('.lint-status.clean').length})
        """) as! [String: Any]
        XCTAssertEqual(result["count"] as? Int, 2)
        XCTAssertTrue((result["formatted"] as? String)?.contains("p = Path(\"example.txt\")\nprint(p)") == true)
        XCTAssertEqual(result["diagnostic"] as? String, "F401")
        XCTAssertEqual(result["lineMarkers"] as? Int, 1)
        XCTAssertEqual(result["originalClosed"] as? Bool, true)
        XCTAssertEqual(result["original"] as? String, command)
        XCTAssertGreaterThan(result["highlighted"] as? Int ?? 0, 0)
        XCTAssertEqual(result["clean"] as? Int, 1)
        if let path = ProcessInfo.processInfo.environment["UNFOLD_PYTHON_SNAPSHOT"] {
            window.setFrameOrigin(NSPoint(x: 80, y: 80)); window.orderBack(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            let image = try await pane.web.takeSnapshot(configuration: WKSnapshotConfiguration())
            var rect = NSRect(origin: .zero, size: image.size)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}

#endif
