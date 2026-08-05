import Foundation

/// A folder you return to often. One tap starts a fresh Claude session there, so you skip
/// the folder picker every time. Just a path; the display name is the folder's own name.
public struct FolderBookmark: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    public var name: String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }
}

public enum FolderBookmarkStore {
    private static let key = "sift.folderBookmarks"
    public static func load() -> [FolderBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([FolderBookmark].self, from: data) else { return [] }
        return list
    }
    public static func save(_ list: [FolderBookmark]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
