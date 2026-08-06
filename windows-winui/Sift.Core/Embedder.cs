using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;

namespace SiftWinUI.Core;

/// Where vectors come from. Sift ships no model of its own, and Anthropic has no embeddings
/// API, so a Claude subscription cannot produce these. What it can use is a model already
/// running on the machine, which keeps the download at zero and the text where it is.
public sealed record EmbeddingBackend(string Name, string Endpoint, string Model, bool OpenAICompatible)
{
    /// Vectors from two models are not comparable, so this is stored beside every one and a
    /// change throws them away rather than silently mixing two coordinate systems.
    public string Fingerprint => $"{Name}:{Model}";
}

public sealed class EmbeddingException(string message) : Exception(message);

public sealed class LocalEmbedder(EmbeddingBackend backend, HttpClient? http = null)
{
    private readonly HttpClient _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(120) };

    public string Fingerprint => backend.Fingerprint;

    public async Task<List<float[]>> Embed(IReadOnlyList<string> texts, CancellationToken token)
    {
        if (texts.Count == 0) return [];
        var response = await _http.PostAsJsonAsync(backend.Endpoint,
            new { model = backend.Model, input = texts }, token);
        if (!response.IsSuccessStatusCode)
            throw new EmbeddingException($"HTTP {(int)response.StatusCode}");
        var body = await response.Content.ReadAsStringAsync(token);
        return Vectors(body, backend.OpenAICompatible);
    }

    /// Both shapes, read leniently. A server that puts numbers in the right place is good
    /// enough; rejecting one that adds fields buys nothing.
    public static List<float[]> Vectors(string body, bool openAICompatible)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(body).RootElement; }
        catch (JsonException) { throw new EmbeddingException("not JSON"); }
        if (root.ValueKind != JsonValueKind.Object) throw new EmbeddingException("not an object");

        if (openAICompatible)
        {
            if (!root.TryGetProperty("data", out var rows) || rows.ValueKind != JsonValueKind.Array)
                throw new EmbeddingException("no data array");
            return rows.EnumerateArray()
                .Select(r => r.TryGetProperty("embedding", out var v) ? Floats(v) : null)
                .Where(v => v is not null).Select(v => v!).ToList();
        }
        if (root.TryGetProperty("embeddings", out var many) && many.ValueKind == JsonValueKind.Array)
            return many.EnumerateArray().Select(Floats).Where(v => v is not null).Select(v => v!).ToList();
        // The legacy /api/embeddings answers with one vector under `embedding`.
        if (root.TryGetProperty("embedding", out var one) && Floats(one) is { } single)
            return [single];
        throw new EmbeddingException("no embeddings");
    }

    private static float[]? Floats(JsonElement element) =>
        element.ValueKind == JsonValueKind.Array
            ? element.EnumerateArray().Where(n => n.ValueKind == JsonValueKind.Number)
                     .Select(n => (float)n.GetDouble()).ToArray()
            : null;
}

/// Finds a model server that is already running. Nothing is installed and nothing downloaded.
public static class EmbeddingDiscovery
{
    public static readonly (string Name, string Probe, string Embed, bool OpenAI)[] Candidates =
    [
        ("Ollama", "http://127.0.0.1:11434/api/tags", "http://127.0.0.1:11434/api/embed", false),
        ("LM Studio", "http://127.0.0.1:1234/v1/models", "http://127.0.0.1:1234/v1/embeddings", true),
    ];

    /// A chat model will answer an embedding request on some servers and hand back something
    /// that ranks like noise, which is worse than having no semantic search at all.
    public static bool LooksLikeEmbeddingModel(string name)
    {
        var lowered = name.ToLowerInvariant();
        return new[] { "embed", "bge", "gte", "e5", "minilm", "nomic" }.Any(lowered.Contains);
    }

    public static List<string> Models(string body)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(body).RootElement; }
        catch (JsonException) { return []; }
        if (root.ValueKind != JsonValueKind.Object) return [];

        if (root.TryGetProperty("models", out var ollama) && ollama.ValueKind == JsonValueKind.Array)
            return ollama.EnumerateArray()
                .Select(r => Str(r, "name") is { Length: > 0 } n ? n : Str(r, "model"))
                .Where(n => n.Length > 0).ToList();
        if (root.TryGetProperty("data", out var openAI) && openAI.ValueKind == JsonValueKind.Array)
            return openAI.EnumerateArray().Select(r => Str(r, "id")).Where(n => n.Length > 0).ToList();
        return [];
    }

    public static async Task<EmbeddingBackend?> Discover(HttpClient? http = null,
                                                         CancellationToken token = default)
    {
        var client = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        foreach (var candidate in Candidates)
        {
            try
            {
                var response = await client.GetAsync(candidate.Probe, token);
                if (!response.IsSuccessStatusCode) continue;
                var models = Models(await response.Content.ReadAsStringAsync(token));
                var model = models.FirstOrDefault(LooksLikeEmbeddingModel);
                if (model is null) continue;
                return new EmbeddingBackend(candidate.Name, candidate.Embed, model, candidate.OpenAI);
            }
            catch (Exception) { /* nothing is listening there, try the next one */ }
        }
        return null;
    }

    private static string Str(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? "" : "";
}

public static class Vectors
{
    public static double Cosine(float[] a, float[] b)
    {
        var n = Math.Min(a.Length, b.Length);
        if (n == 0) return 0;
        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < n; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
        return na > 0 && nb > 0 ? dot / (Math.Sqrt(na) * Math.Sqrt(nb)) : 0;
    }

    public static byte[] ToBytes(float[] vector)
    {
        var bytes = new byte[vector.Length * sizeof(float)];
        Buffer.BlockCopy(vector, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    public static float[] FromBytes(byte[] bytes)
    {
        if (bytes.Length == 0 || bytes.Length % sizeof(float) != 0) return [];
        var vector = new float[bytes.Length / sizeof(float)];
        Buffer.BlockCopy(bytes, 0, vector, 0, bytes.Length);
        return vector;
    }

    /// Reciprocal rank fusion. Two rankings that disagree about scale still agree about
    /// order, so ranks are what get combined and something both put near the top wins.
    public static List<string> Fuse(IReadOnlyList<string> lexical, IReadOnlyList<string> semantic,
                                    double k = 60)
    {
        var score = new Dictionary<string, double>();
        for (var i = 0; i < lexical.Count; i++)
            score[lexical[i]] = score.GetValueOrDefault(lexical[i]) + 1 / (k + i + 1);
        for (var i = 0; i < semantic.Count; i++)
            score[semantic[i]] = score.GetValueOrDefault(semantic[i]) + 1 / (k + i + 1);
        return score.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.Ordinal)
                    .Select(p => p.Key).ToList();
    }
}
