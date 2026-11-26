import AppKit

struct StreamViewState: Codable {
    var firstRecord: Int = 0
    var offset: Double = 0
    var follows: Bool = true
    var fontSize: Double = 16
    var searchQuery: String?
    var searchVisible: Bool?
    var navigatorWidth: Double?
}

struct PaneViewState: Codable {
    var id: UUID
    var session: UUID?
    var tabs: [UUID]
    var tabOffset: Double
    // Each pane can visit the same conversation at a different position.
    var streams: [UUID: StreamViewState]?
    var closedTabs: [UUID]?
}

indirect enum PaneLayout: Codable, Equatable {
    case pane(UUID)
    case split(vertical: Bool, fraction: Double, first: PaneLayout, second: PaneLayout)

    /// A comfortable pane. Wider panes use the regular chrome and text size.
    static let minimumPaneSize = NSSize(width: 260, height: 300)
    /// The floor on a cramped display: the pane's chrome and text go compact.
    static let compactPaneSize = NSSize(width: 170, height: 260)
    /// Lanes share the visible area up to these counts, then the pane area scrolls.
    static let visibleColumnsBeforeScrolling = 5
    static let visibleRowsBeforeScrolling = 5

    /// Fit five columns in the current pane viewport, including dividers and insets.
    static func rebalancedColumnWidth(viewport: NSSize, paneInset: CGFloat = 0) -> CGFloat {
        guard viewport.width.isFinite, viewport.width > 0 else { return 0 }
        let columns = CGFloat(visibleColumnsBeforeScrolling)
        return max(0, (viewport.width - (columns - 1)) / columns - 2 * paneInset)
    }

    /// The smallest pane for a visible pane area. A big display gives every
    /// lane a fifth of its width and height; a cramped one stops
    /// at the compact floor and scrolls sooner. There is no cap on pane count.
    static func adaptiveMinimum(viewport: NSSize, paneInset: CGFloat = 0, divider: CGFloat = 1) -> NSSize {
        func share(_ extent: CGFloat, _ lanes: Int, _ floor: CGFloat) -> CGFloat {
            guard extent.isFinite, extent > 0 else { return floor }
            let each = ((extent - CGFloat(lanes - 1) * divider) / CGFloat(lanes)).rounded(.down) - 2 * paneInset
            return max(floor, each)
        }
        return NSSize(width: share(viewport.width, visibleColumnsBeforeScrolling, compactPaneSize.width),
                      height: share(viewport.height, visibleRowsBeforeScrolling, compactPaneSize.height))
    }

    var dimensions: (columns: Int, rows: Int) {
        switch self {
        case .pane: return (1, 1)
        case .split(let vertical, _, let first, let second):
            let a = first.dimensions, b = second.dimensions
            return vertical ? (a.columns + b.columns, max(a.rows, b.rows))
                : (max(a.columns, b.columns), a.rows + b.rows)
        }
    }

    var minimumSize: NSSize {
        minimumSize(paneInset: 0)
    }

    func minimumSize(paneInset: CGFloat, paneMinimum: NSSize = Self.minimumPaneSize) -> NSSize {
        switch self {
        case .pane: return NSSize(width: paneMinimum.width + 2 * paneInset,
                                  height: paneMinimum.height + 2 * paneInset)
        case .split(let vertical, _, let first, let second):
            let a = first.minimumSize(paneInset: paneInset, paneMinimum: paneMinimum)
            let b = second.minimumSize(paneInset: paneInset, paneMinimum: paneMinimum)
            return vertical ? NSSize(width: a.width + b.width + 1, height: max(a.height, b.height))
                : NSSize(width: max(a.width, b.width), height: a.height + b.height + 1)
        }
    }

    /// Any existing pane can be split. Room is made by shrinking panes to the
    /// adaptive minimum and then scrolling, never by refusing the split.
    func permitsSplit(of id: UUID) -> Bool { ids.contains(id) }

    var ids: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.ids + second.ids
        }
    }
    /// Older workspaces saved long rows as a chain of nested split views.
    /// Regroup only deep trees, carrying each lane's size across the dividers.
    func shorteningDeepSplits(canvasSize: NSSize?) -> PaneLayout {
        func exceedsDepth(_ node: PaneLayout, remaining: Int) -> Bool {
            guard case let .split(_, _, first, second) = node else { return false }
            return remaining == 0 || exceedsDepth(first, remaining: remaining - 1)
                || exceedsDepth(second, remaining: remaining - 1)
        }
        guard exceedsDepth(self, remaining: 12) else { return self }
        let minimum = minimumSize
        let size = NSSize(width: max(minimum.width, canvasSize?.width ?? 0),
                          height: max(minimum.height, canvasSize?.height ?? 0))
        func rebuild(_ node: PaneLayout, size: NSSize) -> PaneLayout {
            guard case let .split(vertical, _, _, _) = node else { return node }
            var lanes: [(layout: PaneLayout, extent: CGFloat)] = []
            func collect(_ part: PaneLayout, extent: CGFloat) {
                if case let .split(axis, fraction, first, second) = part, axis == vertical {
                    let content = max(0, extent - 1)
                    let share = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
                    collect(first, extent: content * share)
                    collect(second, extent: content * (1 - share))
                } else {
                    let laneSize = vertical ? NSSize(width: extent, height: size.height)
                                            : NSSize(width: size.width, height: extent)
                    lanes.append((rebuild(part, size: laneSize), extent))
                }
            }
            collect(node, extent: vertical ? size.width : size.height)
            func join(_ range: Range<Int>) -> (layout: PaneLayout, extent: CGFloat) {
                if range.count == 1 { return lanes[range.lowerBound] }
                let middle = range.lowerBound + range.count / 2
                let left = join(range.lowerBound..<middle), right = join(middle..<range.upperBound)
                let content = left.extent + right.extent
                return (.split(vertical: vertical, fraction: content > 0 ? left.extent / content : 0.5,
                               first: left.layout, second: right.layout), content + 1)
            }
            return join(lanes.indices).layout
        }
        return rebuild(self, size: size)
    }

    func replacing(_ id: UUID, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let value): return value == id ? replacement : self
        case .split(let vertical, let fraction, let first, let second):
            return .split(vertical: vertical, fraction: fraction,
                          first: first.replacing(id, with: replacement), second: second.replacing(id, with: replacement))
        }
    }
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let value): return value == id ? nil : self
        case .split(let vertical, let fraction, let first, let second):
            let a = first.removing(id), b = second.removing(id)
            if let a, let b { return .split(vertical: vertical, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }

    /// Rows of side-by-side panes, filled left to right, with equal shares.
    static func grid(_ ids: [UUID], columns requested: Int? = nil) -> PaneLayout? {
        guard !ids.isEmpty else { return nil }
        let columns = min(ids.count, max(1, requested ?? Int(Double(ids.count).squareRoot().rounded(.up))))
        let rows = stride(from: 0, to: ids.count, by: columns).map { Array(ids[$0..<min($0 + columns, ids.count)]) }
        func chain(_ parts: [PaneLayout], weights: [Int], vertical: Bool) -> PaneLayout {
            guard parts.count > 1 else { return parts[0] }
            let total = weights.reduce(0, +)
            return .split(vertical: vertical, fraction: Double(weights[0]) / Double(total), first: parts[0],
                          second: chain(Array(parts.dropFirst()), weights: Array(weights.dropFirst()), vertical: vertical))
        }
        let rowLayouts = rows.map { row in chain(row.map(PaneLayout.pane), weights: row.map { _ in 1 }, vertical: true) }
        return chain(rowLayouts, weights: rows.map { _ in 1 }, vertical: false)
    }

    /// The column count whose panes come closest to a readable upright shape
    /// in this pane area, preferring grids without a ragged last row.
    static func gridColumns(count: Int, viewport: NSSize) -> Int {
        guard count > 1 else { return 1 }
        guard viewport.width > 0, viewport.height > 0 else { return Int(Double(count).squareRoot().rounded(.up)) }
        let minimum = adaptiveMinimum(viewport: viewport)
        var best = 1, bestScore = Double.greatestFiniteMagnitude
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            // Panes never get smaller than the adaptive minimum; past it the area scrolls.
            let width = max(minimum.width, viewport.width / CGFloat(columns))
            let height = max(minimum.height, viewport.height / CGFloat(rows))
            let shape = abs(log(Double(width / height) / 0.9))
            let scrolling = Double(max(0, columns - visibleColumnsBeforeScrolling)) * 0.6
                + Double(max(0, rows - visibleRowsBeforeScrolling)) * 0.9
            let ragged = Double(columns * rows - count) / Double(count) * 0.5
            let score = shape + scrolling + ragged
            if score < bestScore - 0.0001 { best = columns; bestScore = score }
        }
        return best
    }

    /// A tidy layout for any number of panes, keeping their reading order.
    static func arranged(_ ids: [UUID], as arrangement: PaneArrangement, viewport: NSSize = .zero) -> PaneLayout? {
        switch arrangement {
        case .grid: return grid(ids, columns: gridColumns(count: ids.count, viewport: viewport))
        case .columns: return grid(ids, columns: ids.count)
        case .rows: return grid(ids, columns: 1)
        }
    }

    /// The surviving sibling identifies the row or column that loses a pane.
    func removalBalanceTarget(for id: UUID) -> (paneID: UUID, vertical: Bool)? {
        guard case .split(let vertical, _, let first, let second) = self else { return nil }
        if case .pane(let firstID) = first, firstID == id, let sibling = second.ids.first {
            return (sibling, vertical)
        }
        if case .pane(let secondID) = second, secondID == id, let sibling = first.ids.first {
            return (sibling, vertical)
        }
        return first.removalBalanceTarget(for: id) ?? second.removalBalanceTarget(for: id)
    }
}

enum PaneArrangement: String, CaseIterable {
    case grid, columns, rows

    var title: String {
        switch self {
        case .grid: return "Tidy into Grid"
        case .columns: return "Side by Side"
        case .rows: return "Stacked"
        }
    }
}

/// Accepted only when reading pre-region workspace snapshots.
enum WorkspaceLayoutMode: String, Codable {
    case tabs, panes

}

struct TabbedViewState: Codable {
    var selectedChat: UUID?
    var tabs: [UUID]
    var tabOffset: Double = 0
    var streams: [UUID: StreamViewState] = [:]
    var closedTabs: [UUID] = []
}

struct ProjectViewState: Codable {
    /// Current format. Legacy tabs below are read only when migrating a workspace.
    var regions: [ChatRegionState]?
    var layout: PaneLayout?
    /// Present after manual resizing, even when no extra canvas space was needed.
    var paneCanvasSize: NSSize?
    var compactColumnSizing: Bool?
    var panes: [PaneViewState]?
    var focusedPane: UUID?
    var primary: UUID?
    var secondary: UUID?
    var splitFraction: Double = 0.5
    var focusedSecondary: Bool = false
    var tabs: [UUID]?
    var primaryTabOffset: Double?
    var secondaryTabOffset: Double?
    var primaryTabs: [UUID]?
    var secondaryTabs: [UUID]?
    var historyExpanded: Bool?
    var tabbed: TabbedViewState?


}

struct ChatRegionState: Codable {
    var id: UUID
    var session: UUID?
    var stream: StreamViewState?
}

struct ChatRegionLayout {
    var layout: PaneLayout?
    var regions: [ChatRegionState]
    var focused: UUID?
}

extension ProjectViewState {
    /// Expand old tab groups in place, preserving split geometry and the selected
    /// chat's region identity. A conversation can occur only once in the result.
    func chatRegionLayout(validIDs: Set<UUID>, fallbackIDs: [UUID], preferTabbed: Bool = false) -> ChatRegionLayout {
        var result: [ChatRegionState] = []
        var seen = Set<UUID>()
        var tree: PaneLayout?
        var focus = focusedPane
        var owners: [UUID: UUID] = [:]
        for pane in panes ?? [] {
            if let chat = pane.session, owners[chat] == nil || pane.id == focusedPane { owners[chat] = pane.id }
        }
        func append(_ region: ChatRegionState) -> PaneLayout? {
            guard let session = region.session, validIDs.contains(session), seen.insert(session).inserted else { return nil }
            result.append(region)
            return .pane(region.id)
        }
        func join(_ first: PaneLayout?, _ second: PaneLayout?, vertical: Bool = true, fraction: Double? = nil) -> PaneLayout? {
            guard let first else { return second }
            guard let second else { return first }
            let firstCount = vertical ? first.dimensions.columns : first.dimensions.rows
            let secondCount = vertical ? second.dimensions.columns : second.dimensions.rows
            let share = fraction ?? Double(firstCount) / Double(firstCount + secondCount)
            return .split(vertical: vertical, fraction: share, first: first, second: second)
        }
        /// Keep a large migrated tab group shallow. Left-folding hundreds of
        /// legacy tabs creates a hundreds-deep AppKit view/controller tree;
        /// AppKit then recursively resolves constraints until launch stalls.
        func balancedJoin(_ layouts: [PaneLayout], vertical: Bool = true) -> PaneLayout? {
            func build(_ range: Range<Int>) -> PaneLayout? {
                guard !range.isEmpty else { return nil }
                guard range.count > 1 else { return layouts[range.lowerBound] }
                let middle = range.lowerBound + range.count / 2
                return join(build(range.lowerBound..<middle), build(middle..<range.upperBound), vertical: vertical)
            }
            return build(layouts.indices)
        }
        func visit(_ node: PaneLayout) -> PaneLayout? {
            switch node {
            case .split(let vertical, let fraction, let first, let second):
                return join(visit(first), visit(second), vertical: vertical, fraction: fraction)
            case .pane(let id):
                if let regions { return regions.first { $0.id == id }.flatMap(append) }
                guard let old = panes?.first(where: { $0.id == id }) else { return nil }
                let ids = old.tabs + (old.session.map { [$0] } ?? [])
                var branch: [PaneLayout] = []
                for chat in ids {
                    if let owner = owners[chat], owner != id { continue }
                    let regionID = chat == old.session ? id : UUID()
                    if let region = append(ChatRegionState(id: regionID, session: chat, stream: old.streams?[chat])) {
                        branch.append(region)
                    }
                }
                return balancedJoin(branch)
            }
        }
        if regions != nil, let layout {
            tree = visit(layout.shorteningDeepSplits(canvasSize: paneCanvasSize))
        } else if preferTabbed, let tabbed {
            var tabLayouts: [PaneLayout] = []
            for chat in tabbed.tabs {
                let id = UUID()
                if let region = append(ChatRegionState(id: id, session: chat, stream: tabbed.streams[chat])) {
                    tabLayouts.append(region)
                }
                if chat == tabbed.selectedChat { focus = id }
            }
            tree = balancedJoin(tabLayouts)
        } else if let layout, panes != nil {
            tree = visit(layout.shorteningDeepSplits(canvasSize: paneCanvasSize))
        } else if let regions {
            var regionLayouts: [PaneLayout] = []
            for region in regions {
                if let layout = append(region) { regionLayouts.append(layout) }
            }
            tree = balancedJoin(regionLayouts)
        } else {
            func group(_ selected: UUID?, _ candidates: [UUID]) -> PaneLayout? {
                var branch: [PaneLayout] = []
                for chat in (selected.map { [$0] } ?? []) + candidates {
                    let id = UUID()
                    if let region = append(ChatRegionState(id: id, session: chat)) { branch.append(region) }
                    if chat == (focusedSecondary ? secondary : primary), result.last?.id == id { focus = id }
                }
                return balancedJoin(branch)
            }
            let left = group(primary, (primaryTabs ?? tabs ?? fallbackIDs).filter { $0 != secondary || $0 == primary })
            let right = group(secondary, secondaryTabs ?? [])
            tree = join(left, right, fraction: splitFraction)
        }
        if result.isEmpty {
            let id = regions?.first?.id ?? UUID()
            result = [ChatRegionState(id: id, session: nil)]
            tree = .pane(id)
        }
        if !result.contains(where: { $0.id == focus }) { focus = result.first?.id }
        return ChatRegionLayout(layout: tree, regions: result, focused: focus)
    }
}

struct WorkspaceSnapshot: Codable {
    var primary: UUID?
    var secondary: UUID?
    var drafts: [UUID: String] = [:]
    var streams: [UUID: StreamViewState] = [:]
    var windowFrame: String?
    var closedTabs: [UUID]?
    var selectedProject: String?
    var projects: [String: ProjectViewState]?
    var attachmentDrafts: [UUID: [ChatAttachment]]?
    var sidebarChatFraction: Double?
    /// Projects hidden from the sidebar. Their chats stay on disk.
    var removedProjects: [String]?
    /// Stable chat positions, including closed tabs so reopening doesn't move them.
    var sidebarConversationOrder: [UUID]?
    var layoutMode: WorkspaceLayoutMode?
}

final class WorkspaceStateStore {
    private let queue = DispatchQueue(label: "app.unfold.workspace-state", qos: .utility)
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnfoldNative/workspace-state.json")
    }
    func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }
    func save(_ value: WorkspaceSnapshot) {
        let destination = url
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    func flush() { queue.sync {} }
}

// Swift's UUID-keyed dictionaries normally encode as pairs. Accept older
// object-shaped state too, including the empty dictionaries in early snapshots.
extension WorkspaceSnapshot {
    enum CodingKeys: String, CodingKey {
        case primary, secondary, drafts, streams, windowFrame, closedTabs, selectedProject, projects, attachmentDrafts, sidebarChatFraction, removedProjects, sidebarConversationOrder, layoutMode
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func dictionary<T: Decodable>(_ key: CodingKeys) throws -> [UUID: T] {
            guard values.contains(key), try !values.decodeNil(forKey: key) else { return [:] }
            if let pairs = try? values.decode([UUID: T].self, forKey: key) { return pairs }
            let object = try values.decode([String: T].self, forKey: key)
            return Dictionary(uniqueKeysWithValues: object.compactMap { name, value in UUID(uuidString: name).map { ($0, value) } })
        }
        primary = try values.decodeIfPresent(UUID.self, forKey: .primary)
        secondary = try values.decodeIfPresent(UUID.self, forKey: .secondary)
        drafts = try dictionary(.drafts)
        streams = try dictionary(.streams)
        windowFrame = try values.decodeIfPresent(String.self, forKey: .windowFrame)
        closedTabs = try values.decodeIfPresent([UUID].self, forKey: .closedTabs)
        selectedProject = try values.decodeIfPresent(String.self, forKey: .selectedProject)
        projects = try values.decodeIfPresent([String: ProjectViewState].self, forKey: .projects)
        attachmentDrafts = values.contains(.attachmentDrafts) ? try dictionary(.attachmentDrafts) : nil
        sidebarChatFraction = try values.decodeIfPresent(Double.self, forKey: .sidebarChatFraction)
        removedProjects = try values.decodeIfPresent([String].self, forKey: .removedProjects)
        sidebarConversationOrder = try values.decodeIfPresent([UUID].self, forKey: .sidebarConversationOrder)
        layoutMode = try values.decodeIfPresent(WorkspaceLayoutMode.self, forKey: .layoutMode)
    }
}
