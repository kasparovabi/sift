import Foundation

/// A free-floating note pinned to the desktop. Plain text, a colour, and a position
/// on the canvas. Kept deliberately small: jot a thought, a command, a reminder — it
/// stays on the wallpaper until you delete it.
public struct StickyNote: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var text: String = ""
    public var colorIndex: Int = 0
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), text: String = "", colorIndex: Int = 0, x: Double, y: Double) {
        self.id = id
        self.text = text
        self.colorIndex = colorIndex
        self.x = x
        self.y = y
    }

    /// Pastel note colours as [red, green, blue] in 0…1. Index wraps if out of range.
    /// Sarı / Yeşil / Mavi / Pembe / Mor — solid fills (no backdrop material) so dragging
    /// a note across the wallpaper never flickers.
    public static let palette: [[Double]] = [
        [0.99, 0.90, 0.45],   // Sarı
        [0.70, 0.90, 0.55],   // Yeşil
        [0.60, 0.82, 0.98],   // Mavi
        [0.99, 0.74, 0.82],   // Pembe
        [0.82, 0.74, 0.99],   // Mor
    ]

    public var rgb: (r: Double, g: Double, b: Double) {
        let c = StickyNote.palette[((colorIndex % StickyNote.palette.count) + StickyNote.palette.count) % StickyNote.palette.count]
        return (c[0], c[1], c[2])
    }
}

public enum StickyNoteStore {
    private static let key = "claudeos.stickyNotes"
    public static func load() -> [StickyNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([StickyNote].self, from: data) else { return [] }
        return list
    }
    public static func save(_ list: [StickyNote]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
