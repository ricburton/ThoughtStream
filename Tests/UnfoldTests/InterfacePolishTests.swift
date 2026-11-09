import AppKit
import XCTest
@testable import ThoughtStream

final class InterfacePolishTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testFindBarFitsNarrowPaneAndRestoresVisibility() async throws {
        let column = ChatColumn()
        let window = NSWindow(contentViewController: column)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for width: CGFloat in [260, 320, 420, 680] {
            window.setContentSize(NSSize(width: width, height: 700))
            column.stream.find()
            column.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(column.view.bounds.width, width, accuracy: 1, "Find must not widen the pane")
            let bar = try XCTUnwrap(descendants(column.view).compactMap { $0 as? ChatControlBar }.first)
            let search = try XCTUnwrap(descendants(bar).compactMap { $0 as? NSSearchField }.first)
            XCTAssertGreaterThan(search.bounds.width, width - 120)
            for control in descendants(bar).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                let rect = control.convert(control.bounds, to: bar)
                XCTAssertTrue(bar.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Clipped control: \(control)")
            }
            XCTAssertTrue(column.stream.viewState.searchVisible == true)
            let state = column.stream.viewState
            XCTAssertTrue(column.stream.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            column.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(search.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(column.stream.viewState.searchVisible == true)
            column.stream.restoreViewState(state)
            try await Task.sleep(nanoseconds: 10_000_000)
            column.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        }
    }

    @MainActor
    func testOverviewLabelsFitMinimumNavigatorWidth() throws {
        let entries = [
            FeedHighlight(record: 0, kind: "Reasoning", title: "Reasoning", summary: String(repeating: "Review the interface carefully. ", count: 8)),
            FeedHighlight(record: 1, kind: "Changes", title: "AReallyLongWorkspaceViewController.swift", summary: "12 added · 2 removed\nA longer description of the change.", freshCode: true),
            FeedHighlight(record: 2, kind: "Reply", title: "Final answer", summary: String(repeating: "Finished the review. ", count: 8)),
            FeedHighlight(record: 3, kind: "Command", title: "Run checks", summary: "Inspect the workspace", command: CommandActivity(state: .succeeded, startedAt: Date(), durationMs: 3_725_000, exitCode: 0))
        ]
        for width: CGFloat in [116, 156, 210] {
            for entry in entries {
                let cell = FeedOverviewCell(entry: entry)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: entry.overviewHeight), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = cell
                defer { window.close() }
                cell.layoutSubtreeIfNeeded()
                for label in descendants(cell).compactMap({ $0 as? NSTextField }).filter({ !$0.stringValue.isEmpty }) {
                    let rect = label.convert(label.bounds, to: cell)
                    XCTAssertTrue(cell.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Clipped overview label: \(label.stringValue), \(rect)")
                }
                XCTAssertNotNil(cell.toolTip, "Truncated details remain available")
            }
        }
    }

    @MainActor
    func testSettingsRowsFitEveryPageAtMinimumWindowSize() throws {
        let settings = SettingsWindowController(target: self, actions: [:],
            chatGPTButton: NSButton(title: "Connect ChatGPT", target: nil, action: nil),
            claudeButton: NSButton(title: "Connect Claude", target: nil, action: nil),
            claudeStatus: NSTextField(wrappingLabelWithString: "Use your Claude Code sign-in on this Mac."))
        let window = try XCTUnwrap(settings.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 760, height: 480))
        let root = try XCTUnwrap(window.contentView)
        let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
        for page in 0..<navigation.numberOfRows {
            navigation.selectRowIndexes(IndexSet(integer: page), byExtendingSelection: false)
            settings.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.width, 760, accuracy: 1, "Switching settings must not shrink the content view")
            let buttons = descendants(root).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertFalse(buttons.isEmpty)
            for button in buttons {
                XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), "Clipped settings action: \(button.title)")
            }
        }
    }

    @MainActor
    func testMarkdownHeadingsKeepHierarchyWithoutBlankParagraphs() throws {
        let markdown = "# Heading one\n\nParagraph one.\n\n## Heading two\n\nParagraph two.\n\n### Heading three\nBody."
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let text = try XCTUnwrap(renderer.render(StreamRecord(kind: "Agent", text: markdown)).compactMap { block -> NSAttributedString? in
            if case .text(let text) = block { return text }; return nil
        }.first)
        XCTAssertFalse(text.string.contains("Heading one\n\n"))
        XCTAssertTrue(text.string.contains("Paragraph one.\n\nHeading two"), "Body paragraph breaks remain intact")
        var previousSize: CGFloat = .greatestFiniteMagnitude
        for heading in ["Heading one", "Heading two", "Heading three"] {
            let range = (text.string as NSString).range(of: heading)
            let font = try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertLessThan(font.pointSize, previousSize)
            XCTAssertGreaterThan(paragraph.paragraphSpacing, 0)
            XCTAssertLessThan(paragraph.minimumLineHeight / font.pointSize, 1.4)
            previousSize = font.pointSize
        }
    }

    @MainActor
    func testReadingAndBadgeColorsRetainContrastAcrossAppearances() throws {
        let original = InterfaceStyle.current
        defer { InterfaceStyle.current = original }
        func rgb(_ color: NSColor) -> [CGFloat] {
            let color = color.usingColorSpace(.sRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        func blend(_ foreground: [CGFloat], over background: [CGFloat], alpha: CGFloat) -> [CGFloat] {
            zip(foreground, background).map { $0 * alpha + $1 * (1 - alpha) }
        }
        func luminance(_ color: [CGFloat]) -> CGFloat {
            zip(color, [CGFloat(0.2126), 0.7152, 0.0722]).reduce(0) { result, pair in
                let value = pair.0
                return result + pair.1 * (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
            }
        }
        func contrast(_ foreground: [CGFloat], _ background: [CGFloat]) -> CGFloat {
            let a = luminance(foreground), b = luminance(background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for style in InterfaceStyle.allCases {
            InterfaceStyle.current = style
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    let canvas = rgb(FeedPalette.canvas)
                    for background in [FeedPalette.canvas, FeedPalette.input, FeedPalette.incomingMessage] {
                        for foreground in [FeedPalette.text, FeedPalette.muted] {
                            XCTAssertGreaterThanOrEqual(contrast(rgb(foreground), rgb(background)), 4.5)
                        }
                    }
                    XCTAssertGreaterThanOrEqual(contrast(rgb(FeedPalette.muted), rgb(FeedPalette.selection)), 4.5)
                    XCTAssertGreaterThanOrEqual(contrast([1, 1, 1], rgb(FeedPalette.outgoingMessage)), 4.5)
                    for (ink, cardTint) in [(FeedPalette.green, true), (FeedPalette.purple, true), (FeedPalette.muted, false), (FeedPalette.blue, false), (FeedPalette.red, false)] {
                        let foreground = rgb(ink)
                        let card = cardTint ? blend(foreground, over: canvas, alpha: 0.07) : canvas
                        let badge = blend(foreground, over: card, alpha: 0.09)
                        XCTAssertGreaterThanOrEqual(contrast(foreground, badge), 4.5, "\(style), \(appearance): badge contrast")
                    }
                }
            }
        }
    }
}
