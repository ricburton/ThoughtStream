import AppKit
import XCTest
@testable import ThoughtStream

final class ChatTitleReadabilityTests: XCTestCase {
    @MainActor
    func testSingleTitleShowsItsModelInEveryStyle() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(AgentProvider, String, String, ModelBrand)] = [
            (.codex, "Astra chat", "gpt-6-astra", .openAI),
            (.claude, "Claude chat", "claude-fable-5-2", .anthropic),
            (.gemini, "Gemini chat", "gemini-4-carbon", .gemini),
            (.local, "Local chat", "ollama|llama3.2", .local)
        ]
        for style in [InterfaceStyle.standard, .breathe] {
            InterfaceStyle.current = style
            for (provider, title, model, brand) in fixtures {
                let chat = Session(project: root, title: title, storageRoot: root, provider: provider)
                chat.setInferenceSettings(InferenceSettings(model: model, effort: "high", tier: "default"))
                let column = ChatColumn()
                let window = NSWindow(contentViewController: column)
                window.isReleasedWhenClosed = false
                defer { window.close(); chat.stop() }
                window.setContentSize(NSSize(width: 380, height: 600))
                column.display(chat)
                column.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(column.chatTitle.modelBrand, brand)
                XCTAssertEqual(column.chatTitle.title, title)
                XCTAssertNil(column.chatTitle.enclosingScrollView)
                XCTAssertGreaterThan(column.chatTitle.bounds.width, 300)
                XCTAssertTrue(column.chatTitle.toolTip?.contains(chat.inferenceSettings.displayName) == true)
                XCTAssertTrue(column.chatTitle.accessibilityLabel()?.contains(brand.name) == true)
                XCTAssertTrue(try XCTUnwrap(brand.image).isValid)
                if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_HEADER_PREVIEW"] {
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        window.appearance = NSAppearance(named: appearance)
                        column.view.layoutSubtreeIfNeeded()
                        let rect = NSRect(x: 0, y: column.view.bounds.maxY - 100, width: 380, height: 100)
                        let bitmap = try XCTUnwrap(column.view.bitmapImageRepForCachingDisplay(in: rect))
                        column.view.cacheDisplay(in: rect, to: bitmap)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("brand-\(brand.rawValue)-\(style.rawValue)-\(name).png"))
                    }
                }
            }
        }
    }
}
