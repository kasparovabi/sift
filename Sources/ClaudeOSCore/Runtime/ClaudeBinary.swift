import Foundation

/// Resolves the `claude` executable using the repaired PATH, with a hard fallback
/// to `~/.local/bin/claude` (the standard install location).
public enum ClaudeBinary {
    public static func resolve() -> URL {
        let env = EnvironmentResolver.resolved()
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("claude")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude")
    }
}
