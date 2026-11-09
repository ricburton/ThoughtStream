import AppKit
import XCTest
@testable import ThoughtStream

final class DiffRenderingTests: XCTestCase {
    private let patch = """
    diff --git a/Greeting.swift b/Greeting.swift
    index 1234567..7654321 100644
    --- a/Greeting.swift
    +++ b/Greeting.swift
    @@ -1,3 +1,4 @@
     struct Greeting {
    -    let message = "Hello"
    +    let message = "Hello, world 👋"
    +    let isVisible = true
     }
    """

    @MainActor
    private func code(_ source: String, kind: String = "File change", language: String? = nil) throws -> (NSAttributedString, String, String) {
        var renderer = NativeFeedRenderer(size: 15, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: kind, text: source, language: language))
        return try XCTUnwrap(blocks.compactMap { block in
            if case .code(let text, let raw, let label) = block { return (text, raw, label) }
            return nil
        }.first)
    }

    private func attribute(_ key: NSAttributedString.Key, in text: NSAttributedString, at needle: String) throws -> Any? {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound)
        return text.attribute(key, at: range.location, effectiveRange: nil)
    }

    @MainActor
    func testGitDiffTypesNumbersAndOriginalSource() throws {
        let (text, source, label) = try code(patch)
        XCTAssertEqual(label, "Diff")
        XCTAssertEqual(source, patch)
        XCTAssertEqual(text.string, patch)
        XCTAssertEqual(NativeDiff.summary(text), "+2  −1")
        XCTAssertEqual(try attribute(.nativeDiffKind, in: text, at: "--- a/" ) as? String, "metadata")
        XCTAssertEqual(try attribute(.nativeDiffKind, in: text, at: "+++ b/" ) as? String, "metadata")
        XCTAssertEqual(try attribute(.nativeDiffOldLine, in: text, at: "-    let") as? Int, 2)
        XCTAssertEqual(try attribute(.nativeDiffNewLine, in: text, at: "+    let message") as? Int, 2)
        XCTAssertEqual(try attribute(.nativeDiffNewLine, in: text, at: "+    let isVisible") as? Int, 3)
        XCTAssertEqual(try attribute(.nativeDiffOldLine, in: text, at: " }" ) as? Int, 3)
        XCTAssertEqual(try attribute(.nativeDiffNewLine, in: text, at: " }" ) as? Int, 4)
    }

    @MainActor
    func testPathOnlyHunksCRLFAndNoNewlineMarker() throws {
        let source = "file.txt\r\n@@ -10,2 +20,2 @@\r\n-old\r\n\\ No newline at end of file\r\n+new\r\n context\r\n"
        let (text, raw, _) = try code(source)
        XCTAssertEqual(raw, source)
        XCTAssertEqual(NativeDiff.summary(text), "+1  −1")
        XCTAssertEqual(try attribute(.nativeDiffKind, in: text, at: "\\ No newline") as? String, "metadata")
        XCTAssertEqual(try attribute(.nativeDiffOldLine, in: text, at: " context") as? Int, 11)
        XCTAssertEqual(try attribute(.nativeDiffNewLine, in: text, at: " context") as? Int, 21)
    }

    @MainActor
    func testFencedAndCommandOutputUseDiffRenderer() throws {
        XCTAssertEqual(try code("```diff\n\(patch)\n```", kind: "Agent").2, "Diff")
        XCTAssertEqual(try code(patch, kind: "Output").2, "Diff")
        XCTAssertEqual(try code("let value = 1", kind: "Code", language: "swift").2, "swift")
        let (text, _, _) = try code("a.txt\n@@ -1 +1 @@\n-old\n+par", language: "patch")
        XCTAssertEqual(NativeDiff.summary(text), "+1  −1", "Incomplete streamed content remains renderable")
    }

    @MainActor
    func testMultipleFilesAndHunks() throws {
        let source = patch + "\n@@ -20 +21 @@\n-last\n+next\n" + patch.replacingOccurrences(of: "Greeting.swift", with: "Second.swift")
        let (text, _, _) = try code(source)
        XCTAssertEqual(NativeDiff.summary(text), "+5  −3")
        XCTAssertEqual(try attribute(.nativeDiffOldLine, in: text, at: "-last") as? Int, 20)
        XCTAssertEqual(try attribute(.nativeDiffNewLine, in: text, at: "+next") as? Int, 21)
    }

    @MainActor
    func testNativeDiffPreviewAndStreamingSelection() throws {
        let (text, source, label) = try code(patch)
        let card = NativeCodeView(text: text, source: source, label: label)
        let height = NativeFeedLayout.height(.code(text, source: source, label: label), width: 760, images: [:])
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: height + 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: height + 40))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = root
        card.frame = NSRect(x: 20, y: 20, width: 760, height: height)
        root.addSubview(card)
        window.appearance = NSAppearance(named: .aqua)
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let view = try XCTUnwrap(descendants(card).compactMap { $0 as? NativeFeedTextView }.first)
        let selection = (patch as NSString).range(of: "Hello")
        view.setSelectedRange(selection)
        let next = patch + "\n@@ -9 +10 @@\n-before\n+after"
        let (updated, _, _) = try code(next)
        card.update(text: updated, source: next, reveal: nil)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(card.source, next)
        card.update(text: text, source: source, reveal: nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            root.display()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/thoughtstream-diff-\(name).png"))
        }
    }
}
