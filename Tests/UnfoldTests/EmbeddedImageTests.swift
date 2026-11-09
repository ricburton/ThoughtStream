import AppKit
import XCTest
@testable import ThoughtStream

final class EmbeddedImageTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
    private var payload: String { #"{"type":"image","data":""# + png + #"","mimeType":"image/png"}"# }

    @MainActor
    func testRawEscapedNestedAndFencedImagesRenderAndKeepRawSource() throws {
        let escaped = String(NativeJSON.quoted(payload).dropFirst().dropLast())
        let cases = [
            payload, escaped, NativeJSON.quoted(payload),
            NativeJSON.quoted(NativeJSON.quoted(payload)),
            #"{"result":"# + NativeJSON.quoted(escaped) + "}",
            #"{"content":[{"type":"text","text":"# + NativeJSON.quoted(escaped) + "}]}",
            "```json\n\(escaped)\n```", "```\n\(payload)\n```",
            "Here is the image:\n\n\(escaped)"
        ]
        for source in cases {
            var renderer = NativeFeedRenderer(size: 16, analyses: [:])
            let blocks = renderer.render(StreamRecord(kind: "Tool", text: source, language: nil))
            let images = blocks.compactMap { if case .image(let ref) = $0 { return ref }; return nil }
            XCTAssertEqual(images.count, 1, source)
            XCTAssertEqual(images.first?.source, "data:image/png;base64," + png)
            guard case .header(_, _, _, _, let rawSource) = blocks.first else { return XCTFail("Missing header") }
            XCTAssertNotNil(rawSource)
            XCTAssertFalse(blocks.contains { if case .code(let text, _, _) = $0 { return text.string.contains(png) }; return false })
        }
    }

    @MainActor
    func testMultipleNestedImagesKeepSurroundingMetadata() throws {
        let source = #"{"label":"Two images","results":["# + NativeJSON.quoted(payload) + "," + payload + "]}"
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Tool", text: source, language: nil))
        XCTAssertEqual(blocks.filter { if case .image = $0 { return true }; return false }.count, 2)
        XCTAssertTrue(blocks.contains { if case .code(let text, _, _) = $0 { return text.string.contains("Two images") }; return false })
        guard case .header(_, _, _, _, let rawSource) = blocks.first else { return XCTFail("Missing header") }
        XCTAssertEqual(rawSource, source)
    }

    @MainActor
    func testEmbeddedImageActuallyDecodesAndFitsTheNativeRow() async throws {
        let json = try XCTUnwrap(NativeJSON.parse(payload))
        let reference = try XCTUnwrap(NativeImageReference.detect(json))
        let data = try await NativeImageStore.shared.data(for: reference, project: nil)
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(image.size, NSSize(width: 1, height: 1))
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Tool", text: payload, language: nil))
        let row = NativeFeedRow(blocks: blocks, width: 480, images: [reference.source: image], openHTML: { _ in }, openImage: { _ in })
        row.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
        row.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let imageView = try XCTUnwrap(descendants(row).compactMap { $0 as? NSImageView }.first)
        XCTAssertNotNil(imageView.image)
        XCTAssertGreaterThan(imageView.bounds.width, 0)
        XCTAssertGreaterThan(imageView.bounds.height, 0)
        XCTAssertEqual(descendants(row).compactMap { $0 as? NSButton }.first { $0.title == "Open image ↗" }?.isEnabled, true)
    }

    @MainActor
    func testOrdinaryStringsAndTruncatedJSONRemainReadable() {
        for source in [#"{"note":"{not json}","value":"42"}"#, String(payload.dropLast(10))] {
            var renderer = NativeFeedRenderer(size: 16, analyses: [:])
            let blocks = renderer.render(StreamRecord(kind: "Tool", text: source, language: nil))
            XCTAssertFalse(blocks.contains { if case .image = $0 { return true }; return false })
        }
        XCTAssertNil(NativeJSON.parseEmbedded(#"{\"type\":\"image\",\"data\":\"incomplete"#))
        XCTAssertEqual(NativeJSON.parseEmbedded(#""42""#)?.string, "42")
        XCTAssertEqual(NativeJSON.parseEmbedded(#""true""#)?.string, "true")
    }
}
