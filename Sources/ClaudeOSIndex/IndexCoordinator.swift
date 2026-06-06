import Foundation
import Observation
import ClaudeOSCore

/// Drives the index for the UI: holds the current project/session lists and
/// filter state, runs the scan off the main actor, watches `~/.claude/projects`
/// for live changes, and re-queries on selection/search/filter changes.
@MainActor
@Observable
public final class IndexCoordinator {
    public private(set) var projects: [Project] = []
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var isScanning = false
    public private(set) var totalSessionCount = 0

    public enum SidebarItem: Hashable, Sendable {
        case all, today, pinned
        case project(String)
    }
    public var sidebarSelection: SidebarItem = .all {
        didSet { if oldValue != sidebarSelection { Task { await reloadSessions() } } }
    }
    public var selectedProjectId: String? {
        if case .project(let id) = sidebarSelection { return id }
        return nil
    }
    public var selectedSessionId: String?
    public var searchText: String = ""

    // MARK: Filters

    public enum TimeRange: String, CaseIterable, Sendable {
        case all, today, week, month
        public var since: Date? {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .all: return nil
            case .today: return cal.startOfDay(for: now)
            case .week: return cal.date(byAdding: .day, value: -7, to: now)
            case .month: return cal.date(byAdding: .day, value: -30, to: now)
            }
        }
    }
    public var timeRange: TimeRange = .all {
        didSet { if oldValue != timeRange { Task { await reloadSessions() } } }
    }
    public var branchFilter: String? {
        didSet { if oldValue != branchFilter { Task { await reloadSessions() } } }
    }
    public var entrypointFilter: String? {
        didSet { if oldValue != entrypointFilter { Task { await reloadSessions() } } }
    }
    public var tagFilter: String? {
        didSet { if oldValue != tagFilter { Task { await reloadSessions() } } }
    }
    public var showArchived = false {
        didSet { if oldValue != showArchived { Task { await reloadSessions() } } }
    }
    public private(set) var branches: [String] = []
    public private(set) var entrypoints: [String] = []
    public var allTags: [String] { metaStore.allTags }
    public var hasActiveFilters: Bool {
        timeRange != .all || branchFilter != nil || entrypointFilter != nil || tagFilter != nil
    }
    public func clearFilters() {
        timeRange = .all
        branchFilter = nil
        entrypointFilter = nil
        tagFilter = nil
    }

    @ObservationIgnored private let store: IndexStore
    @ObservationIgnored public let metaStore = SessionMetaStore()
    @ObservationIgnored private let projectsRoot: URL
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(store: IndexStore, projectsRoot: URL? = nil) {
        self.store = store
        self.projectsRoot = projectsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public func initialLoad() async {
        await reloadProjects()
        await reloadSessions()
        await loadFilterOptions()
        totalSessionCount = (try? await store.sessionCount()) ?? 0
        let needsBackfill = (try? await store.needsContentBackfill()) ?? false
        if totalSessionCount == 0 || needsBackfill { await rescan() }
        startWatching()
    }

    public func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        let root = projectsRoot
        let result = await Task.detached(priority: .userInitiated) {
            SessionScanner.scan(projectsRoot: root, known: [:])
        }.value
        try? await store.apply(result)
        await refreshAfterIndexChange()
        isScanning = false
    }

    public func incrementalUpdate() async {
        guard !isScanning else { return }
        let known = (try? await store.fingerprints()) ?? [:]
        let root = projectsRoot
        let result = await Task.detached(priority: .utility) {
            SessionScanner.scan(projectsRoot: root, known: known)
        }.value
        if result.upserts.isEmpty && result.presentPaths.count == known.count { return }
        try? await store.apply(result)
        await refreshAfterIndexChange()
    }

    public func runSearch() async {
        await reloadSessions()
    }

    /// One-off search for the quick-open panel; does not disturb the Library's list.
    public func quickSearch(_ query: String, limit: Int = 40) async -> [SessionSummary] {
        let results = (try? await store.search(query, filters: SearchFilters())) ?? []
        return overlay(Array(results.prefix(limit)))
    }

    /// Recent sessions for the menubar/dashboard, independent of the Library's filters.
    public func recentSessions(limit: Int = 8) async -> [SessionSummary] {
        let results = (try? await store.search("", filters: SearchFilters())) ?? []
        return overlay(Array(results.prefix(limit)))
    }

    /// All pinned sessions (for the dashboard), regardless of recency.
    public func pinnedSessions() async -> [SessionSummary] {
        let ids = metaStore.metas.compactMap { $0.value.pinned ? $0.key : nil }
        let results = (try? await store.sessions(ids: ids)) ?? []
        return overlay(results)
    }

    public func rename(_ sessionId: String, to name: String?) {
        metaStore.setName(name, for: sessionId)
        Task { await reloadSessions() }
    }

    public func setTags(_ tags: [String], for sessionId: String) {
        metaStore.setTags(tags, for: sessionId)
        Task { await reloadSessions() }
    }

    public func meta(for sessionId: String) -> SessionMeta {
        metaStore.meta(for: sessionId)
    }

    public func togglePin(_ sessionId: String) {
        metaStore.togglePin(for: sessionId)
        Task { await reloadSessions() }
    }

    public func toggleArchive(_ sessionId: String) {
        metaStore.toggleArchive(for: sessionId)
        Task { await reloadSessions() }
    }

    public func toggleProjectPin(_ projectId: String) {
        metaStore.toggleProjectPin(projectId)
        Task { await reloadProjects() }
    }

    public func selectedSession() -> SessionSummary? {
        sessions.first { $0.sessionId == selectedSessionId }
    }

    // MARK: - Live watching

    private func startWatching() {
        guard watcher == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let watcher = FileWatcher(path: projectsRoot.path) { continuation.yield(()) }
        self.watcher = watcher
        watcher.start()
        watchTask = Task { [weak self] in
            for await _ in stream {
                await self?.incrementalUpdate()
            }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: - Private

    private func refreshAfterIndexChange() async {
        await reloadProjects()
        await reloadSessions()
        await loadFilterOptions()
        totalSessionCount = (try? await store.sessionCount()) ?? 0
    }

    private func reloadProjects() async {
        let fetched = (try? await store.projects()) ?? []
        let withPins = fetched.map { project -> Project in
            var copy = project
            copy.pinned = metaStore.isProjectPinned(project.id)
            return copy
        }
        // Pinned projects float to the top (stable within each group).
        projects = withPins.filter(\.pinned) + withPins.filter { !$0.pinned }
    }

    private func reloadSessions() async {
        var projectId: String?
        var smartSince: Date?
        var pinnedOnly = false
        switch sidebarSelection {
        case .all: break
        case .project(let id): projectId = id
        case .today: smartSince = Calendar.current.startOfDay(for: Date())
        case .pinned: pinnedOnly = true
        }
        // Combine the smart-list cutoff with any explicit time filter (most recent wins).
        let since = [timeRange.since, smartSince].compactMap { $0 }.max()

        let filters = SearchFilters(
            projectId: projectId,
            since: since,
            gitBranch: branchFilter,
            entrypoint: entrypointFilter
        )
        var results = overlay((try? await store.search(searchText, filters: filters)) ?? [])
        if let tag = tagFilter {
            results = results.filter { $0.tags.contains(tag) }
        }
        if pinnedOnly {
            results = results.filter(\.pinned)
        }
        if !showArchived {
            results = results.filter { !$0.archived }
        }
        // Pinned sessions float to the top (stable within each group).
        sessions = results.filter(\.pinned) + results.filter { !$0.pinned }
        // Keep selection valid so the List never points at a removed row (avoids
        // a reentrant table update).
        if let selected = selectedSessionId, !results.contains(where: { $0.sessionId == selected }) {
            selectedSessionId = nil
        }
    }

    /// Apply user metadata (custom name + tags + pin) onto fetched summaries.
    private func overlay(_ summaries: [SessionSummary]) -> [SessionSummary] {
        summaries.map { summary in
            var copy = summary
            let meta = metaStore.meta(for: summary.sessionId)
            copy.customName = meta.name
            copy.tags = meta.tags
            copy.pinned = meta.pinned
            copy.archived = meta.archived
            return copy
        }
    }

    private func loadFilterOptions() async {
        branches = (try? await store.distinctBranches()) ?? []
        entrypoints = (try? await store.distinctEntrypoints()) ?? []
    }
}
