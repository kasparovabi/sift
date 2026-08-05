using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace SiftWinUI.Core;

public sealed record Appearance(string Id, string Name, ElementTheme Theme, string Accent);

/// WinUI already draws Fluent controls in light or dark, so a theme here is the element
/// theme plus one accent colour, rather than the full palette the WPF build had to define
/// for itself. Mica and the system chrome do the rest.
public static class ThemeService
{
    public static readonly Appearance[] All =
    {
        new("system",   "Follow system", ElementTheme.Default, "#5AC8E8"),
        new("dark",     "Dark",          ElementTheme.Dark,    "#5AC8E8"),
        new("light",    "Light",         ElementTheme.Light,   "#0F6CBD"),
        new("ocean",    "Ocean",         ElementTheme.Dark,    "#38BDF8"),
        new("terminal", "Terminal",      ElementTheme.Dark,    "#C6FF2E"),
    };

    public static Appearance Current { get; private set; } = All[0];

    public static Appearance Named(string? id) => All.FirstOrDefault(a => a.Id == id) ?? All[0];

    public static void Apply(Appearance appearance, FrameworkElement root)
    {
        Current = appearance;
        root.RequestedTheme = appearance.Theme;
        var colour = Parse(appearance.Accent);
        var resources = Application.Current.Resources;
        resources["SiftAccentBrush"] = new SolidColorBrush(colour);
        resources["SystemAccentColor"] = colour;
    }

    public static Color Parse(string hex)
    {
        hex = hex.TrimStart('#');
        return ColorHelper.FromArgb(255,
            Convert.ToByte(hex.Substring(0, 2), 16),
            Convert.ToByte(hex.Substring(2, 2), 16),
            Convert.ToByte(hex.Substring(4, 2), 16));
    }

    private static string SettingsPath => Path.Combine(AppPaths.SupportDir, "appearance.txt");

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
        catch { /* an appearance that will not persist is not worth an error dialog */ }
    }
}
