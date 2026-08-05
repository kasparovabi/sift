import Foundation
import Observation
import SiftCore

/// On-disk shape: session metadata plus the set of pinned project ids.
private struct MetaFile: Codable {
    var sessions: [String: SessionMeta] = [:]
    var pinnedProjects: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([String: SessionMeta].self, forKey: .sessions) ?? [:]
        pinnedProjects = try container.decodeIfPresent([String].self, forKey: .pinnedProjects) ?? []
    }
}

/// Persists user-authored metadata (custom names, tags, pins) in its own JSON
/// file, independent of the rebuildable index so it survives a full rescan or
/// index deletion.
@MainActor
@Observable
public final class SessionMetaStore {
    public private(set) var metas: [String: SessionMeta] = [:]
    public private(set) var pinnedProjects: Set<String> = []

    @ObservationIgnored private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = AppPaths.supportDirectory.appendingPathComponent("session-meta.json")
        }
        load()
    }

    // MARK: - Sessions

    public func meta(for sessionId: String) -> SessionMeta {
        metas[sessionId] ?? SessionMeta()
    }

    public func setName(_ name: String?, for sessionId: String) {
        var meta = meta(for: sessionId)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        write(meta, for: sessionId)
    }

    public func setTags(_ tags: [String], for sessionId: String) {
        var meta = meta(for: sessionId)
        var seen = Set<String>()
        meta.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        write(meta, for: sessionId)
    }

    public func togglePin(for sessionId: String) {
        var meta = meta(for: sessionId)
        meta.pinned.toggle()
        write(meta, for: sessionId)
    }

    public func isPinned(_ sessionId: String) -> Bool {
        metas[sessionId]?.pinned ?? false
    }

    public func toggleArchive(for sessionId: String) {
        var meta = meta(for: sessionId)
        meta.archived.toggle()
        if meta.archived { meta.pinned = false }  // archived items shouldn't also be pinned
        write(meta, for: sessionId)
    }

    public func isArchived(_ sessionId: String) -> Bool {
        metas[sessionId]?.archived ?? false
    }

    public var allTags: [String] {
        Array(Set(metas.values.flatMap(\.tags))).sorted()
    }

    // MARK: - Projects

    public func toggleProjectPin(_ projectId: String) {
        if pinnedProjects.contains(projectId) {
            pinnedProjects.remove(projectId)
        } else {
            pinnedProjects.insert(projectId)
        }
        save()
    }

    public func isProjectPinned(_ projectId: String) -> Bool {
        pinnedProjects.contains(projectId)
    }

    // MARK: - Persistence

    private func write(_ meta: SessionMeta, for sessionId: String) {
        if meta.isEmpty {
            metas[sessionId] = nil
        } else {
            metas[sessionId] = meta
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(MetaFile.self, from: data) else { return }
        metas = file.sessions
        pinnedProjects = Set(file.pinnedProjects)
    }

    private func save() {
        var file = MetaFile()
        file.sessions = metas
        file.pinnedProjects = pinnedProjects.sorted()
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
