import Foundation

/// User-authored metadata for a session: a custom name (overriding the
/// auto-generated title) and tags. Not derivable from the JSONL, so it is stored
/// separately from the rebuildable index.
public struct SessionMeta: Codable, Sendable, Hashable {
    public var name: String?
    public var tags: [String]
    public var pinned: Bool
    public var archived: Bool

    public init(name: String? = nil, tags: [String] = [], pinned: Bool = false, archived: Bool = false) {
        self.name = name
        self.tags = tags
        self.pinned = pinned
        self.archived = archived
    }

    public var isEmpty: Bool {
        (name?.isEmpty ?? true) && tags.isEmpty && !pinned && !archived
    }

    // Tolerant decoding so the on-disk format can gain fields without breaking
    // older files (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}
