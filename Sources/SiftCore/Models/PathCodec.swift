import Foundation

/// Maps between Claude Code's `~/.claude/projects` directory names and filesystem paths.
///
/// Claude encodes a working directory by replacing every `/` with `-`, so
/// `/Users/alex/Downloads` becomes `-Users-alex-Downloads`. Decoding is
/// therefore best-effort: a literal `-` inside a path (e.g. `YEDEK-AHMET`) is
/// indistinguishable from an encoded separator. The authoritative path always
/// comes from the `cwd` field inside a session's JSONL; this codec is only for
/// grouping and display before a session has been parsed.
public enum PathCodec {

    public static func decode(_ encoded: String) -> String {
        guard !encoded.isEmpty else { return "/" }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    public static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    public static func displayName(forDecodedPath path: String) -> String {
        let trimmed = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? trimmed : last
    }
}
