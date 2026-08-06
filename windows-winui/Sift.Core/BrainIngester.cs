using System.IO;

namespace SiftWinUI.Core;

/// Extraction sends transcript text to Claude, so it stays off until the user turns it on.
/// A fresh install never sends anything anywhere.
public static class Preferences
{
    private static string ExtractionPath => Path.Combine(AppPaths.SupportDir, "knowledge.txt");

    public static bool KnowledgeExtractionEnabled
    {
        get
        {
            try { return File.Exists(ExtractionPath) && File.ReadAllText(ExtractionPath).Trim() == "1"; }
            catch { return false; }
        }
        set
        {
            try
            {
                Directory.CreateDirectory(AppPaths.SupportDir);
                File.WriteAllText(ExtractionPath, value ? "1" : "0");
            }
            catch { }
        }
    }

    /// Small enough that a backlog of thousands of sessions cannot fire all at once and
    /// spend a day of tokens in a minute.
    public const int ExtractionsPerTick = 2;
}

public sealed record IngestOutcome(int Sessions, int Atoms);

/// Feeds finished sessions through the extractor into the brain, a couple at a time.
public sealed class BrainIngester(BrainStore brain, IndexStore index, Extractor extractor)
{
    public async Task<IngestOutcome> Tick(CancellationToken token,
                                          int limit = Preferences.ExtractionsPerTick)
    {
        if (!Preferences.KnowledgeExtractionEnabled) return new IngestOutcome(0, 0);

        var sessions = 0;
        var atoms = 0;
        foreach (var hit in index.Search("", null, null, 400))
        {
            if (token.IsCancellationRequested || sessions >= limit) break;
            if (brain.AlreadyIngested(hit.SessionId)) continue;

            string transcript;
            try { transcript = ReadTranscript(hit.FilePath); }
            catch (IOException) { continue; }

            // An extraction run is itself a session with a transcript. Ingesting one feeds
            // the brain's own output back into it, so it is marked done and skipped.
            if (transcript.Length < 200 || Extractor.LooksLikeExtraction(transcript))
            {
                brain.MarkIngested(hit.SessionId);
                continue;
            }

            var result = await extractor.Extract(transcript, token);
            atoms += brain.Ingest(result, hit.SessionId, hit.ProjectId);
            brain.MarkIngested(hit.SessionId);
            sessions++;
        }
        return new IngestOutcome(sessions, atoms);
    }

    public static string ReadTranscript(string filePath)
    {
        var turns = Scanner.LoadTurns(filePath, 400);
        return string.Join("\n\n", turns.Select(t => $"{t.Role}: {t.Text}"));
    }
}
