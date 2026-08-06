using System.Globalization;
using System.Text.Json;

namespace SiftWinUI.Core;

public sealed record StreamEvent(string? Display, string? FinalResult);

/// Turns one line of `claude --output-format stream-json` into something worth putting on
/// screen. The raw events carry far more than anyone wants to read: what matters while a
/// task runs is which tool is being used on what, and what Claude is saying.
public static class StreamEvents
{
    public static readonly StreamEvent Nothing = new(null, null);

    public static StreamEvent Read(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return Nothing;
        // A non-JSON line is claude complaining on its own terms; show it rather than
        // swallowing it, because that is usually the reason a task produced nothing.
        if (trimmed[0] != '{') return new StreamEvent(trimmed, null);

        JsonDocument doc;
        try { doc = JsonDocument.Parse(trimmed); }
        catch (JsonException) { return new StreamEvent(trimmed, null); }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return Nothing;
            var type = Text(root, "type");

            if (type == "system")
                return Text(root, "subtype") == "init" ? new StreamEvent("Started.", null) : Nothing;

            if (type == "result")
            {
                var result = Text(root, "result");
                // A dollar amount written with the machine's decimal separator reads as a
                // different number in half the world, so the money stays invariant.
                var cost = root.TryGetProperty("total_cost_usd", out var c) && c.ValueKind == JsonValueKind.Number
                    ? "  ($" + c.GetDouble().ToString("F3", CultureInfo.InvariantCulture) + ")" : "";
                var subtype = Text(root, "subtype");
                var closing = subtype is "success" or "" ? $"Done.{cost}" : $"Ended: {subtype}.{cost}";
                return new StreamEvent(closing, result);
            }

            if (type != "assistant" && type != "user") return Nothing;
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content)) return Nothing;

            if (content.ValueKind == JsonValueKind.String)
                return type == "assistant" ? new StreamEvent(content.GetString(), null) : Nothing;
            if (content.ValueKind != JsonValueKind.Array) return Nothing;

            var lines = new List<string>();
            foreach (var block in content.EnumerateArray())
            {
                if (block.ValueKind != JsonValueKind.Object) continue;
                switch (Text(block, "type"))
                {
                    case "text" when type == "assistant":
                        var said = Text(block, "text");
                        if (said.Length > 0) lines.Add(said);
                        break;
                    case "tool_use":
                        lines.Add("→ " + Tool(block));
                        break;
                }
            }
            return lines.Count == 0 ? Nothing : new StreamEvent(string.Join("\n", lines), null);
        }
    }

    /// A tool call as one line: the name, plus whichever input field says what it is acting
    /// on. Printing the whole input turns a file edit into a screenful.
    private static string Tool(JsonElement block)
    {
        var name = Text(block, "name");
        if (name.Length == 0) name = "tool";
        if (!block.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object)
            return name;

        foreach (var key in new[] { "command", "file_path", "path", "pattern", "query", "url", "prompt" })
        {
            var value = Text(input, key);
            if (value.Length == 0) continue;
            var single = value.ReplaceLineEndings(" ").Trim();
            return $"{name}: {(single.Length > 140 ? single[..140] + "…" : single)}";
        }
        return name;
    }

    private static string Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? "" : "";
}
