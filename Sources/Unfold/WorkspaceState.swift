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

    static let maximumColumns = 12
    static let maximumRows = 6
    static let minimumPaneSize = NSSize(width: 260, height: 300)

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

    func permitsSplit(of id: UUID, vertical: Bool, availableSize: NSSize? = nil, paneInset: CGFloat = 0,
                      paneMinimum: NSSize = Self.minimumPaneSize) -> Bool {
        guard ids.contains(id) else { return false }
        let proposed = replacing(id, with: .split(vertical: vertical, fraction: 0.5,
                                                  first: .pane(id), second: .pane(UUID())))
        let dimensions = proposed.dimensions
        guard dimensions.columns <= Self.maximumColumns, dimensions.rows <= Self.maximumRows else { return false }
        guard let availableSize else { return true }
        let required = proposed.minimumSize(paneInset: paneInset, paneMinimum: paneMinimum)
        return required.width <= availableSize.width && required.height <= availableSize.height
    }

    var ids: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.ids + second.ids
        }
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
    static func grid(_ ids: [UUID]) -> PaneLayout? {
        guard !ids.isEmpty else { return nil }
        let columns = Int(Double(ids.count).squareRoot().rounded(.up))
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

enum WorkspaceLayoutMode: String, Codable, CaseIterable {
    case tabs, panes

    var title: String { self == .tabs ? "Tabs Only" : "Panes" }
}

struct TabbedViewState: Codable {
    var selectedChat: UUID?
    var tabs: [UUID]
    var tabOffset: Double = 0
    var streams: [UUID: StreamViewState] = [:]
    var closedTabs: [UUID] = []
}

struct ProjectViewState: Codable {
    var layout: PaneLayout?
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

    /// Seed the new view once, preserving order and the focused conversation.
    /// Subsequent visits use its own tabs without changing the saved pane layout.
    func tabbedState(fallbackTabs: [UUID]) -> TabbedViewState {
        if let tabbed { return tabbed }
        let orderedPanes = layout?.ids.compactMap { id in panes?.first { $0.id == id } } ?? panes ?? []
        let focused = orderedPanes.first { $0.id == focusedPane } ?? orderedPanes.first
        let candidates = orderedPanes.isEmpty
            ? (primaryTabs ?? fallbackTabs) + (secondaryTabs ?? [])
            : orderedPanes.flatMap(\.tabs)
        var seen = Set<UUID>()
        let tabs = candidates.filter { seen.insert($0).inserted }
        let selected = focused?.session ?? (focusedSecondary ? secondary : primary)
        var streams: [UUID: StreamViewState] = [:]
        for pane in orderedPanes { streams.merge(pane.streams ?? [:]) { first, _ in first } }
        streams.merge(focused?.streams ?? [:]) { _, focused in focused }
        return TabbedViewState(selectedChat: selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first,
                               tabs: tabs, streams: streams,
                               closedTabs: orderedPanes.flatMap { $0.closedTabs ?? [] })
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
