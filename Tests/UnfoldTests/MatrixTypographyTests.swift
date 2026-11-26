import AppKit
import XCTest
@testable import ThoughtStream

final class MatrixTypographyTests: XCTestCase {
    @MainActor
    func testExistingControlsRestoreTheirExactFontsAfterRepeatedThemeChanges() throws {
        let previous = InterfaceStyle.current
        defer { InterfaceStyle.current = previous }
        InterfaceStyle.current = .standard
        let root = NSView()
        let labels = [NSTextField(labelWithString: "Projects"), NSTextField(labelWithString: "ThoughtStream"), NSTextField(labelWithString: "12")]
        let fonts = [Typography.section, Typography.interface, Typography.counter]
        for (label, font) in zip(labels, fonts) { label.font = font; root.addSubview(label) }
        for _ in 0..<3 {
            InterfaceStyle.current = .matrix
            InterfaceTypography.apply(to: root)
            InterfaceTypography.apply(to: root)
            for (label, font) in zip(labels, fonts) {
                XCTAssertTrue(try XCTUnwrap(label.font).isFixedPitch)
                XCTAssertEqual(label.font?.pointSize, font.pointSize)
                XCTAssertEqual(label.textColor, FeedPalette.text)
            }
            InterfaceStyle.current = .breathe
            InterfaceTypography.apply(to: root)
            for (label, font) in zip(labels, fonts) { XCTAssertEqual(label.font, font) }
        }
    }

    @MainActor
    func testModelMenuUpdatesNewItemsAndRestoresNativeTitles() throws {
        let previous = InterfaceStyle.current
        defer { InterfaceStyle.current = previous }
        let picker = ThemedPopUpButton()
        picker.addItems(withTitles: ["GPT model", "Claude model"])
        InterfaceStyle.current = .matrix
        picker.updateTypography()
        picker.addItem(withTitle: "Newly discovered local model")
        picker.lastItem?.isEnabled = false
        picker.updateTypography()
        XCTAssertTrue(try XCTUnwrap(picker.font).isFixedPitch)
        for item in picker.itemArray {
            let title = try XCTUnwrap(item.attributedTitle)
            XCTAssertTrue(try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).isFixedPitch)
            XCTAssertEqual(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, item.isEnabled ? FeedPalette.text : FeedPalette.muted)
        }
        InterfaceStyle.current = .standard
        picker.updateTypography()
        XCTAssertEqual(picker.font, Typography.interface)
        XCTAssertTrue(picker.itemArray.allSatisfy { $0.attributedTitle == nil })
    }

    @MainActor
    func testWorkspaceMatrixPreview() async throws {
        let previous = InterfaceStyle.current
        defer { InterfaceStyle.current = previous }
        InterfaceStyle.current = .matrix
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(project: directory.appendingPathComponent("ThoughtStream"), title: "Polish the Matrix theme", storageRoot: directory)
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: WorkspaceStateStore(url: directory.appendingPathComponent("workspace.json")))
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: directory) }
        window.setContentSize(NSSize(width: 1120, height: 760))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let labels = descendants(root).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
        for label in labels { XCTAssertTrue(label.font?.isFixedPitch == true, "Unstyled label: \(label.stringValue)") }
        for picker in descendants(root).compactMap({ $0 as? ThemedPopUpButton }) { picker.updateTypography() }
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        if let path = ProcessInfo.processInfo.environment["THOUGHTSTREAM_MATRIX_PREVIEW"] {
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
