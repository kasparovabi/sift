namespace SiftWinUI.Core;

public sealed record NodePosition(string Id, string Label, int Weight, double X, double Y);

/// Force-directed placement for the knowledge graph. Deterministic: the seed comes from the
/// node id, so the same graph draws the same way twice and a redraw does not reshuffle
/// everything the user was just looking at.
public static class GraphLayout
{
    public static List<NodePosition> Compute(
        IReadOnlyList<Entity> entities, IReadOnlyList<GraphEdge> edges, int iterations = 220)
    {
        var count = entities.Count;
        if (count == 0) return [];
        if (count == 1) return [new NodePosition(entities[0].Id, entities[0].Name,
                                                 entities[0].AtomCount, 0.5, 0.5)];

        var index = new Dictionary<string, int>(count);
        var x = new double[count];
        var y = new double[count];
        for (var i = 0; i < count; i++)
        {
            index[entities[i].Id] = i;
            // A ring start beats random placement: no two nodes begin on top of each other,
            // which is the case the repulsion term cannot recover from.
            var angle = 2 * Math.PI * i / count;
            var radius = 0.30 + 0.12 * ((Hash(entities[i].Id) % 100) / 100.0);
            x[i] = 0.5 + radius * Math.Cos(angle);
            y[i] = 0.5 + radius * Math.Sin(angle);
        }

        var links = new List<(int A, int B, double Strength)>();
        foreach (var edge in edges)
        {
            if (!index.TryGetValue(edge.FromId, out var a)) continue;
            if (!index.TryGetValue(edge.ToId, out var b)) continue;
            if (a == b) continue;
            links.Add((a, b, Math.Min(edge.Weight, 5) / 5.0));
        }

        var fx = new double[count];
        var fy = new double[count];
        var repulsion = 0.9 / count;

        for (var step = 0; step < iterations; step++)
        {
            Array.Clear(fx);
            Array.Clear(fy);

            for (var i = 0; i < count; i++)
            {
                for (var j = i + 1; j < count; j++)
                {
                    var dx = x[i] - x[j];
                    var dy = y[i] - y[j];
                    var distanceSquared = dx * dx + dy * dy + 0.0001;
                    var force = repulsion / distanceSquared;
                    var distance = Math.Sqrt(distanceSquared);
                    fx[i] += force * dx / distance; fy[i] += force * dy / distance;
                    fx[j] -= force * dx / distance; fy[j] -= force * dy / distance;
                }
            }

            foreach (var (a, b, strength) in links)
            {
                var dx = x[b] - x[a];
                var dy = y[b] - y[a];
                var distance = Math.Sqrt(dx * dx + dy * dy) + 0.0001;
                var pull = 0.02 * strength * distance;
                fx[a] += pull * dx / distance; fy[a] += pull * dy / distance;
                fx[b] -= pull * dx / distance; fy[b] -= pull * dy / distance;
            }

            var cooling = 0.9 * (1.0 - (double)step / iterations) + 0.02;
            for (var i = 0; i < count; i++)
            {
                x[i] += Math.Clamp(fx[i] * cooling, -0.05, 0.05) + (0.5 - x[i]) * 0.004;
                y[i] += Math.Clamp(fy[i] * cooling, -0.05, 0.05) + (0.5 - y[i]) * 0.004;
            }
        }

        return Normalize(entities, x, y);
    }

    /// Rescale into 0..1 so the view can map straight onto its own size, whatever the forces
    /// happened to settle on.
    private static List<NodePosition> Normalize(IReadOnlyList<Entity> entities, double[] x, double[] y)
    {
        double minX = x.Min(), maxX = x.Max(), minY = y.Min(), maxY = y.Max();
        var spanX = Math.Max(maxX - minX, 0.0001);
        var spanY = Math.Max(maxY - minY, 0.0001);
        var result = new List<NodePosition>(entities.Count);
        for (var i = 0; i < entities.Count; i++)
        {
            result.Add(new NodePosition(
                entities[i].Id, entities[i].Name, entities[i].AtomCount,
                0.05 + 0.90 * (x[i] - minX) / spanX,
                0.05 + 0.90 * (y[i] - minY) / spanY));
        }
        return result;
    }

    private static int Hash(string text)
    {
        var hash = 17;
        foreach (var c in text) hash = unchecked(hash * 31 + c);
        return Math.Abs(hash);
    }
}
