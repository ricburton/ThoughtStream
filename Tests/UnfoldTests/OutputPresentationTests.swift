import AppKit
import XCTest
@testable import ThoughtStream

final class OutputPresentationTests: XCTestCase {
    @MainActor
    func testLongCodeStillPaintsItsLastLines() throws {
        let source = String(repeating: "let value = 123\n", count: 1500) + "let lastVisibleLine = 456"
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        let block = try XCTUnwrap(renderer.render(StreamRecord(kind: "Code", text: source, language: "swift")).last)
        guard case .code(let text, _, let label) = block else { return XCTFail("Expected code") }
        let card = NativeCodeView(text: text, source: source, label: label)
        card.appearance = NSAppearance(named: .aqua)
        card.frame = NSRect(x: 0, y: 0, width: 500, height: NativeFeedLayout.height(block, width: 500, images: [:]))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = card
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        card.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(card.subviews.compactMap { $0 as? NativeFeedTextView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: card.bounds.height - scroll.contentSize.height))
        // Capture the bottom without explicitly laying out the text: doing so
        // would conceal the lazy-layout bug this checks.
        let tail = NSRect(x: 0, y: view.bounds.maxY - 30, width: view.bounds.width, height: 26)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: tail))
        view.cacheDisplay(in: tail, to: bitmap)
        var inkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.5, max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7 {
                    inkPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(inkPixels, 20, "The last code lines must be painted, not left as an empty tail")
    }

    @MainActor
    func testTerminalResetAfterPaddingDoesNotLeaveBlankLines() throws {
        let source = "\u{1B}[32m  Build complete  \u{1B}[0m\n" + String(repeating: "  \t\u{1B}[0m\r\n", count: 100)
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        guard case .code(let text, let copySource, _) = try XCTUnwrap(renderer.render(StreamRecord(kind: "Output", text: source)).last) else {
            return XCTFail("Expected command output")
        }
        XCTAssertEqual(text.string, "Build complete")
        XCTAssertEqual(copySource, source)
    }

    @MainActor
    func testTerminalHyperlinkPaddingKeepsLabelAndRawCopy() throws {
        let source = "\u{1B}]8;;https://example.com\u{1B}\\Ready\u{1B}]8;;\u{1B}\\   \n\u{1B}[0m"
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        guard case .code(let text, let copySource, _) = try XCTUnwrap(renderer.render(StreamRecord(kind: "Output", text: source)).last) else {
            return XCTFail("Expected command output")
        }
        XCTAssertEqual(text.string, "Ready")
        XCTAssertEqual(copySource, source)
    }

    @MainActor
    func testCodeCardEndsCloseToTheLastRenderedLine() throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for width: CGFloat in [240, 600] {
            var renderer = NativeFeedRenderer(size: 14, analyses: [:])
            let blocks = renderer.render(StreamRecord(kind: "Output", text: "    A completed command with a line that wraps in a narrow pane.\n\n\u{1B}[0m"))
            let row = NativeFeedRow(blocks: blocks, width: width, images: [:], openHTML: { _ in }, openImage: { _ in })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: row.contentHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = row
            row.layoutSubtreeIfNeeded()
            let card = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeCodeView }.first)
            let text = try XCTUnwrap(descendants(card).compactMap { $0 as? NativeFeedTextView }.first)
            let layout = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            layout.ensureLayout(for: container)
            let lastLineBottom = text.convert(layout.usedRect(for: container), to: card).maxY
            XCTAssertGreaterThanOrEqual(card.bounds.maxY - lastLineBottom, 8)
            XCTAssertLessThanOrEqual(card.bounds.maxY - lastLineBottom, 13)
            window.close()
        }
    }

    @MainActor
    func testTrailingPaddingDoesNotIncreaseOutputHeightOrChangeCopySource() throws {
        let compact = "let value = 1\n\nprint(value)"
        let source = "\n  \n    let value = 1  \n \t\n    print(value) \t" + String(repeating: "\n  \t", count: 100)
        for kind in ["Output", "Code"] {
            var renderer = NativeFeedRenderer(size: 14, analyses: [:])
            let blocks = renderer.render(StreamRecord(kind: kind, text: source, language: "swift"))
            guard case .code(let text, let copySource, _) = try XCTUnwrap(blocks.last) else {
                return XCTFail("Expected a code card for \(kind)")
            }
            XCTAssertEqual(text.string, compact, kind)
            XCTAssertEqual(copySource, source, kind)
            let cleanText = NSMutableAttributedString(string: compact, attributes: text.attributes(at: 0, effectiveRange: nil))
            XCTAssertEqual(NativeFeedLayout.textHeight(text, width: 400), NativeFeedLayout.textHeight(cleanText, width: 400), accuracy: 0.5, kind)
        }
    }

    @MainActor
    func testFencedCodeAndProseKeepInternalSpacingWithoutTrailingBlankLines() throws {
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Agent", text: "Before.  \n\n```swift\n    first()  \n\n    second()\n\n\n```\n\nAfter.   \n\n\n"))
        let texts = blocks.compactMap { block -> String? in
            switch block {
            case .text(let text), .code(let text, _, _): return text.string
            default: return nil
            }
        }
        XCTAssertEqual(texts, ["Before.", "first()\n\nsecond()", "After."])
    }

    @MainActor
    func testFormatterPaddingIsRemovedBeforeDiagnostics() throws {
        let source = "x=missing\n"
        let request = CodeAnalysisRequest(source: source, language: "python")
        let formatted = "x = missing\n\n\n"
        let analysis = PythonAnalysis(source: source, formatted: formatted,
            diagnostics: [PythonDiagnostic(code: "F821", message: "Undefined name", line: 1, column: 5, endLine: 1, endColumn: 12)],
            state: "issues", message: nil)
        var renderer = NativeFeedRenderer(size: 14, analyses: [request.key: analysis])
        let blocks = renderer.render(StreamRecord(kind: "Code", text: source, language: "python"))
        guard case .code(let text, let copySource, _) = try XCTUnwrap(blocks.last) else {
            return XCTFail("Expected formatted Python")
        }
        XCTAssertEqual(text.string, "x = missing\nF821  1:5  Undefined name")
        XCTAssertEqual(copySource, formatted)
    }

    @MainActor
    func testBlankOutputHasNoEmptyCodeCardAndCRLFLinesStartFlushLeft() throws {
        var empty = NativeFeedRenderer(size: 14, analyses: [:])
        XCTAssertEqual(empty.render(StreamRecord(kind: "Output", text: " \t\r\n\n  ")).count, 1)
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        guard case .code(let text, _, _) = try XCTUnwrap(renderer.render(StreamRecord(kind: "Output", text: "  first  \r\n\tsecond \r\n \r\n")).last) else {
            return XCTFail("Expected output")
        }
        XCTAssertEqual(text.string, "first\r\nsecond")
    }
}
