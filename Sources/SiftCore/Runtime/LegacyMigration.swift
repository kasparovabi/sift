import Foundation

/// Carries data over from the app's previous identity.
///
/// The app was renamed, which changes both places macOS keys user data on: the bundle
/// identifier (so preferences land in a different plist) and the Application Support folder
/// name. Without this, a rename silently orphans the session index, the knowledge store, and
/// every saved prompt and scheduled job — the app looks freshly installed and rebuilds an
/// index that already exists. Runs once, never overwrites anything already present.
///
/// The literals below are the *old* identity on purpose. A project-wide rename must leave
/// them alone, or the migration quietly becomes a no-op that copies a folder onto itself.
public enum LegacyMigration {

    private static let legacyBundleID = "com." + "claudeos" + ".app"
    private static let legacyFolder = "Claude" + "OS"
    private static let legacyKeyPrefix = "claudeos" + "."
    private static let currentKeyPrefix = "sift."

    public static func run(applicationSupport: URL, currentFolder: String = "Sift",
                           defaults: UserDefaults = .standard) {
        moveSupportDirectory(in: applicationSupport, from: legacyFolder, to: currentFolder)
        copyPreferences(from: legacyBundleID, into: defaults)
    }

    /// Moves the old support folder across, but only when there is nothing to lose: if the
    /// new folder already exists the app has run under its new name and its data wins.
    static func moveSupportDirectory(in applicationSupport: URL, from oldFolder: String,
                                     to currentFolder: String) {
        let fm = FileManager.default
        guard oldFolder != currentFolder else { return }
        let old = applicationSupport.appendingPathComponent(oldFolder, isDirectory: true)
        let new = applicationSupport.appendingPathComponent(currentFolder, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    /// Preferences live per bundle identifier, so the old ones are in another domain
    /// entirely and have to be read from it explicitly rather than renamed in place.
    static func copyPreferences(from oldBundleID: String, into defaults: UserDefaults,
                                oldPrefix: String? = nil) {
        let prefix = oldPrefix ?? legacyKeyPrefix
        guard let legacy = UserDefaults(suiteName: oldBundleID) else { return }
        for (key, value) in legacy.dictionaryRepresentation() {
            guard key.hasPrefix(prefix) else { continue }
            let renamed = currentKeyPrefix + key.dropFirst(prefix.count)
            // An existing value means the user has already set it under the new name.
            guard defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
        }
    }
}
