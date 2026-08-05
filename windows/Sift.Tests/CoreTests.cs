using System.IO;
using System.Text.Json;
using Sift.Core;
using Xunit;

namespace Sift.Tests;

public sealed class ScannerTests
{
    private static JsonElement Parse(string json) => JsonDocument.Parse(json).RootElement;

    [Fact]
    public void ToolResultsAndInjectedRemindersAreNotUserMessages()
    {
        Assert.Null(Scanner.HumanText(Parse(
            """{"message":{"content":[{"type":"tool_result","content":"exit 0"}]}}""")));
        Assert.Null(Scanner.HumanText(Parse(
            """{"message":{"content":"<system-reminder>be careful</system-reminder>"}}""")));
        Assert.Null(Scanner.HumanText(Parse(
            """{"message":{"content":"<local-command-stdout>ok</local-command-stdout>"}}""")));
        Assert.Null(Scanner.HumanText(Parse("""{"isMeta":true,"message":{"content":"hi"}}""")));
        Assert.Equal("real question", Scanner.HumanText(Parse(
            """{"message":{"content":"real question"}}""")));
    }

    [Fact]
    public void ATurnThatIsOnlyAToolCallHasNothingToShow()
    {
        Assert.Null(Scanner.AssistantText(Parse(
            """{"message":{"content":[{"type":"tool_use","name":"Bash"}]}}""")));
        Assert.Equal("ok", Scanner.AssistantText(Parse(
            """{"message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash"}]}}""")));
    }

    [Fact]
    public void ATranscriptYieldsOnlyWhatTheTwoSidesSaid()
    {
        var file = Fixture.WriteTranscript(out var dir);
        try
        {
            var row = Scanner.ParseTranscript(file);
            Assert.Equal("s1", row.SessionId);
            Assert.Equal("/Users/alex/code/orbit-api", row.Cwd);
            Assert.Equal("main", row.GitBranch);
            Assert.Equal("Cursor pagination for events", row.Title);
            Assert.Equal(2, row.MessageCount);
            Assert.Equal(1, row.ToolCallCount);
            Assert.Contains("keyset pagination", row.FullText);
            Assert.DoesNotContain("system-reminder", row.FullText);

            var turns = Scanner.LoadTurns(file);
            Assert.Equal(new[] { "You", "Claude" }, turns.Select(t => t.Role));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void SubagentTranscriptsStayOutOfTheIndex()
    {
        Fixture.WriteTranscript(out var dir);
        try
        {
            var nested = Path.Combine(dir, "projects", "-Users-alex-code-orbit-api", "sub", "workflows");
            Directory.CreateDirectory(nested);
            File.WriteAllText(Path.Combine(nested, "agent-1.jsonl"), "{}\n");

            var found = Scanner.ListTranscripts(Path.Combine(dir, "projects"));
            Assert.Single(found);
            Assert.EndsWith("s1.jsonl", found[0].FilePath);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void ProjectDirectoryNamesDecodeBackToSomethingReadable()
    {
        Assert.Equal("/Users/alex/code/orbit/api", Scanner.DecodeProjectDir("-Users-alex-code-orbit-api"));
        Assert.Equal("orbit-api", Scanner.DisplayName("/Users/alex/code/orbit-api"));
        Assert.Equal("code", Scanner.DisplayName("/Users/alex/code/"));
        Assert.Equal("app", Scanner.DisplayName(@"C:\code\app"));
    }
}

public sealed class IndexStoreTests
{
    [Fact]
    public void SearchRanksSnippetsAndMatchesPrefixes()
    {
        var file = Fixture.WriteTranscript(out var dir);
        try
        {
            using var store = new IndexStore(":memory:");
            var result = Indexer.Reindex(store, Path.Combine(dir, "projects"));
            Assert.Equal(1, result.Total);
            Assert.Equal(1, result.Indexed);

            var hits = store.Search("pagination");
            Assert.Single(hits);
            Assert.Contains("pagination", hits[0].Snippet, StringComparison.OrdinalIgnoreCase);

            Assert.Single(store.Search("pagin"));
            Assert.Empty(store.Search("kubernetes"));
            Assert.Single(store.Search(""));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void ARescanNeitherDuplicatesNorRereadsUnchangedFiles()
    {
        var file = Fixture.WriteTranscript(out var dir);
        try
        {
            using var store = new IndexStore(":memory:");
            var projects = Path.Combine(dir, "projects");
            Indexer.Reindex(store, projects);

            var second = Indexer.Reindex(store, projects);
            Assert.Equal(0, second.Indexed);
            Assert.Equal(1, store.Count());
            Assert.Single(store.Search("pagination"));

            File.WriteAllText(file,
                """{"type":"user","sessionId":"s1","cwd":"/Users/alex/code/orbit-api","timestamp":"2026-08-02T10:00:00.000Z","message":{"role":"user","content":"a different subject: kubernetes"}}""" + "\n");
            var third = Indexer.Reindex(store, projects);
            Assert.Equal(1, third.Indexed);
            Assert.Equal(1, store.Count());
            Assert.Empty(store.Search("pagination"));
            Assert.Single(store.Search("kubernetes"));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void ADeletedTranscriptLeavesTheIndex()
    {
        var file = Fixture.WriteTranscript(out var dir);
        try
        {
            using var store = new IndexStore(":memory:");
            var projects = Path.Combine(dir, "projects");
            Indexer.Reindex(store, projects);
            File.Delete(file);
            var result = Indexer.Reindex(store, projects);
            Assert.Equal(1, result.Removed);
            Assert.Equal(0, store.Count());
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void AQueryCannotBeASyntaxError()
    {
        Assert.Equal("\"rate\"* AND \"limiter\"*", IndexStore.FtsQuery("rate limiter"));
        Assert.Equal("\"unbalanced\"*", IndexStore.FtsQuery("\"unbalanced"));
        Assert.Equal("\"\"", IndexStore.FtsQuery("   "));

        using var store = new IndexStore(":memory:");
        var ex = Record.Exception(() => store.Search("a \"b* (c"));
        Assert.Null(ex);
    }
}

public sealed class LauncherTests
{
    [Fact]
    public void PathsWithQuotesCannotBreakOutOfTheCommand()
    {
        Assert.Equal("'it''s'", Launcher.Quote("it's"));
        var command = Launcher.ResumeCommand("claude", @"C:\code\it's", "abc-1");
        Assert.Contains(@"Set-Location 'C:\code\it''s'", command);
        Assert.Contains("--resume 'abc-1'", command);
    }

    [Fact]
    public void WithoutASessionItOpensAFreshOne()
    {
        var command = Launcher.ResumeCommand("claude", @"C:\code", null);
        Assert.DoesNotContain("--resume", command);
        Assert.Contains("& 'claude'", command);
    }
}

public sealed class ThemeTests
{
    [Fact]
    public void EveryThemeIsListedOnceAndHasCopy()
    {
        var ids = ThemeManager.All.Select(t => t.Id).ToArray();
        Assert.Equal(ids.Length, ids.Distinct().Count());
        Assert.True(ThemeManager.All.Length >= 4);
        Assert.All(ThemeManager.All, t =>
        {
            Assert.False(string.IsNullOrWhiteSpace(t.Name));
            Assert.False(string.IsNullOrWhiteSpace(t.Blurb));
        });
    }

    [Fact]
    public void ThemesAreActuallyDifferentFromEachOther()
    {
        var backgrounds = ThemeManager.All.Select(t => t.Base).Distinct().Count();
        Assert.Equal(ThemeManager.All.Length, backgrounds);
    }

    [Fact]
    public void AnUnknownIdFallsBackInsteadOfFailing()
    {
        Assert.Equal("ocean", ThemeManager.Named(null).Id);
        Assert.Equal("ocean", ThemeManager.Named("wasteland").Id);
        Assert.Equal("paper", ThemeManager.Named("paper").Id);
    }
}

public sealed class AppPathsTests
{
    [Fact]
    public void AnOverrideRedirectsAndBlankCountsAsUnset()
    {
        var env = new Dictionary<string, string> { [AppPaths.SupportDirKey] = @"C:\tmp\demo" };
        Assert.Equal(@"C:\tmp\demo", AppPaths.Resolve(AppPaths.SupportDirKey, env));

        env[AppPaths.SupportDirKey] = "   ";
        Assert.Null(AppPaths.Resolve(AppPaths.SupportDirKey, env));
        Assert.Null(AppPaths.Resolve(AppPaths.SupportDirKey, new Dictionary<string, string>()));
    }
}

internal static class Fixture
{
    /// One transcript holding a real exchange, a tool-only assistant turn, a tool result
    /// and an injected reminder, so every filtering rule has something to bite on.
    public static string WriteTranscript(out string dir)
    {
        dir = Path.Combine(Path.GetTempPath(), "sift-" + Guid.NewGuid().ToString("N"));
        var projectDir = Path.Combine(dir, "projects", "-Users-alex-code-orbit-api");
        Directory.CreateDirectory(projectDir);
        var file = Path.Combine(projectDir, "s1.jsonl");
        File.WriteAllLines(file, new[]
        {
            """{"type":"user","sessionId":"s1","cwd":"/Users/alex/code/orbit-api","gitBranch":"main","entrypoint":"cli","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"offset pagination is slow past page 200"}}""",
            """{"type":"assistant","timestamp":"2026-08-01T10:00:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Switched to keyset pagination."}]}}""",
            """{"type":"assistant","timestamp":"2026-08-01T10:00:25.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}""",
            """{"type":"user","timestamp":"2026-08-01T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"exit 0"}]}}""",
            """{"type":"user","timestamp":"2026-08-01T10:00:40.000Z","message":{"role":"user","content":"<system-reminder>be careful</system-reminder>"}}""",
            """{"type":"ai-title","title":"Cursor pagination for events"}""",
        });
        return file;
    }
}
