import AppKit
import XCTest
@testable import ThoughtStream

final class WorkspaceStateTests: XCTestCase {
    @MainActor
    private func columns(_ workspace: WorkspaceWindow) -> [ChatColumn] {
        func descend(_ controller: NSViewController) -> [ChatColumn] {
            if let column = controller as? ChatColumn { return [column] }
            return controller.children.flatMap(descend)
        }
        return workspace.window?.contentViewController.map(descend) ?? []
    }

    @MainActor
    func testNewSplitStartsWithEqualPaneWidths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let session = Session(project: root, storageRoot: root)
        let workspace = WorkspaceWindow(restoredSessions: [session], stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        var createdSessions: [UUID] = []
        defer {
            workspace.stopAll(); window.close()
            for id in createdSessions { try? FileManager.default.removeItem(at: Session.base.appendingPathComponent(id.uuidString)) }
            try? FileManager.default.removeItem(at: root)
        }
        for size in [NSSize(width: 1120, height: 800), NSSize(width: 860, height: 600)] {
            window.setContentSize(size)
            workspace.splitStream(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let panes = columns(workspace)
            XCTAssertEqual(panes.count, 2)
            let second = try XCTUnwrap(panes.last)
            createdSessions.append(try XCTUnwrap(second.session?.id))
            XCTAssertGreaterThan(panes[0].view.frame.width, 0)
            XCTAssertEqual(panes[0].view.frame.width, second.view.frame.width, accuracy: 1)
            // Splitting either end must rebalance the whole row, including its dividers.
            workspace.splitPane(size.width > 1000 ? second : panes[0], side: .right)
            window.contentView?.layoutSubtreeIfNeeded()
            let thirds = columns(workspace)
            if size.width == 860 {
                // Two panes fit here, but a third would violate their minimum width.
                XCTAssertEqual(thirds.count, 2)
                workspace.singlePane(nil)
                continue
            }
            XCTAssertEqual(thirds.count, 3)
            guard thirds.count == 3 else { continue }
            createdSessions.append(contentsOf: thirds.compactMap { $0.session?.id }.filter { $0 != session.id && !createdSessions.contains($0) })
            XCTAssertEqual(thirds[0].view.frame.width, thirds[1].view.frame.width, accuracy: 1)
            XCTAssertEqual(thirds[1].view.frame.width, thirds[2].view.frame.width, accuracy: 1)
            workspace.singlePane(nil)
        }
    }

    @MainActor
    func testClosingPaneRebalancesRemainingPanesAndPersistsWidths() throws {
        for vertical in [true, false] {
            for closedIndex in 0..<4 {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
                let sessions = (0..<4).map { Session(project: root, title: "Pane \($0)", storageRoot: root) }
                let ids = sessions.map { _ in UUID() }
                // Deliberately unequal persisted sizes must become equal on close.
                let layout = PaneLayout.split(vertical: vertical, fraction: 0.3,
                    first: .pane(ids[0]), second: .split(vertical: vertical, fraction: 0.6,
                        first: .split(vertical: vertical, fraction: 0.4,
                            first: .pane(ids[1]), second: .pane(ids[2])), second: .pane(ids[3])))
                store.save(WorkspaceSnapshot(windowFrame: NSStringFromRect(NSRect(x: 0, y: 0, width: 1400, height: 1100)),
                    selectedProject: root.path, projects: [root.path: ProjectViewState(layout: layout,
                        panes: zip(ids, sessions).map { PaneViewState(id: $0.0, session: $0.1.id, tabs: [$0.1.id], tabOffset: 0) })]))
                store.flush()
                let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
                defer { workspace.stopAll(); workspace.window?.close() }
                let original = columns(workspace)
                original.forEach { $0.prompt.string = "Draft \($0.columnID)" }
                workspace.closePane(original[closedIndex])
                func checkEqual(_ panes: [ChatColumn], count: Int) {
                    XCTAssertEqual(panes.count, count)
                    let sizes = panes.map { vertical ? $0.view.frame.width : $0.view.frame.height }
                    XCTAssertGreaterThan(sizes.min() ?? 0, 0)
                    XCTAssertEqual(sizes.min() ?? 0, sizes.max() ?? 0, accuracy: 1)
                }
                let remaining = columns(workspace)
                checkEqual(remaining, count: 3)
                XCTAssertEqual(remaining.map(\.columnID), ids.filter { $0 != ids[closedIndex] })
                workspace.closePane(remaining[1])
                let halves = columns(workspace)
                checkEqual(halves, count: 2)
                XCTAssertEqual(halves.map { $0.prompt.string }, halves.map { "Draft \($0.columnID)" })
                workspace.stopAll()
                let restored = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
                defer { restored.stopAll(); restored.window?.close() }
                checkEqual(columns(restored), count: 2)
                XCTAssertEqual(columns(restored).map(\.columnID), halves.map(\.columnID))
                restored.closePane(try XCTUnwrap(columns(restored).first))
                checkEqual(columns(restored), count: 1)
            }
        }
    }

    @MainActor
    func testProjectSwitchAndRelaunchRestoreIndependentWorkspaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let a1 = Session(project: a, title: "A one", storageRoot: root)
        let a2 = Session(project: a, title: "A two", storageRoot: root)
        let b1 = Session(project: b, title: "B one", storageRoot: root)
        let b2 = Session(project: b, title: "B closed", storageRoot: root)
        let sessions = [a1, a2, b1, b2]
        sessions.forEach { session in
            for index in 0..<40 { session.report(.prose, "Record \(index). " + String(repeating: "Some conversation. ", count: 20)) }
        }
        let aState = StreamViewState(firstRecord: 12, offset: 6, follows: false, fontSize: 18, searchQuery: "conversation", searchVisible: true)
        store.save(WorkspaceSnapshot(primary: a1.id, secondary: a2.id,
            drafts: [a1.id: "First draft", a2.id: "Second draft"], streams: [a1.id: aState], closedTabs: [b2.id], selectedProject: a.path,
            projects: [a.path: ProjectViewState(primary: a1.id, secondary: a2.id, splitFraction: 0.63, focusedSecondary: true, tabs: [a2.id, a1.id]),
                       b.path: ProjectViewState(primary: b1.id)]))
        store.flush()
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close() }
        var panes = columns(workspace)
        XCTAssertEqual(panes.map { $0.session?.id }, [a1.id, a2.id])
        XCTAssertEqual(panes.map { $0.prompt.string }, ["First draft", "Second draft"])
        XCTAssertTrue(window.firstResponder === panes[1].prompt)
        XCTAssertEqual(panes[0].stream.viewState.firstRecord, 12)
        panes[1].prompt.string = "Edited second draft"
        workspace.selectProject(b.path)
        panes = columns(workspace)
        XCTAssertEqual(panes.map { $0.session?.id }, [b1.id])
        panes[0].prompt.string = "Project B draft"
        // Switch before the queued restoration completes; it must never touch B.
        workspace.selectProject(a.path)
        panes = columns(workspace)
        XCTAssertEqual(panes.map { $0.session?.id }, [a1.id, a2.id])
        XCTAssertEqual(panes[1].prompt.string, "Edited second draft")
        XCTAssertTrue(window.firstResponder === panes[1].prompt)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(panes[0].stream.viewState.follows)
        XCTAssertEqual(panes[0].stream.viewState.firstRecord, 12)
        XCTAssertEqual(panes[0].stream.viewState.fontSize, 18)
        XCTAssertEqual(panes[0].stream.viewState.searchQuery, "conversation")
        // A narrow window may clamp the requested 63:37 split at a pane's
        // native minimum. Giving it room must recover the saved proportions.
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        let fraction = panes[0].view.frame.width / (panes[0].view.frame.width + panes[1].view.frame.width)
        XCTAssertEqual(fraction, 0.63, accuracy: 0.02)
        workspace.selectProject(b.path)
        XCTAssertEqual(columns(workspace).first?.prompt.string, "Project B draft")
        workspace.stopAll()
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.projects?[a.path]?.tabs, [a2.id, a1.id])
        XCTAssertEqual(saved.closedTabs, [b2.id])
        XCTAssertEqual(saved.selectedProject, b.path)
        let relaunched = WorkspaceWindow(restoredSessions: sessions.reversed(), stateStore: store)
        defer { relaunched.stopAll(); relaunched.window?.close() }
        XCTAssertEqual(columns(relaunched).map { $0.session?.id }, [b1.id])
        relaunched.selectProject(a.path)
        XCTAssertEqual(columns(relaunched).map { $0.session?.id }, [a1.id, a2.id])
        XCTAssertEqual(columns(relaunched).last?.prompt.string, "Edited second draft")
    }

    @MainActor
    func testLegacySnapshotMigratesAndEmptyProjectStaysEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let a = Session(project: root.appendingPathComponent("A"), storageRoot: root)
        let a2 = Session(project: a.project, storageRoot: root)
        let b = Session(project: root.appendingPathComponent("B"), storageRoot: root)
        let legacy = WorkspaceSnapshot(primary: a.id, secondary: a2.id, closedTabs: [b.id])
        // Encoding omits the new optional fields, as older files did.
        store.save(legacy); store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [a, a2, b], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        XCTAssertEqual(columns(workspace).map { $0.session?.id }, [a.id, a2.id])
        workspace.selectProject(b.project.path)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertNil(columns(workspace).first?.session)
        workspace.selectProject(a.project.path)
        XCTAssertEqual(columns(workspace).map { $0.session?.id }, [a.id, a2.id])
        workspace.selectProject(b.project.path)
        workspace.stopAll()
        let relaunched = WorkspaceWindow(restoredSessions: [a, a2, b], stateStore: store)
        defer { relaunched.stopAll(); relaunched.window?.close() }
        XCTAssertNil(columns(relaunched).first?.session)
        XCTAssertEqual(store.load()?.selectedProject, b.project.path)
    }

    @MainActor
    func testClosingSplitIsRememberedOnlyForItsProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let a = Session(project: root.appendingPathComponent("A"), storageRoot: root)
        let a2 = Session(project: a.project, storageRoot: root)
        let b = Session(project: root.appendingPathComponent("B"), storageRoot: root)
        let b2 = Session(project: b.project, storageRoot: root)
        store.save(WorkspaceSnapshot(selectedProject: a.project.path, projects: [
            a.project.path: ProjectViewState(primary: a.id, secondary: a2.id),
            b.project.path: ProjectViewState(primary: b.id, secondary: b2.id)
        ])); store.flush()
        let workspace = WorkspaceWindow(restoredSessions: [a, a2, b, b2], stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.singlePane(nil)
        XCTAssertEqual(columns(workspace).count, 1)
        workspace.selectProject(b.project.path)
        XCTAssertEqual(columns(workspace).count, 2)
        workspace.selectProject(a.project.path)
        XCTAssertEqual(columns(workspace).map { $0.session?.id }, [a.id])
    }
    @MainActor
    func testClosingRightPaneTabsPreservesLeftPaneAndRestoresIndependentLists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let left = Session(project: root, title: "Left", storageRoot: root)
        let right = Session(project: root, title: "Right", storageRoot: root)
        let spare = Session(project: root, title: "Spare", storageRoot: root)
        let sessions = [left, right, spare]
        store.save(WorkspaceSnapshot(selectedProject: root.path, projects: [
            root.path: ProjectViewState(primary: left.id, secondary: right.id)
        ])); store.flush()
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        let panes = columns(workspace)
        panes[0].prompt.string = "Keep this draft"
        let originalTabs = panes[0].tabIDs
        // Close the left pane's active chat from the RIGHT tab strip.
        panes[1].onCloseChat?(0)
        XCTAssertTrue(panes[0].session === left)
        XCTAssertEqual(panes[0].prompt.string, "Keep this draft")
        XCTAssertEqual(panes[0].tabIDs, originalTabs)
        XCTAssertFalse(panes[1].tabIDs.contains(left.id))
        XCTAssertTrue(panes[1].session === right)
        // Closing the right active tab chooses its own next tab.
        panes[1].onCloseChat?(1)
        XCTAssertTrue(panes[1].session === spare)
        XCTAssertTrue(panes[0].session === left)
        // Closing its final tab removes the pane while preserving the left pane.
        panes[1].onCloseChat?(2)
        XCTAssertEqual(columns(workspace).count, 1)
        XCTAssertTrue(columns(workspace)[0] === panes[0])
        XCTAssertEqual(panes[0].tabIDs, originalTabs)
        workspace.stopAll()
        let relaunched = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { relaunched.stopAll(); relaunched.window?.close() }
        let restored = columns(relaunched)
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].session === left)
        XCTAssertEqual(restored[0].tabIDs, originalTabs)
        XCTAssertEqual(restored[0].prompt.string, "Keep this draft")
    }

    @MainActor
    func testRecursiveGridRestoresDraftsFocusAndCanKeepDividing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(url: root.appendingPathComponent("workspace.json"))
        let sessions = (0..<5).map { Session(project: root, title: "Chat \($0)", storageRoot: root) }
        let workspace = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { workspace.stopAll(); workspace.window?.close() }
        workspace.window?.setContentSize(NSSize(width: 1400, height: 1000))
        var panes = columns(workspace)
        let first = panes[0]
        for (session, side, target) in [(sessions[1], TabSplitSide.right, first),
                                        (sessions[2], TabSplitSide.bottom, first)] {
            XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: session.id, columnID: first.columnID), on: side, in: target))
        }
        panes = columns(workspace)
        XCTAssertEqual(panes.count, 3)
        let right = try XCTUnwrap(panes.first { $0.session === sessions[1] })
        XCTAssertTrue(workspace.dropTab(ChatTabDrag(sessionID: sessions[3].id, columnID: first.columnID), on: .bottom, in: right))
        panes = columns(workspace)
        XCTAssertEqual(panes.count, 4)
        let widths = panes.map { $0.view.bounds.width }, heights = panes.map { $0.view.bounds.height }
        XCTAssertEqual(widths.max()!, widths.min()!, accuracy: 2)
        XCTAssertEqual(heights.max()!, heights.min()!, accuracy: 2)
        for (index, pane) in panes.enumerated() { pane.prompt.string = "Draft \(index)" }
        let focused = panes[2]
        workspace.window?.makeFirstResponder(focused.prompt)
        workspace.stopAll()
        let restored = WorkspaceWindow(restoredSessions: sessions, stateStore: store)
        defer { restored.stopAll(); restored.window?.close() }
        let recovered = columns(restored)
        XCTAssertEqual(recovered.map(\.columnID), panes.map(\.columnID))
        XCTAssertEqual(recovered.map { $0.prompt.string }, panes.map { $0.prompt.string })
        XCTAssertTrue(restored.window?.firstResponder === recovered[2].prompt)
        let spare = sessions[4]
        let owner = try XCTUnwrap(recovered.first { $0.tabIDs.contains(spare.id) })
        XCTAssertTrue(restored.dropTab(ChatTabDrag(sessionID: spare.id, columnID: owner.columnID), on: .right, in: recovered[3]))
        XCTAssertEqual(columns(restored).count, 5)
        restored.closePane(recovered[0])
        XCTAssertEqual(columns(restored).count, 4)
        XCTAssertFalse(columns(restored).contains { $0 === recovered[0] })
        XCTAssertEqual(recovered[2].prompt.string, "Draft 2")
    }

}
