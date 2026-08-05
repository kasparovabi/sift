using System.IO;
using System.Windows;

namespace Sift;

public partial class App : Application
{
    /// `Sift.exe --shot out.png` renders the window to a file and quits. A Windows box
    /// reached over SSH has no interactive desktop, so screen capture returns nothing;
    /// this is how the interface can be looked at without sitting in front of it.
    public static string? ShotPath { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        for (var i = 0; i < e.Args.Length - 1; i++)
            if (e.Args[i] is "--shot") ShotPath = Path.GetFullPath(e.Args[i + 1]);
        base.OnStartup(e);
    }
}
