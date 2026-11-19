import AppKit
import XCTest
@testable import ThoughtStream

/// Tester feedback, 3 Nov 2026: prompts vs. command cards, long code, visible
/// progress, and which branch or worktree a chat is on.
final class FeedbackPolishTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testPromptsUseBlueTintDistinctFromCommandCards() throws {
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "You", text: "role: you're a senior design engineer"))
        let row = NativeFeedRow(blocks: blocks, width: 600, images: [:], openHTML: { _ in }, openImage: { _ in })
        let prompt = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeProseView }.first)
        XCTAssertEqual(prompt.fill, FeedPalette.userMessage)
        XCTAssertNotEqual(prompt.fill, FeedPalette.surface, "Prompts must not share the gray command-card fill")
    }

    @MainActor
    func testLongCodeCollapsesAndExpandsInPlace() throws {
        let source = (1...80).map { "echo line \($0)" }.joined(separator: "\n")
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Output", text: source))
        let row = NativeFeedRow(blocks: blocks, width: 700, images: [:], openHTML: { _ in }, openImage: { _ in })
        let card = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeCodeView }.first)
        guard case .code(let text, let blockSource, let label) = try XCTUnwrap(blocks.last) else { return XCTFail("Expected code") }
        defer { CodeCollapse.setExpanded(false, key: CodeCollapse.key(source: blockSource, label: label)) }
        XCTAssertTrue(card.isCollapsed)
        let collapsed = row.contentHeight
        let full = NativeFeedLayout.textHeight(text, width: 700 - 28 - 24)
        XCTAssertLessThan(collapsed, full, "A collapsed card shows only its first lines")

        var reported: CGFloat?
        row.onHeightChange = { reported = $0.contentHeight }
        card.setExpanded(true)
        XCTAssertFalse(card.isCollapsed)
        XCTAssertGreaterThan(try XCTUnwrap(reported), full, "Expanding re-measures the row to the full block")

        // Expansion survives the row being recycled while scrolling.
        let recycled = NativeFeedRow(blocks: blocks, width: 700, images: [:], openHTML: { _ in }, openImage: { _ in })
        XCTAssertEqual(recycled.contentHeight, row.contentHeight, accuracy: 0.5)

        card.setExpanded(false)
        XCTAssertEqual(row.contentHeight, collapsed, accuracy: 0.5)
    }

    @MainActor
    func testShortCodeHasNoCollapseControl() throws {
        var renderer = NativeFeedRenderer(size: 16, analyses: [:])
        let blocks = renderer.render(StreamRecord(kind: "Command", text: "$ git status", language: "bash"))
        let row = NativeFeedRow(blocks: blocks, width: 700, images: [:], openHTML: { _ in }, openImage: { _ in })
        let card = try XCTUnwrap(descendants(row).compactMap { $0 as? NativeCodeView }.first)
        XCTAssertEqual(card.collapse, .short)
        XCTAssertFalse(descendants(card).contains { $0 is FeedPillButton && !$0.isHidden })
    }

    @MainActor
    func testConversationShowsWorkingIndicatorUntilTurnEnds() {
        let panel = ConversationView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        var active = true
        panel.setWorking(true) { active ? "Running a command" : nil }
        XCTAssertFalse(panel.working.isHidden)
        XCTAssertTrue(panel.working.text.hasPrefix("Running a command"))
        active = false
        panel.working.refresh()
        XCTAssertTrue(panel.working.isHidden, "The indicator hides itself once the turn ends")
    }

    func testActivityNamesLatestWork() {
        let running = StreamRecord(kind: "Command", text: "$ pnpm check", command: CommandActivity(state: .running, startedAt: Date()))
        XCTAssertEqual(ConversationWorkingIndicator.activity(after: [running]), "Running a command")
        XCTAssertEqual(ConversationWorkingIndicator.activity(after: [StreamRecord(kind: "File change", text: "")]), "Editing files")
        XCTAssertEqual(ConversationWorkingIndicator.activity(after: [StreamRecord(kind: "You", text: "hi")]), "Thinking")
        XCTAssertEqual(ConversationWorkingIndicator.activity(after: []), "Working")
    }

    func testRepositoryLocationReadsBranchAndLinkedWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        let nested = root.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("worktrees/arrival-orb"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let main = try XCTUnwrap(RepositoryLocation.read(nested))
        XCTAssertEqual(main.branch, "main"); XCTAssertNil(main.worktree)
        XCTAssertEqual(main.root.standardizedFileURL.path, root.standardizedFileURL.path)

        let tree = root.appendingPathComponent(".claude/worktrees/arrival-orb")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "gitdir: \(git.path)/worktrees/arrival-orb\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/arrival-orb\n".write(to: git.appendingPathComponent("worktrees/arrival-orb/HEAD"), atomically: true, encoding: .utf8)
        let linked = try XCTUnwrap(RepositoryLocation.read(tree))
        XCTAssertEqual(linked.branch, "feature/arrival-orb")
        XCTAssertEqual(linked.worktree, "arrival-orb")
        XCTAssertEqual(linked.summary, "feature/arrival-orb · worktree arrival-orb")

        try "4a51080c0ffee\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepositoryLocation.read(root)?.summary, "detached at 4a51080")
    }

    /// The tester's chat stayed in the main checkout while the agent committed
    /// to a sibling worktree with `git -C`; the label must name that worktree.
    func testRepositoryLabelFollowsTheWorktreeTheAgentWorksIn() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("portfolio"), git = root.appendingPathComponent(".git")
        func addWorktree(_ tree: URL, name: String, branch: String) throws {
            let entry = git.appendingPathComponent("worktrees/\(name)")
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try "gitdir: \(entry.path)\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            try "\(tree.path)/.git\n".write(to: entry.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
            try "ref: refs/heads/\(branch)\n".write(to: entry.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepositoryLocation.active(project: root, activity: ["\n$ git status"])?.branch, "main")

        let sibling = base.appendingPathComponent("portfolio-arrival-orb")
        let nested = root.appendingPathComponent(".claude/worktrees/yosemite")
        try addWorktree(sibling, name: "portfolio-arrival-orb", branch: "spike/arrival-orb")
        try addWorktree(nested, name: "yosemite", branch: "spike/yosemite")

        func active(_ records: [StreamRecord]) -> RepositoryLocation? {
            RepositoryLocation.active(project: root, activity: RepositoryLocation.activity(in: records))
        }
        let inSibling = StreamRecord(kind: "Command", text: "\n$ git -C \(sibling.path) commit -m 'fix(home): let drags pass through'")
        XCTAssertEqual(active([inSibling])?.summary, "spike/arrival-orb · worktree portfolio-arrival-orb")
        // A worktree inside the main checkout is not mistaken for the main checkout.
        let edit = StreamRecord(kind: "Tool", text: "{\"tool\":\"Edit\",\"arguments\":{\"file_path\":\"\(nested.path)/src/app/page.tsx\"}}")
        XCTAssertEqual(active([inSibling, edit])?.worktree, "yosemite")
        // Codex commands lead with their working directory.
        let back = StreamRecord(kind: "Command", text: "\(root.path)\n$ pnpm check")
        XCTAssertEqual(active([inSibling, edit, back])?.summary, "main")
        // Listings name every checkout; a command with no path keeps the last known one.
        let listing = StreamRecord(kind: "Output", text: "\(root.path) 4a51080 [main]\n\(sibling.path) 1b2c3d4 [spike/arrival-orb]")
        XCTAssertEqual(active([edit, StreamRecord(kind: "Command", text: "\n$ pnpm check"), listing])?.worktree, "yosemite")
        // Another folder that merely starts with the same name is a different place.
        let lookalike = StreamRecord(kind: "Command", text: "\n$ ls \(sibling.path)-backup")
        XCTAssertEqual(active([lookalike])?.summary, "main")
    }
}
