using System.IO;
using System.Text.Json;

namespace SiftWinUI.Core;

public enum Agent { ClaudeCode, Codex }

public static class Agents
{
    public static string Code(this Agent agent) => agent == Agent.Codex ? "codex" : "claude";

    public static Agent Parse(string? code) => code == "codex" ? Agent.Codex : Agent.ClaudeCode;

    public static string Label(this Agent agent) => agent == Agent.Codex ? "Codex" : "Claude Code";

    /// The executable and the arguments that reopen one session by the id its own transcript
    /// records. Both agents take one, so a result goes back to the tool that wrote it.
    public static string Command(this Agent agent) => agent == Agent.Codex ? "codex" : "claude";

    public static string[] ResumeArguments(this Agent agent, string sessionId) =>
        agent == Agent.Codex ? ["resume", sessionId] : ["--resume", sessionId];
}

/// Codex writes one JSONL per session under `%USERPROFILE%\.codex\sessions\YYYY\MM\DD\`,
/// nested by date rather than by project. Every line is {timestamp, type, payload}: the first
/// is session_meta and carries the working directory and git branch, and the turns arrive as
/// response_item payloads of type message.
public static class Codex
{
    /// Codex prepends its own preamble to the user's words. Left in, every session in a
    /// repository ends up with the same title.
    private static readonly string[] Injected =
    [
        "# AGENTS.md instructions", "<permissions instructions>", "<INSTRUCTIONS>",
        "<environment_context>", "<user_instructions>", "<recommended_plugins>",
    ];

    public static string Root =>
        AppPaths.Resolve("SIFT_CODEX_ROOT")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        ".codex", "sessions");

    /// A thread Codex spawned for itself, the equivalent of Claude Code's sidechains. On the
    /// library this was built against, 64 of 76 rollouts were these; indexing them buries the
    /// sessions someone actually had.
    public static bool IsSubagent(JsonElement meta) =>
        (meta.TryGetProperty("thread_source", out var source) &&
         source.ValueKind == JsonValueKind.String && source.GetString() == "subagent") ||
        (meta.TryGetProperty("source", out _) && meta.TryGetProperty("parent_thread_id", out _));

    /// Returns null when the file is a subagent thread or holds nothing anyone said.
    public static SessionRow? ParseTranscript(string filePath)
    {
        var row = new SessionRow { FilePath = filePath };
        var full = new System.Text.StringBuilder();
        var isSubagent = false;

        foreach (var line in File.ReadLines(filePath))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonElement obj;
            try { obj = JsonDocument.Parse(line).RootElement; }
            catch (JsonException) { continue; }
            if (obj.ValueKind != JsonValueKind.Object) continue;

            var at = Millis(Str(obj, "timestamp"));
            if (at is not null)
            {
                row.StartedAt ??= at;
                row.LastActivity = at;
            }

            if (!obj.TryGetProperty("payload", out var payload) ||
                payload.ValueKind != JsonValueKind.Object) continue;

            switch (Str(obj, "type"))
            {
                case "session_meta":
                    if (IsSubagent(payload)) isSubagent = true;
                    row.SessionId = Str(payload, "id") is { Length: > 0 } id
                        ? id : Str(payload, "session_id");
                    row.Cwd = Blank(Str(payload, "cwd"));
                    row.Entrypoint = Blank(Str(payload, "originator"));
                    if (payload.TryGetProperty("git", out var git) &&
                        git.ValueKind == JsonValueKind.Object)
                        row.GitBranch = Blank(Str(git, "branch"));
                    break;

                case "response_item":
                    var kind = Str(payload, "type");
                    if (kind == "function_call") { row.ToolCallCount++; break; }
                    if (kind != "message") break;

                    // `developer` is the harness talking to the model about sandboxing and
                    // policy, not one of the two sides of the conversation.
                    var role = Str(payload, "role");
                    if (role != "user" && role != "assistant") break;
                    var text = TextOf(payload);
                    if (text.Length == 0) break;
                    if (role == "user" && Injected.Any(text.StartsWith)) break;

                    row.MessageCount++;
                    full.AppendLine(text);
                    if (role == "user" && row.FirstMessage is null)
                        row.FirstMessage = text[..Math.Min(400, text.Length)];
                    break;
            }
        }

        if (isSubagent || row.MessageCount == 0) return null;
        row.FullText = full.ToString();
        row.Title = row.FirstMessage?[..Math.Min(90, row.FirstMessage.Length)];
        if (row.SessionId.Length == 0) row.SessionId = Path.GetFileNameWithoutExtension(filePath);
        row.ProjectId = row.Cwd ?? "codex";
        return row;
    }

    public static List<Scanner.Found> ListTranscripts(string root)
    {
        var found = new List<Scanner.Found>();
        if (!Directory.Exists(root)) return found;

        foreach (var file in Directory.EnumerateFiles(root, "rollout-*.jsonl",
                                                      SearchOption.AllDirectories))
        {
            var info = new FileInfo(file);
            found.Add(new Scanner.Found(file, "codex", info.Length,
                                        new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds()));
        }
        return found;
    }

    /// The conversation, for the reader pane.
    public static List<Turn> LoadTurns(string filePath, int maxTurns = 200)
    {
        var turns = new List<Turn>();
        foreach (var line in File.ReadLines(filePath))
        {
            if (turns.Count >= maxTurns) break;
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonElement obj;
            try { obj = JsonDocument.Parse(line).RootElement; }
            catch (JsonException) { continue; }
            if (obj.ValueKind != JsonValueKind.Object) continue;
            if (Str(obj, "type") != "response_item") continue;
            if (!obj.TryGetProperty("payload", out var payload)) continue;
            if (Str(payload, "type") != "message") continue;

            var role = Str(payload, "role");
            if (role != "user" && role != "assistant") continue;
            var text = TextOf(payload);
            if (text.Length == 0) continue;
            if (role == "user" && Injected.Any(text.StartsWith)) continue;
            turns.Add(new Turn(role, text, Millis(Str(obj, "timestamp"))));
        }
        return turns;
    }

    private static string TextOf(JsonElement payload)
    {
        if (!payload.TryGetProperty("content", out var content)) return "";
        if (content.ValueKind == JsonValueKind.String) return content.GetString()?.Trim() ?? "";
        if (content.ValueKind != JsonValueKind.Array) return "";

        var parts = new List<string>();
        foreach (var block in content.EnumerateArray())
        {
            if (block.ValueKind != JsonValueKind.Object) continue;
            if (Str(block, "type") is not ("input_text" or "output_text" or "text")) continue;
            var text = Str(block, "text");
            if (text.Length > 0) parts.Add(text);
        }
        return string.Join("\n", parts).Trim();
    }

    private static string Str(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? "" : "";

    private static string? Blank(string value) => value.Length == 0 ? null : value;

    private static long? Millis(string timestamp) =>
        DateTimeOffset.TryParse(timestamp, System.Globalization.CultureInfo.InvariantCulture,
                                System.Globalization.DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed.ToUnixTimeMilliseconds() : null;
}
