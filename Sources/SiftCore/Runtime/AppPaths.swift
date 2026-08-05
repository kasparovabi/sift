import Foundation

/// Where Sift reads transcripts from and writes its databases to.
///
/// Both are overridable by environment variable so a run can be pointed at throwaway data:
/// that is how the screenshots in the README are made without putting anyone's real session
/// titles on the internet, and how you can try a build without it touching your live index.
///
///     SIFT_PROJECTS_ROOT=/tmp/demo/projects \
///     SIFT_SUPPORT_DIR=/tmp/demo/support \
///     /Applications/Sift.app/Contents/MacOS/Sift
public enum AppPaths {
    public static let projectsRootKey = "SIFT_PROJECTS_ROOT"
    public static let supportDirectoryKey = "SIFT_SUPPORT_DIR"

    public static var projectsRoot: URL {
        resolve(projectsRootKey) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
    }

    public static var supportDirectory: URL {
        if let override = resolve(supportDirectoryKey) { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sift", isDirectory: true)
    }

    /// True when either path is redirected, so the app can say so instead of leaving someone
    /// wondering why their sessions are missing.
    public static var isUsingOverriddenPaths: Bool {
        resolve(projectsRootKey) != nil || resolve(supportDirectoryKey) != nil
    }

    static func resolve(_ key: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
}
