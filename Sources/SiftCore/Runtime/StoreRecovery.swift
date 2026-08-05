import Foundation

/// Opens a SQLite-backed store, and if the file will not open, moves it aside and tries
/// once more on a fresh file.
///
/// A corrupt or half-written database used to be fatal at launch, which left the app
/// permanently unopenable for anyone who did not know to delete a file inside
/// `~/Library/Application Support`. The damaged file is kept rather than deleted: the
/// index rebuilds from the transcripts, but the brain does not, so its contents are the
/// user's to recover.
public enum StoreRecovery {
    public struct Outcome<Store> {
        public let store: Store
        /// Where the unopenable file was moved, when one had to be moved.
        public let quarantined: URL?
    }

    public static func open<Store>(at url: URL,
                                   using make: (URL) throws -> Store) throws -> Outcome<Store> {
        do {
            return Outcome(store: try make(url), quarantined: nil)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            let moved = quarantine(url)
            return Outcome(store: try make(url), quarantined: moved)
        }
    }

    /// Move `url` and its SQLite sidecars to the first free `<name>.corrupt[-n]` path.
    /// Returns the destination, or nil if nothing could be moved.
    @discardableResult
    public static func quarantine(_ url: URL) -> URL? {
        let fm = FileManager.default
        let destination = firstFreeName(for: url)
        do {
            try fm.moveItem(at: url, to: destination)
        } catch {
            return nil
        }
        for sidecar in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + sidecar)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: URL(fileURLWithPath: destination.path + sidecar))
        }
        return destination
    }

    static func firstFreeName(for url: URL) -> URL {
        let fm = FileManager.default
        let base = url.path + ".corrupt"
        if !fm.fileExists(atPath: base) { return URL(fileURLWithPath: base) }
        var n = 2
        while fm.fileExists(atPath: "\(base)-\(n)") { n += 1 }
        return URL(fileURLWithPath: "\(base)-\(n)")
    }
}
