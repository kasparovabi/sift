using System.IO;
using System.Windows;
using System.Windows.Media;

namespace Sift.Core;

public sealed record Theme(
    string Id, string Name, string Blurb,
    string Base, string Surface, string SurfaceHi, string Line,
    string TextMain, string TextDim, string Accent, string Hot,
    string FontFamily);

/// The same five designs the macOS app offers. Views bind to named brushes with
/// DynamicResource, so switching swaps the brushes in place and everything repaints.
public static class ThemeManager
{
    public static readonly Theme[] All =
    {
        new("system", "System", "Windows dark, neutral.",
            "#1F1F1F", "#2A2A2A", "#353535", "#3F3F3F",
            "#EAEAEA", "#9C9C9C", "#4CC2FF", "#7FD962", "Segoe UI Variable Text, Segoe UI"),
        new("graphite", "Graphite", "Neutral dark, low colour.",
            "#1C1D20", "#26282C", "#33363C", "#3F4349",
            "#E7E9EC", "#9AA1AA", "#8EA3C4", "#DFB347", "Segoe UI Variable Text, Segoe UI"),
        new("ocean", "Ocean", "Deep blue with soft edges.",
            "#0E1A26", "#172A3A", "#22394D", "#2D4C66",
            "#DCECF5", "#8AABC0", "#5AC8E8", "#C6FF2E", "Segoe UI Variable Text, Segoe UI"),
        new("paper", "Paper", "Light and warm, for reading.",
            "#F6F2E9", "#FDFBF6", "#EFE7D8", "#D8CFBC",
            "#2E2A24", "#6D6557", "#9A5B2C", "#9A7B12", "Georgia, Segoe UI"),
        new("terminal", "Terminal", "Phosphor green, monospaced.",
            "#080A04", "#10140A", "#18200E", "#46502A",
            "#BFE84A", "#7A9438", "#C6FF2E", "#F5E000", "Cascadia Mono, Consolas"),
    };

    public static Theme Current { get; private set; } = All[2];

    public static Theme Named(string? id) =>
        All.FirstOrDefault(t => t.Id == id) ?? All[2];

    public static void Apply(Theme theme)
    {
        Current = theme;
        var r = Application.Current.Resources;
        Set(r, "Base", theme.Base);
        Set(r, "Surface", theme.Surface);
        Set(r, "SurfaceHi", theme.SurfaceHi);
        Set(r, "Line", theme.Line);
        Set(r, "TextMain", theme.TextMain);
        Set(r, "TextDim", theme.TextDim);
        Set(r, "Accent", theme.Accent);
        Set(r, "Hot", theme.Hot);
        r["AppFont"] = new FontFamily(theme.FontFamily);
    }

    private static void Set(ResourceDictionary r, string key, string hex) =>
        r[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));

    private static string SettingsPath =>
        Path.Combine(AppPaths.SupportDir, "settings.txt");

    public static string? LoadSavedId()
    {
        try { return File.Exists(SettingsPath) ? File.ReadAllText(SettingsPath).Trim() : null; }
        catch { return null; }
    }

    public static void Save(string id)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.SupportDir);
            File.WriteAllText(SettingsPath, id);
        }
        catch { /* a theme that will not persist is not worth an error dialog */ }
    }
}
