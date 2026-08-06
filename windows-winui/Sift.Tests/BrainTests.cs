using SiftWinUI.Core;
using Xunit;

namespace SiftWinUI.Tests;

public class ExtractorTests
{
    [Fact]
    public void TheMarkerIsPartOfTheInstruction()
    {
        // If these drift apart, an extraction run stops being recognised as a machine session
        // and the ingester starts feeding the brain its own output.
        Assert.Contains(Extractor.InstructionMarker, Extractor.Instruction);
        Assert.True(Extractor.LooksLikeExtraction("user: " + Extractor.Instruction + " ..."));
        Assert.False(Extractor.LooksLikeExtraction("user: how do I paginate this"));
    }

    [Fact]
    public void AnEnvelopeIsUnwrappedAndPlainTextIsLeftAlone()
    {
        Assert.Equal("{\"atoms\":[]}", Extractor.Unwrap("{\"result\":\"{\\\"atoms\\\":[]}\"}"));
        Assert.Equal("{\"atoms\":[]}", Extractor.Unwrap("  {\"atoms\":[]}  "));
        Assert.Equal("", Extractor.Unwrap("   "));
    }

    [Fact]
    public void JsonSurvivesBeingWrappedInProseOrAFence()
    {
        var fenced = "Here you go:\n```json\n{\"atoms\":[{\"t\":\"D\",\"s\":\"Chose keyset\",\"imp\":8}]}\n```";
        var result = Extractor.Parse(fenced);
        var atom = Assert.Single(result.Atoms);
        Assert.Equal(AtomType.Decision, atom.Type);
        Assert.Equal("Chose keyset", atom.Statement);
        Assert.Equal(8, atom.Importance);
    }

    [Fact]
    public void EntitiesAreReadInEitherShapeAndBadRowsAreDropped()
    {
        var json = """
            {"atoms":[
              {"t":"F","s":"GRDB wraps SQLite","imp":"6","entities":["GRDB",{"n":"SQLite","k":"lib"}]},
              {"t":"F","s":"","imp":9,"entities":["ignored"]}],
             "relations":[{"s":"GRDB","p":"wraps","o":"SQLite"},{"s":"","p":"x","o":"y"}]}
            """;
        var result = Extractor.Parse(json);
        var atom = Assert.Single(result.Atoms);
        Assert.Equal(6, atom.Importance);
        Assert.Equal(new[] { "GRDB", "SQLite" }, atom.Entities);
        var relation = Assert.Single(result.Relations);
        Assert.Equal("wraps", relation.Predicate);
    }

    [Fact]
    public void NonsenseIsEmptyRatherThanAnException()
    {
        Assert.True(Extractor.Parse("not json at all").IsEmpty);
        Assert.True(Extractor.Parse("[1,2,3]").IsEmpty);
        Assert.True(Extractor.Parse("").IsEmpty);
    }
}

public class StreamEventTests
{
    [Fact]
    public void AToolCallSaysWhatItIsActingOn()
    {
        var line = """
            {"type":"assistant","message":{"content":[
              {"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"run"}}]}}
            """;
        Assert.Equal("→ Bash: npm test", StreamEvents.Read(line).Display);
    }

    [Fact]
    public void WhatClaudeSaysComesThrough()
    {
        var line = """
            {"type":"assistant","message":{"content":[{"type":"text","text":"Switched to keyset."}]}}
            """;
        Assert.Equal("Switched to keyset.", StreamEvents.Read(line).Display);
    }

    [Fact]
    public void ToolResultsAreNotWorthShowing()
    {
        var line = """
            {"type":"user","message":{"content":[{"type":"tool_result","content":"exit 0"}]}}
            """;
        Assert.Null(StreamEvents.Read(line).Display);
    }

    [Fact]
    public void TheFinalAnswerIsSeparateFromTheCommentary()
    {
        var line = """
            {"type":"result","subtype":"success","result":"All 12 tests pass.","total_cost_usd":0.0412}
            """;
        var read = StreamEvents.Read(line);
        Assert.Equal("All 12 tests pass.", read.FinalResult);
        Assert.Contains("Done.", read.Display);
        Assert.Contains("0.041", read.Display);
    }

    [Fact]
    public void AFailedRunSaysSoRatherThanReportingDone()
    {
        var read = StreamEvents.Read("""{"type":"result","subtype":"error_max_turns","result":""}""");
        Assert.Contains("error_max_turns", read.Display);
    }

    [Fact]
    public void ALineThatIsNotAnEventIsShownRatherThanSwallowed()
    {
        // Losing this is how a task with a missing claude looks identical to one that worked.
        Assert.Equal("command not found: claude", StreamEvents.Read("command not found: claude").Display);
        Assert.Null(StreamEvents.Read("   ").Display);
        Assert.Equal("{oops", StreamEvents.Read("{oops").Display);
    }

    [Fact]
    public void ALongCommandIsCutRatherThanFloodingThePane()
    {
        var command = new string('x', 400);
        var line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"," +
                   "\"name\":\"Bash\",\"input\":{\"command\":\"" + command + "\"}}]}}";
        var display = StreamEvents.Read(line).Display!;
        Assert.True(display.Length < 200, $"was {display.Length}");
        Assert.EndsWith("…", display);
    }
}

public class BrainStoreTests
{
    private static ExtractionResult Sample() => new(
        [
            new RawAtom(AtomType.Decision, "Switched to keyset pagination", 8, ["Postgres", "orbit-api"]),
            new RawAtom(AtomType.Fact, "Offset pagination degrades past page 200", 6, ["Postgres"]),
        ],
        [new RawRelation("orbit-api", "runs on", "Postgres")]);

    [Fact]
    public void AtomsComeBackRankedAndSearchable()
    {
        using var brain = new BrainStore(":memory:");
        Assert.Equal(2, brain.Ingest(Sample(), "s1", "orbit-api"));

        var all = brain.Atoms();
        Assert.Equal(2, all.Count);
        Assert.Equal("Switched to keyset pagination", all[0].Statement);

        Assert.Single(brain.Atoms("keyset"));
        Assert.Equal(2, brain.Atoms("pagin").Count);
        Assert.Empty(brain.Atoms("kubernetes"));
    }

    [Fact]
    public void AnEntityMentionedTwiceIsOneNode()
    {
        using var brain = new BrainStore(":memory:");
        brain.Ingest(Sample(), "s1", "orbit-api");
        brain.Ingest(new ExtractionResult(
            [new RawAtom(AtomType.Fact, "postgres 16 is installed", 4, ["postgres"])], []), "s2", "other");

        var entities = brain.Entities();
        var postgres = Assert.Single(entities, e => e.Name.Equals("Postgres", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(3, postgres.AtomCount);
        Assert.Equal(3, brain.Atoms(entityId: postgres.Id).Count);
    }

    [Fact]
    public void TwoThingsInOneStatementAreConnected()
    {
        using var brain = new BrainStore(":memory:");
        brain.Ingest(Sample(), "s1", "orbit-api");
        var ids = brain.Entities().Select(e => e.Id).ToList();
        Assert.NotEmpty(brain.Edges(ids));
    }

    [Fact]
    public void ASessionIsOnlyIngestedOnce()
    {
        using var brain = new BrainStore(":memory:");
        Assert.False(brain.AlreadyIngested("s1"));
        brain.MarkIngested("s1");
        Assert.True(brain.AlreadyIngested("s1"));
    }

    [Fact]
    public void IdsStayShort()
    {
        Assert.Equal("0", BrainStore.Base62(0));
        Assert.Equal("Z", BrainStore.Base62(61));
        Assert.Equal("10", BrainStore.Base62(62));
    }
}

public class GraphLayoutTests
{
    private static List<Entity> Entities(int count) =>
        Enumerable.Range(0, count).Select(i => new Entity($"e{i}", $"thing {i}", "thing", i + 1)).ToList();

    [Fact]
    public void EveryNodeLandsInsideTheCanvas()
    {
        var nodes = GraphLayout.Compute(Entities(12), [new GraphEdge("e0", "e1", 3)]);
        Assert.Equal(12, nodes.Count);
        Assert.All(nodes, n =>
        {
            Assert.InRange(n.X, 0.0, 1.0);
            Assert.InRange(n.Y, 0.0, 1.0);
        });
    }

    [Fact]
    public void NoTwoNodesEndUpOnTheSamePoint()
    {
        var nodes = GraphLayout.Compute(Entities(20), []);
        var distinct = nodes.Select(n => (Math.Round(n.X, 3), Math.Round(n.Y, 3))).Distinct().Count();
        Assert.Equal(nodes.Count, distinct);
    }

    [Fact]
    public void TheSameGraphDrawsTheSameWayTwice()
    {
        var edges = new List<GraphEdge> { new("e0", "e3", 2), new("e1", "e2", 1) };
        var first = GraphLayout.Compute(Entities(8), edges);
        var second = GraphLayout.Compute(Entities(8), edges);
        Assert.Equal(first, second);
    }

    [Fact]
    public void ConnectedNodesEndUpCloserThanUnconnectedOnes()
    {
        var entities = Entities(10);
        var nodes = GraphLayout.Compute(entities, [new GraphEdge("e0", "e1", 5)]);
        var byId = nodes.ToDictionary(n => n.Id);
        double Gap(string a, string b) =>
            Math.Sqrt(Math.Pow(byId[a].X - byId[b].X, 2) + Math.Pow(byId[a].Y - byId[b].Y, 2));

        var linked = Gap("e0", "e1");
        var others = nodes.Where(n => n.Id != "e0" && n.Id != "e1")
                          .Average(n => Gap("e0", n.Id));
        Assert.True(linked < others, $"linked {linked:F3} should be under the average {others:F3}");
    }

    [Fact]
    public void AnEmptyGraphIsNotAnError()
    {
        Assert.Empty(GraphLayout.Compute([], []));
        Assert.Single(GraphLayout.Compute(Entities(1), []));
    }
}

public class ProjectFoldingTests
{
    private static Dictionary<string, (int, long?)> Counts(params (string Path, int Count)[] rows) =>
        rows.ToDictionary(r => r.Path, r => (r.Count, (long?)1), StringComparer.OrdinalIgnoreCase);

    [Fact]
    public void HundredsOfOneShotFoldersBecomeOneProject()
    {
        var rows = Enumerable.Range(0, 40)
            .Select(i => ($@"A:\harness\sandbox\clean\run{i}", 1)).ToArray();
        var folded = IndexStore.FoldOneShotSiblings(Counts(rows));
        var only = Assert.Single(folded);
        Assert.Equal(@"A:\harness\sandbox\clean", only.Key);
        Assert.Equal(40, only.Value.Count);
    }

    [Fact]
    public void AFolderOfRealProjectsIsLeftAlone()
    {
        var folded = IndexStore.FoldOneShotSiblings(Counts(
            (@"C:\dev\peri", 40), (@"C:\dev\kiebatch", 22), (@"C:\dev\sift", 31),
            (@"C:\dev\etsy", 12), (@"C:\dev\radar", 9), (@"C:\dev\hermes", 7)));
        Assert.Equal(6, folded.Count);
    }

    [Fact]
    public void AHandfulOfSiblingsIsNotEnoughToFold()
    {
        var folded = IndexStore.FoldOneShotSiblings(Counts(
            (@"C:\dev\a", 1), (@"C:\dev\b", 1), (@"C:\dev\c", 1)));
        Assert.Equal(3, folded.Count);
    }

    [Fact]
    public void ParentStopsAtADriveOrFilesystemRoot()
    {
        Assert.Equal(@"A:\harness", IndexStore.Parent(@"A:\harness\sandbox"));
        Assert.Equal("/Users/alex", IndexStore.Parent("/Users/alex/code"));
        Assert.Null(IndexStore.Parent(@"A:\"));
        Assert.Null(IndexStore.Parent("/Users"));
    }
}
