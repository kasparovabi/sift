using System.Diagnostics;
using System.Text.Json;

namespace SiftWinUI.Core;

public sealed record RawAtom(AtomType Type, string Statement, int Importance, List<string> Entities);

public sealed record RawRelation(string Subject, string Predicate, string Object);

public sealed record ExtractionResult(List<RawAtom> Atoms, List<RawRelation> Relations)
{
    public static readonly ExtractionResult Empty = new([], []);
    public bool IsEmpty => Atoms.Count == 0 && Relations.Count == 0;
}

public sealed record Extraction(ExtractionResult Result, double CostUsd);

/// Turns a finished session into durable statements by asking Claude for them. This is the
/// one part of Sift that sends transcript text over the network, so nothing here runs unless
/// the user has switched knowledge extraction on.
public sealed class Extractor(string claudePath)
{
    /// Has to stay a literal substring of Instruction. If the two drift apart, extraction
    /// runs stop being recognised as machine sessions and the ingester starts feeding its
    /// own output back into itself.
    public const string InstructionMarker = "Extract DURABLE, REUSABLE knowledge";

    public const string Instruction =
        InstructionMarker + " from the Claude Code session transcript below. " +
        "Return valid JSON only, with no other text. Schema: " +
        "{\"atoms\":[{\"t\":\"F|D|P|H|V\",\"s\":\"one-line claim\",\"imp\":1-10," +
        "\"entities\":[\"name\"]}], " +
        "\"relations\":[{\"s\":\"subject\",\"p\":\"predicate\",\"o\":\"object\"}]}. " +
        "Skip small talk, raw error output, and anything trivial. Transcript:";

    public const int MaxTranscriptChars = 60_000;

    public static bool LooksLikeExtraction(string text) =>
        text.Contains(InstructionMarker, StringComparison.Ordinal);

    public async Task<Extraction> Extract(string transcript, CancellationToken token)
    {
        var clipped = transcript.Length > MaxTranscriptChars
            ? transcript[..MaxTranscriptChars] : transcript;
        var raw = await RunClaude(Instruction + "\n" + clipped, token);
        var json = Unwrap(raw);
        var result = json.Trim().Length == 0 ? ExtractionResult.Empty : Parse(json);
        return new Extraction(result, CostOf(raw));
    }

    /// The prompt goes in on stdin. As an argument it is a whole transcript, which blows past
    /// the Windows command line limit and fails with "the filename or extension is too long".
    /// PowerShell rather than the executable directly, because on Windows `claude` is a .ps1
    /// and CreateProcess cannot run one.
    private async Task<string> RunClaude(string prompt, CancellationToken token)
    {
        var info = new ProcessStartInfo("powershell.exe")
        {
            Arguments = "-NoProfile -Command \"" + Launcher.Utf8Prelude + "& " +
                        Launcher.Quote(claudePath) + " -p --output-format json\"",
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            StandardInputEncoding = System.Text.Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        using var process = Process.Start(info);
        if (process is null) return "";
        // Read while writing. A transcript is larger than the pipe buffer, so writing it all
        // before reading anything deadlocks the moment claude answers early.
        var reading = process.StandardOutput.ReadToEndAsync(token);
        await process.StandardInput.WriteAsync(prompt.AsMemory(), token);
        process.StandardInput.Close();
        var output = await reading;
        await process.WaitForExitAsync(token);
        return output;
    }

    /// What the run cost, straight from the envelope, so a backlog of a thousand sessions can
    /// say what it is spending instead of finding out afterwards.
    public static double CostOf(string raw)
    {
        try
        {
            using var doc = JsonDocument.Parse(raw.Trim());
            return doc.RootElement.ValueKind == JsonValueKind.Object &&
                   doc.RootElement.TryGetProperty("total_cost_usd", out var cost) &&
                   cost.ValueKind == JsonValueKind.Number
                ? cost.GetDouble() : 0;
        }
        catch (JsonException) { return 0; }
    }

    /// A `claude --output-format json` reply is an envelope with the answer under "result".
    public static string Unwrap(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return "";
        try
        {
            using var doc = JsonDocument.Parse(trimmed);
            if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                doc.RootElement.TryGetProperty("result", out var result) &&
                result.ValueKind == JsonValueKind.String)
                return result.GetString() ?? "";
        }
        catch (JsonException) { }
        return trimmed;
    }

    /// Models wrap JSON in prose or a code fence often enough that trusting the reply to be
    /// bare JSON loses extractions silently. Take the outermost braced span instead.
    public static string CleanJson(string text)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        return start >= 0 && end > start ? text[start..(end + 1)] : text.Trim();
    }

    public static ExtractionResult Parse(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(CleanJson(json)); }
        catch (JsonException) { return ExtractionResult.Empty; }

        using (doc)
        {
            var atoms = new List<RawAtom>();
            var relations = new List<RawRelation>();
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return ExtractionResult.Empty;

            if (root.TryGetProperty("atoms", out var atomArray) &&
                atomArray.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in atomArray.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;
                    var statement = Str(item, "s");
                    if (statement.Length == 0) continue;
                    var entities = new List<string>();
                    if (item.TryGetProperty("entities", out var list) &&
                        list.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var entity in list.EnumerateArray())
                        {
                            var name = entity.ValueKind == JsonValueKind.String
                                ? entity.GetString()
                                : entity.ValueKind == JsonValueKind.Object ? Str(entity, "n") : null;
                            if (!string.IsNullOrWhiteSpace(name)) entities.Add(name!);
                        }
                    }
                    atoms.Add(new RawAtom(AtomTypes.Parse(Str(item, "t")), statement,
                                          Int(item, "imp", 5), entities));
                }
            }

            if (root.TryGetProperty("relations", out var relArray) &&
                relArray.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in relArray.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;
                    var subject = Str(item, "s");
                    var predicate = Str(item, "p");
                    var obj = Str(item, "o");
                    if (subject.Length == 0 || obj.Length == 0) continue;
                    relations.Add(new RawRelation(subject, predicate, obj));
                }
            }
            return new ExtractionResult(atoms, relations);
        }
    }

    private static string Str(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()!.Trim() : "";

    private static int Int(JsonElement element, string name, int fallback)
    {
        if (!element.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
        if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), out var parsed))
            return parsed;
        return fallback;
    }
}
