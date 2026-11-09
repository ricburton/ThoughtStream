import AppKit
import XCTest
@testable import ThoughtStream

final class AttachmentTests: XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testImportKeepsItsOwnCopyAndBuildsImageOnlyAndMixedRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Original image.png")
        try png().write(to: original)
        let image = try ChatAttachment.importImage(.file(original), directory: root.appendingPathComponent("stored"))
        try FileManager.default.removeItem(at: original)
        XCTAssertNotNil(image.thumbnail())
        XCTAssertEqual(image.name, "Original image.png")
        let imageOnly = try Session.messageInput("", attachments: [image])
        XCTAssertEqual(imageOnly.count, 1)
        XCTAssertEqual(imageOnly[0]["type"] as? String, "localImage")
        XCTAssertEqual(imageOnly[0]["path"] as? String, image.path)
        let mixed = try Session.messageInput("What is this?", attachments: [image])
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0]["text"] as? String, "What is this?")
        XCTAssertEqual(try Session.messageInput("Hello", attachments: []).count, 1)
        XCTAssertThrowsError(try Session.messageInput("", attachments: []))
        XCTAssertThrowsError(try Session.messageInput("", attachments: Array(repeating: image, count: 9)))
        try FileManager.default.removeItem(atPath: image.path)
        XCTAssertThrowsError(try Session.messageInput("", attachments: [image]))
    }

    @MainActor
    func testDropPasteboardAndDraftRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try png(), forType: .png)
        XCTAssertTrue(ChatAttachment.accepts(board))
        let image = try ChatAttachment.importImage(XCTUnwrap(ChatAttachment.sources(from: board).first), directory: root)
        let chat = UUID()
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        store.save(WorkspaceSnapshot(drafts: [chat: "Inspect this"], attachmentDrafts: [chat: [image]])); store.flush()
        XCTAssertEqual(store.load()?.attachmentDrafts?[chat], [image])
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{\"drafts\":{},\"streams\":{}}".utf8))
        XCTAssertNil(old.attachmentDrafts)
        XCTAssertThrowsError(try ChatAttachment.importImage(.data(Data("not an image".utf8)), directory: root))
    }

    @MainActor
    func testComposerKeepsAttachmentsSeparateWhileSwitchingChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try ChatAttachment.importImage(.data(png()), directory: root)
        let first = Session(project: root, storageRoot: root), second = Session(project: root, storageRoot: root)
        defer { first.stop(); second.stop() }
        let column = ChatColumn()
        column.display(first, draft: "First", attachments: [image])
        XCTAssertEqual(column.attachments, [image])
        column.display(second, draft: "Second")
        XCTAssertTrue(column.attachments.isEmpty)
        column.display(first, draft: "First", attachments: [image])
        XCTAssertEqual(column.attachments, [image])
        XCTAssertEqual(column.prompt.string, "First")
    }
}
