import AppKit
import XCTest
@testable import ThoughtStream

final class TabReadabilityTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testBrandIconsFollowEachConversationAndRenderAtRetinaScale() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for brand in ModelBrand.allCases {
            let image = try XCTUnwrap(brand.image, "Missing bundled vector for \(brand.name)")
            XCTAssertTrue(image.isValid)
        }
        let fixtures: [(AgentProvider, String, String, ModelBrand)] = [
            (.codex, "Astra chat", "gpt-6-astra", .openAI),
            (.claude, "Claude chat", "claude-fable-5-2", .anthropic),
            (.gemini, "Gemini chat", "gemini-4-carbon", .gemini),
            (.local, "Local chat", "ollama|llama3.2", .local)
        ]
        let chats = fixtures.map { provider, title, model, _ in
            let chat = Session(project: root, title: title, storageRoot: root, provider: provider)
            chat.setInferenceSettings(InferenceSettings(model: model, effort: "high", tier: "default"))
            return chat
        }
        chats[1].turn = "fixture-working"
        defer { chats.forEach { $0.stop() } }
        for style in [InterfaceStyle.standard, .breathe] {
            InterfaceStyle.current = style
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let column = ChatColumn(tabsOnly: true)
                let window = NSWindow(contentViewController: column)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: 1100, height: 400))
                column.display(chats[0])
                column.updateTabs(Array(chats.enumerated()), isSplit: false)
                column.view.layoutSubtreeIfNeeded()
                let buttons = descendants(column.view).compactMap { $0 as? ChatTabButton }
                XCTAssertEqual(buttons.map(\.modelBrand), fixtures.map { $0.3 })
                for (button, chat) in zip(buttons, chats) {
                    XCTAssertTrue(button.toolTip?.contains(chat.inferenceSettings.displayName) == true)
                    XCTAssertTrue(button.accessibilityLabel()?.contains(button.modelBrand.name) == true)
                }
                let strip = try XCTUnwrap(buttons.first?.enclosingScrollView)
                if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_TAB_PREVIEW"] {
                    let rect = column.view.convert(strip.bounds, from: strip)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2), bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0))
                    bitmap.size = rect.size
                    column.view.cacheDisplay(in: rect, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("brands-\(style.rawValue)-\(appearance.rawValue).png"))
                }
                chats[0].setInferenceSettings(InferenceSettings(model: "gpt-6.1-sol", effort: "high", tier: "default"))
                column.updateTabs(Array(chats.enumerated()), isSplit: false)
                let updated = try XCTUnwrap(descendants(column.view).compactMap { $0 as? ChatTabButton }.first)
                XCTAssertEqual(updated.modelBrand, .openAI)
                XCTAssertTrue(updated.toolTip?.contains("GPT-6.1 Sol") == true)
                chats[0].setInferenceSettings(InferenceSettings(model: "gpt-6-astra", effort: "high", tier: "default"))
            }
        }
    }

    @MainActor
    func testCrowdedTabsKeepThreeWordsWithRunningAndCloseControls() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = ["Investigate intermittent rendering failures", "Keep all tabs readable", "New chat"]
        for style in [InterfaceStyle.standard, .breathe] {
            InterfaceStyle.current = style
            let chats = titles.map { Session(project: root, title: $0, storageRoot: root) }
            chats[0].turn = "running"
            defer { chats.forEach { $0.stop() } }
            let column = ChatColumn(tabsOnly: true)
            let window = NSWindow(contentViewController: column)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.setContentSize(NSSize(width: 440, height: 600))
            column.display(chats[0])
            column.updateTabs(Array(chats.enumerated()), isSplit: false)
            column.view.layoutSubtreeIfNeeded()
            let buttons = descendants(column.view).compactMap { $0 as? ChatTabButton }
            XCTAssertEqual(buttons.count, titles.count)
            for button in buttons {
                let prefix = button.title.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
                let label = prefix + (button.title == prefix ? "" : "…")
                let expected = (label as NSString).size(withAttributes: [.font: Typography.interfaceEmphasis]).width
                let chrome = ChatTabLayout.reservedWidth(breathe: style == .breathe, running: button.isRunning)
                XCTAssertGreaterThanOrEqual(button.bounds.width - chrome, expected, button.title)
            }
            let strip = try XCTUnwrap(buttons.first?.enclosingScrollView)
            XCTAssertGreaterThan(try XCTUnwrap(strip.documentView).frame.width, strip.contentSize.width)
            if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_TAB_PREVIEW"] {
                let rect = column.view.convert(strip.bounds, from: strip)
                let bitmap = try XCTUnwrap(column.view.bitmapImageRepForCachingDisplay(in: rect))
                column.view.cacheDisplay(in: rect, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("tabs-\(style.rawValue).png"))
            }
        }
    }

    @MainActor
    func testOverflowIndicatorsFollowScrollingResizingAndRemoval() throws {
        let strip = TabScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 38))
        strip.hasHorizontalScroller = false; strip.hasVerticalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 38))
        strip.documentView = document
        strip.tile()
        let buttons = strip.subviews.compactMap { $0 as? NSButton }
        let left = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Show more tabs to the left" })
        let right = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Show more tabs to the right" })
        XCTAssertTrue(left.isHidden); XCTAssertFalse(right.isHidden)
        XCTAssertLessThanOrEqual(left.frame.maxX, strip.contentView.frame.minX)
        XCTAssertGreaterThanOrEqual(right.frame.minX, strip.contentView.frame.maxX)
        let viewport = strip.contentSize.width
        strip.tile()
        XCTAssertEqual(strip.contentSize.width, viewport, "Repeated layout must not accumulate gutters")
        right.performClick(nil)
        XCTAssertGreaterThan(strip.contentView.bounds.minX, 0)
        XCTAssertFalse(left.isHidden); XCTAssertFalse(right.isHidden)
        strip.contentView.scroll(to: NSPoint(x: 900 - viewport, y: 0))
        strip.reflectScrolledClipView(strip.contentView)
        XCTAssertFalse(left.isHidden); XCTAssertTrue(right.isHidden)
        left.performClick(nil)
        XCTAssertFalse(right.isHidden)
        strip.setFrameSize(NSSize(width: 1000, height: 38)); strip.tile()
        XCTAssertTrue(left.isHidden); XCTAssertTrue(right.isHidden)
        strip.setFrameSize(NSSize(width: 320, height: 38)); strip.tile()
        XCTAssertFalse(right.isHidden)
        document.setFrameSize(NSSize(width: 100, height: 38))
        strip.updateOverflowIndicators()
        XCTAssertTrue(left.isHidden); XCTAssertTrue(right.isHidden)
    }
}
