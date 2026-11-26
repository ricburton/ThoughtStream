import AppKit
import XCTest
@testable import ThoughtStream

final class FeedContentPresentationTests: XCTestCase {
    private let source = (0..<32).map { "let responseValue\($0) = \($0)" }.joined(separator: "\n")

    @MainActor
    private func render(_ record: StreamRecord) -> [NativeFeedBlock] {
        var renderer = NativeFeedRenderer(size: 14, analyses: [:])
        return renderer.render(record)
    }

    @MainActor
    private func code(_ record: StreamRecord) throws -> (NSAttributedString, String, String) {
        for block in render(record) {
            if case .code(let text, let source, let label) = block { return (text, source, label) }
        }
        throw NSError(domain: "Missing code block", code: 1)
    }

    @MainActor
    func testIdenticalCodeOpensFullyWhenGeneratedAndCompactsWhenReadBack() throws {
        let generated = try code(StreamRecord(kind: "Code", text: source, language: "swift"))
        let output = try code(StreamRecord(kind: "Output", text: source, language: "swift"))
        let full = NativeFeedLayout.code(generated.0, source: generated.1, label: generated.2, width: 600)
        let preview = NativeFeedLayout.code(output.0, source: output.1, label: output.2, width: 600)
        XCTAssertEqual(full.collapse, .expanded(lines: 32))
        XCTAssertEqual(preview.collapse, .collapsed(lines: 32))
        XCTAssertGreaterThan(full.height, preview.height * 2)
        XCTAssertEqual(generated.1, output.1, "Presentation must preserve the full copyable source")
        XCTAssertEqual(FeedContentOrigin.read(from: generated.0), .generated)
        XCTAssertEqual(FeedContentOrigin.read(from: output.0), .output)
    }

    @MainActor
    func testGeneratedJSONIsNotClassifiedAsAnAPIResponse() throws {
        let json = "{\n" + (0..<24).map { "\"field\($0)\": \($0)" }.joined(separator: ",\n") + "\n}"
        for (kind, origin) in [("Code", FeedContentOrigin.generated), ("Tool", .apiResponse)] {
            let block = try code(StreamRecord(kind: kind, text: json, language: "json"))
            XCTAssertEqual(FeedContentOrigin.read(from: block.0), origin)
            let layout = NativeFeedLayout.code(block.0, source: block.1, label: block.2, width: 600)
            if origin == .generated {
                guard case .expanded = layout.collapse else { return XCTFail("Generated JSON should be open") }
            } else {
                guard case .collapsed = layout.collapse else { return XCTFail("API JSON should be compact") }
            }
            XCTAssertEqual(block.1, json)
        }
    }

    @MainActor
    func testToolProseAndFencedCodeAreResponsesButFinalAnswersStayVisible() throws {
        let prose = (0..<30).map { "Result \($0): returned information." }.joined(separator: "\n\n")
        let tool = try code(StreamRecord(kind: "Tool", text: prose))
        XCTAssertEqual(FeedContentOrigin.read(from: tool.0), .apiResponse)
        guard case .collapsed = NativeFeedLayout.code(tool.0, source: tool.1, label: tool.2, width: 600).collapse else {
            return XCTFail("Long tool prose should show a preview")
        }
        let fenced = try code(StreamRecord(kind: "Tool", text: "```swift\n\(source)\n```"))
        XCTAssertEqual(FeedContentOrigin.read(from: fenced.0), .apiResponse)
        XCTAssertFalse(FeedHighlightIndex.entries(for: StreamRecord(kind: "Tool", text: "```swift\n\(source)\n```"), at: 0).contains { $0.prominence == .created })
        let final = render(StreamRecord(kind: "Agent", text: prose, isFinalResponse: true))
        XCTAssertTrue(final.contains { if case .text(let text) = $0 { return text.string.contains("Result 29") }; return false })
        XCTAssertFalse(final.contains { if case .code = $0 { return true }; return false })
    }

    @MainActor
    func testProjectChangesAreDistinctFromDiffsReturnedByTools() throws {
        let diff = "--- a/Example.swift\n+++ b/Example.swift\n@@ -0,0 +1,32 @@\n" + source.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
        let change = try code(StreamRecord(kind: "File change", text: diff, language: "diff"))
        let output = try code(StreamRecord(kind: "Output", text: diff, language: "diff"))
        XCTAssertEqual(FeedContentOrigin.read(from: change.0), .projectChange)
        XCTAssertEqual(FeedContentOrigin.read(from: output.0), .output)
        let entry = try XCTUnwrap(FeedHighlightIndex.entries(for: StreamRecord(kind: "File change", text: diff), at: 0).first)
        XCTAssertEqual(entry.overviewBadge, "Project changes")
        XCTAssertEqual(entry.prominence, .created)
        guard case .expanded = NativeFeedLayout.code(change.0, source: change.1, label: change.2, width: 600).collapse else {
            return XCTFail("Actual project changes should remain open")
        }
    }

    @MainActor
    func testResponseExpansionSurvivesRecyclingWithoutChangingGeneratedCode() throws {
        let block = try code(StreamRecord(kind: "Output", text: source, language: "swift"))
        let key = CodeCollapse.key(source: block.1, label: block.2, origin: .output)
        defer { CodeCollapse.setExpanded(false, key: key) }
        CodeCollapse.setExpanded(true, key: key)
        XCTAssertEqual(NativeFeedLayout.code(block.0, source: block.1, label: block.2, width: 600).collapse, .expanded(lines: 32))
        let generated = try code(StreamRecord(kind: "Code", text: source, language: "swift"))
        CodeCollapse.setExpanded(false, key: key)
        XCTAssertEqual(NativeFeedLayout.code(generated.0, source: generated.1, label: generated.2, width: 600).collapse, .expanded(lines: 32))
    }

    @MainActor
    func testFailuresStayProminentAndResponseSummaryPrioritizesOutcome() throws {
        let failed = "{\"isError\":true,\"message\":\"Could not save\",\"details\":" + NativeJSON.quoted(source) + "}"
        let record = StreamRecord(kind: "Tool", text: failed)
        let block = try code(record)
        XCTAssertEqual(FeedContentOrigin.read(from: block.0), .error)
        guard case .expanded = NativeFeedLayout.code(block.0, source: block.1, label: block.2, width: 600).collapse else {
            return XCTFail("Failure details should remain visible")
        }
        let entry = try XCTUnwrap(FeedHighlightIndex.entries(for: record, at: 0).first)
        XCTAssertEqual(entry.prominence, .error)
        XCTAssertEqual(entry.overviewBadge, "Error")
        let value = NativeJSON.parse(#"{"id":"trace","headers":{},"data":[],"status":"failed","error":{"message":"Quota exceeded"}}"#)
        let summary = FeedSummary.objectDetail(value)
        XCTAssertTrue(summary.hasPrefix("error: Quota exceeded · status: failed"), summary)
        let pending = StreamRecord(kind: "Tool", text: #"{"type":"dynamicToolCall","tool":"Fetch","arguments":{"url":"https://example.com"}}"#)
        XCTAssertEqual(FeedContentOrigin(record: pending), .toolCall)
    }

    @MainActor
    func testPresentationPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_CONTENT_PREVIEW"] else { return }
        let json = "{\n\"status\": \"succeeded\",\n\"results\": [\n" + (0..<24).map { "{\"id\": \($0), \"name\": \"Returned API item\"}" }.joined(separator: ",\n") + "\n]}"
        let code = "struct Greeting {\n" + (0..<12).map { "    let value\($0) = \($0)" }.joined(separator: "\n") + "\n}"
        let records = [StreamRecord(kind: "Tool", text: json), StreamRecord(kind: "Code", text: code, language: "swift"), StreamRecord(kind: "File change", text: "--- a/Greeting.swift\n+++ b/Greeting.swift\n@@ -1 +1 @@\n-let title = \"Hi\"\n+let title = \"Welcome\"", language: "diff")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let root = ContentPreviewBackground(frame: .zero)
            root.appearance = NSAppearance(named: appearance)
            var y: CGFloat = 0
            for record in records {
                let row = NativeFeedRow(blocks: render(record), width: 700, images: [:], openHTML: { _ in }, openImage: { _ in })
                row.frame = NSRect(x: 0, y: y, width: 700, height: row.contentHeight)
                root.addSubview(row); y += row.contentHeight + 12
            }
            root.frame = NSRect(x: 0, y: 0, width: 700, height: y)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            defer { window.close() }
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("content-\(appearance.rawValue).png"))
        }
    }

    func testLiveFocusPrefersNewWorkAndErrorsOverPendingResponses() {
        let records = [
            StreamRecord(kind: "Code", text: "let first = 1", language: "swift"),
            StreamRecord(kind: "Tool", text: "{\"status\":\"ok\"}"),
            StreamRecord(kind: "Output", text: "A verbose command log"),
            StreamRecord(kind: "File change", text: "--- a/File.swift\n+++ b/File.swift\n+let second = 2"),
            StreamRecord(kind: "Tool", text: "More returned data"),
            StreamRecord(kind: "Error", text: "The build failed"),
            StreamRecord(kind: "Agent", text: "Here is the result", isFinalResponse: true)
        ]
        var sequence = FeedLiveFocusSequence()
        for (index, record) in records.enumerated() {
            for entry in FeedLiveFocusSequence.objects(FeedHighlightIndex.entries(for: record, at: index)) {
                sequence.offer(entry, record: record)
            }
        }
        for index in [0, 3, 5, 6] { XCTAssertEqual(sequence.next()?.highlight.record, index) }
        XCTAssertNil(sequence.next())
    }
}

@MainActor
private final class ContentPreviewBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { FeedPalette.canvas.setFill(); bounds.fill() }
}
