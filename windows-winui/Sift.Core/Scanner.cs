using System.IO;
using System.Text.Json;

namespace SiftWinUI.Core;

public sealed class SessionRow
{
    public string SessionId = "";
    public string ProjectId = "";
    public string FilePath = "";
    public string? Cwd;
    public string? GitBranch;
    public string? Title;
    public string? FirstMessage;
    public string? Entrypoint;
    public long? StartedAt;
    public long? LastActivity;
    public int MessageCount;
    public int ToolCallCount;
    public long FileSize;
    public long FileMtime;
    public string FullText = "";
    public Agent Agent = Agent.ClaudeCode;
}

public sealed record Turn(string Role, string Text, long? At);

public static class Scanner
{
    /// Claude Code encodes a project's path into its directory name by turning separators
    /// into dashes. The decode is lossy, which is why a session's own `cwd` wins and this
    /// is only the fallback.
    public static string DecodeProjectDir(string name) => name.Replace('-', '/');

    private static readonly char[] Separators = { '/', '\\' };

    /// The last component of a path, whichever separator it uses. Written with an explicit
    /// array because `Split('/', '\\', options)` binds to an overload that quietly treats
    /// the options value as a separator and leaves backslash paths whole.
    public static string DisplayName(string path)
    {
        var trimmed = path.TrimEnd(Separators);
        var parts = trimmed.Split(Separators, StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 ? parts[^1] : path;
    }

    private static readonly string[] NotTypedByAnyone =
    {
        "<command-", "<local-command", "<task-notification",
        "<scheduled-wakeup", "<background-task", "<system-reminder",
    };

    /// The text of a message a person actually typed, or null. Tool results arrive as
    /// "user" messages and injected reminders look like them; neither is conversation.
    public static string? HumanText(JsonElement obj)
    {
        if (Flag(obj, "isMeta") || Flag(obj, "isSidechain")) return null;
        var text = ContentText(obj);
        if (string.IsNullOrWhiteSpace(text)) return null;
        text = text.Trim();
        foreach (var prefix in NotTypedByAnyone)
            if (text.StartsWith(prefix, StringComparison.Ordinal)) return null;
        return text;
    }

    /// What the assistant said. A turn carrying only tool calls has no prose, so it
    /// yields nothing rather than a placeholder.
    public static string? AssistantText(JsonElement obj)
    {
        var text = ContentText(obj);
        return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    }

    public static bool HasToolUse(JsonElement obj)
    {
        if (!obj.TryGetProperty("message", out var m)) return false;
        if (!m.TryGetProperty("content", out var c) || c.ValueKind != JsonValueKind.Array) return false;
        foreach (var block in c.EnumerateArray())
            if (block.TryGetProperty("type", out var t) && t.GetString() == "tool_use") return true;
        return false;
    }

    private static bool Flag(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string? ContentText(JsonElement obj)
    {
        if (!obj.TryGetProperty("message", out var message)) return null;
        if (!message.TryGetProperty("content", out var content)) return null;
        if (content.ValueKind == JsonValueKind.String) return content.GetString();
        if (content.ValueKind != JsonValueKind.Array) return null;

        var parts = new List<string>();
        foreach (var block in content.EnumerateArray())
        {
            if (block.TryGetProperty("type", out var t) && t.GetString() == "text" &&
                block.TryGetProperty("text", out var text))
            {
                var s = text.GetString();
                if (!string.IsNullOrEmpty(s)) parts.Add(s);
            }
        }
        return parts.Count == 0 ? null : string.Join("\n", parts);
    }

    private const int FullTextCap = 100_000;

    /// Reads one transcript into the row the index stores, a line at a time so a 20 MB
    /// session costs no more memory than a small one.
    public static SessionRow ParseTranscript(string filePath)
    {
        var row = new SessionRow { FilePath = filePath };
        var full = new System.Text.StringBuilder();

        foreach (var line in File.ReadLines(filePath))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonElement obj;
            try { obj = JsonDocument.Parse(line).RootElement; } catch { continue; }

            row.SessionId ??= null!;
            if (string.IsNullOrEmpty(row.SessionId)) row.SessionId = Str(obj, "sessionId") ?? "";
            row.Cwd ??= Str(obj, "cwd");
            row.GitBranch ??= Str(obj, "gitBranch");
            row.Entrypoint ??= Str(obj, "entrypoint");

            if (Str(obj, "timestamp") is { } stamp &&
                DateTimeOffset.TryParse(stamp, out var when))
            {
                var ms = when.ToUnixTimeMilliseconds();
                row.StartedAt ??= ms;
                if (row.LastActivity is null || ms > row.LastActivity) row.LastActivity = ms;
            }

            string? text = null;
            var type = Str(obj, "type");
            if (type == "user")
            {
                text = HumanText(obj);
                if (text is not null)
                {
                    row.FirstMessage ??= text.Length > 2000 ? text[..2000] : text;
                    row.MessageCount++;
                }
            }
            else if (type == "assistant")
            {
                if (HasToolUse(obj)) row.ToolCallCount++;
                // Counted only when the turn carries prose, so the number agrees with the
                // transcript, which shows what the two sides said and nothing else.
                text = AssistantText(obj);
                if (text is not null) row.MessageCount++;
            }
            else if (type == "ai-title")
            {
                row.Title = Str(obj, "title") ?? row.Title;
            }

            if (text is not null && full.Length < FullTextCap) full.Append(text).Append('\n');
        }

        row.FullText = full.Length > FullTextCap ? full.ToString(0, FullTextCap) : full.ToString();
        if (string.IsNullOrEmpty(row.SessionId))
            row.SessionId = Path.GetFileNameWithoutExtension(filePath);
        return row;
    }

    /// The two sides of the conversation, most recent `maxTurns`, and nothing else.
    public static List<Turn> LoadTurns(string filePath, int maxTurns = 200)
    {
        var turns = new List<Turn>();
        foreach (var line in File.ReadLines(filePath))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonElement obj;
            try { obj = JsonDocument.Parse(line).RootElement; } catch { continue; }

            long? at = Str(obj, "timestamp") is { } s && DateTimeOffset.TryParse(s, out var w)
                ? w.ToUnixTimeMilliseconds() : null;

            var type = Str(obj, "type");
            if (type == "user" && HumanText(obj) is { } human) turns.Add(new Turn("You", human, at));
            else if (type == "assistant" && AssistantText(obj) is { } said) turns.Add(new Turn("Claude", said, at));
        }
        return turns.Count > maxTurns ? turns.GetRange(turns.Count - maxTurns, maxTurns) : turns;
    }

    private static string? Str(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public sealed record Found(string FilePath, string ProjectId, long Size, long Mtime);

    /// Sessions live one directory deep. Anything nested below that is a subagent or
    /// workflow transcript, which is machinery rather than a session anyone had.
    public static List<Found> ListTranscripts(string projectsRoot)
    {
        var found = new List<Found>();
        if (!Directory.Exists(projectsRoot)) return found;

        foreach (var dir in Directory.EnumerateDirectories(projectsRoot))
        {
            foreach (var file in Directory.EnumerateFiles(dir, "*.jsonl"))
            {
                try
                {
                    var info = new FileInfo(file);
                    found.Add(new Found(file, Path.GetFileName(dir), info.Length,
                        new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds()));
                }
                catch (IOException) { /* vanished between listing and stat */ }
            }
        }
        return found;
    }
}
