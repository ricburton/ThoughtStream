import AppKit
import XCTest
@testable import ThoughtStream

final class OverviewHierarchyTests: XCTestCase {
    @MainActor
    func testRepeatedOverviewLabelsAreShownOnceWithoutRemovingDistinctContent() throws {
        for kind in ["Reasoning", "Output", "Session", "Image", "Error", "You"] {
            var entry = FeedHighlight(record: 0, kind: kind, title: kind, summary: "Specific content stays visible.")
            XCTAssertFalse(entry.showsOverviewBadge)
            XCTAssertEqual(entry.overviewAccessibilityLabel, kind)
            XCTAssertEqual(entry.overviewDetail, entry.summary)
            let cell = FeedOverviewCell(entry: entry)
            XCTAssertEqual(cell.accessibilityLabel(), kind)
            XCTAssertEqual(cell.toolTip, "\(kind)\nSpecific content stays visible.")
            XCTAssertTrue(try XCTUnwrap(cell.subviews.first { $0 is FeedTypeBadge }).isHidden)
            entry.title = "\(kind) about this task"
            XCTAssertTrue(entry.showsOverviewBadge, "Shared words are not duplicate labels")
            XCTAssertFalse(cell.update(entry), "Adding a distinct badge requires updated layout")
            entry.summary = entry.title
            XCTAssertEqual(entry.overviewDetail, "")
        }
        let normalized = FeedHighlight(record: 0, kind: "Reasoning", title: " reasoning \n", summary: "REASONING")
        XCTAssertFalse(normalized.showsOverviewBadge)
        XCTAssertTrue(normalized.overviewDetail.isEmpty)
        let command = FeedHighlight(record: 1, kind: "Command", title: "Command", summary: "echo hello", command: CommandActivity(state: .running, startedAt: Date()), commandText: "echo hello")
        XCTAssertTrue(command.showsOverviewMetadata, "Elapsed time must remain visible")
        XCTAssertEqual(command.overviewDetail, "echo hello")
        var caseSensitive = command
        caseSensitive.summary = "echo HELLO"
        XCTAssertEqual(caseSensitive.overviewDetail, "echo HELLO\necho hello")
    }
    func testAuthoredArtifactsStandOutFromMatchingReadback() throws {
        let code = "```swift\nstruct Greeting {}\n```"
        let authored = FeedHighlightIndex.entries(for: StreamRecord(kind: "Agent", text: code), at: 0)
        XCTAssertTrue(authored.contains { $0.prominence == .created && $0.freshCode })
        for kind in ["Tool", "Output", "You", "Reasoning summary"] {
            let entries = FeedHighlightIndex.entries(for: StreamRecord(kind: kind, text: code), at: 1)
            XCTAssertFalse(entries.contains { $0.prominence == .created || $0.freshCode }, kind)
        }
        for (source, language) in [("{\"count\":3}", "json"), ("<main>Preview</main>", "html")] {
            let created = try XCTUnwrap(FeedHighlightIndex.entries(for: StreamRecord(kind: "Code", text: source, language: language), at: 2).first)
            let readback = try XCTUnwrap(FeedHighlightIndex.entries(for: StreamRecord(kind: "Output", text: source, language: language), at: 3).first)
            XCTAssertEqual(created.prominence, .created)
            XCTAssertEqual(readback.prominence, .activity)
            XCTAssertGreaterThan(created.overviewHeight, readback.overviewHeight)
        }
    }

    func testRemovalsAndCommandFailuresStayProminent() throws {
        let removal = try XCTUnwrap(FeedHighlightIndex.entries(for: StreamRecord(kind: "File change", text: "--- a/Old.swift\n+++ /dev/null\n-struct Old {}"), at: 0).first)
        XCTAssertFalse(removal.freshCode)
        XCTAssertEqual(removal.prominence, .created)
        XCTAssertEqual(removal.overviewBadge, "Project changes")
        let error = FeedHighlight(record: 1, kind: "Error", title: "Failed", summary: "Could not save")
        XCTAssertEqual(error.prominence, .error)
        let command = FeedHighlight(record: 2, kind: "Command", title: "Run tests", summary: "Failed", command: CommandActivity(state: .failed, startedAt: Date(), exitCode: 1))
        XCTAssertEqual(command.prominence, .error)
        XCTAssertGreaterThan(error.overviewHeight, FeedHighlight(record: 2, kind: "Tool", title: "Read", summary: "File").overviewHeight)
    }

    @MainActor
    func testCompactActivityRemainsNavigableAndSelectionSurvivesUpdates() throws {
        let entries = fixture()
        let navigator = FeedHighlightsView(frame: NSRect(x: 0, y: 0, width: 210, height: 600))
        let window = NSWindow(contentRect: navigator.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = navigator
        defer { window.close() }
        navigator.setFollowingLatest(false)
        navigator.update(entries)
        navigator.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(navigator.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, entries.count)
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, table.rect(ofRow: 0).height)
        var jumped: String?
        navigator.onJump = { jumped = $0.id }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        _ = table.sendAction(table.action, to: table.target)
        XCTAssertEqual(jumped, entries[0].id)
        navigator.update(entries + [FeedHighlight(record: 4, kind: "Tool", title: "Read files", summary: "Next file")])
        XCTAssertEqual(table.selectedRow, 0)
        navigator.markFocused(entries[1])
        XCTAssertEqual(table.selectedRow, 1)
        navigator.reset()
        XCTAssertEqual(table.numberOfRows, 0)
    }

    @MainActor
    func testScrollMaskDoesNotCutSelectionOutlineCorners() throws {
        let navigator = FeedHighlightsView(frame: NSRect(x: 0, y: 0, width: 210, height: 600))
        let clip = try XCTUnwrap(navigator.subviews.compactMap { $0 as? NSScrollView }.first?.contentView)
        XCTAssertEqual(clip.layer?.masksToBounds, true)
        // The first and last rows sit in the mask's corners. A mask rounder
        // than the row's own corner shaves the selection outline there.
        XCTAssertEqual(clip.layer?.cornerRadius, FeedOverviewRow.cornerRadius)
    }

    @MainActor
    func testHierarchyRendersAtNarrowWidthInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let height = fixture().reduce(CGFloat(0)) { $0 + $1.overviewHeight + 4 }
            let root = OverviewPreviewBackground(frame: NSRect(x: 0, y: 0, width: 210, height: height))
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.appearance = NSAppearance(named: appearance)
            defer { window.close() }
            var y: CGFloat = 0
            for entry in fixture().reversed() {
                let cell = FeedOverviewCell(entry: entry)
                cell.frame = NSRect(x: 0, y: y, width: 210, height: entry.overviewHeight)
                root.addSubview(cell)
                y += entry.overviewHeight + 4
            }
            root.layoutSubtreeIfNeeded()
            for cell in root.subviews {
                for label in cell.subviews.compactMap({ $0 as? NSTextField }).filter({ !$0.stringValue.isEmpty }) {
                    XCTAssertTrue(cell.bounds.insetBy(dx: -1, dy: -1).contains(label.frame), "Clipped label: \(label.stringValue)")
                }
            }
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/thoughtstream-overview-\(appearance.rawValue).png"))
        }
    }

    private func fixture() -> [FeedHighlight] {
        [FeedHighlight(record: 0, kind: "Command", title: "Read files", summary: "Inspect existing source", commandText: "cat Sources/Greeting.swift"),
         FeedHighlight(record: 1, kind: "Changes", title: "GreetingView.swift", summary: "12 added · 2 removed\nAdded: struct GreetingView", freshCode: true),
         FeedHighlight(record: 2, kind: "HTML", title: "Greeting preview", summary: "Rendered page and source", createdOutput: true),
         FeedHighlight(record: 3, kind: "Reply", title: "Final answer", summary: "Created the view and verified the focused checks."),
         FeedHighlight(record: 4, kind: "Reasoning", title: "Reasoning", summary: "Check the smallest change against the existing tests."),
         FeedHighlight(record: 5, kind: "Output", title: "Output", summary: "Build succeeded.")]
    }
}

@MainActor
private final class OverviewPreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
