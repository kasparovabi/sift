using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Sift.Core;

namespace Sift;

public sealed class ResultItem
{
    public required SearchHit Hit { get; init; }
    public string Title => Hit.Title;
    public string Line => Hit.Snippet ?? Hit.Preview.Replace('\n', ' ');
    public string Meta =>
        string.Join("  ·  ", new[]
        {
            Hit.ProjectId,
            Hit.GitBranch,
            Ago(Hit.LastActivity),
            $"{Hit.MessageCount} messages",
        }.Where(s => !string.IsNullOrWhiteSpace(s)));

    public static string Ago(long? ms)
    {
        if (ms is null) return "";
        var s = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - ms.Value) / 1000.0;
        if (s < 90) return "just now";
        if (s < 5400) return $"{Math.Round(s / 60)} minutes ago";
        if (s < 129600) return $"{Math.Round(s / 3600)} hours ago";
        return $"{Math.Round(s / 86400)} days ago";
    }
}

public partial class MainWindow : Window
{
    private readonly IndexStore _store;
    private readonly ObservableCollection<ResultItem> _results = new();
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private CancellationTokenSource? _taskRun;
    private string? _projectFilter;
    private bool _todayOnly;
    private bool _ready;
    // XAML sets IsSelected on the first list item while InitializeComponent is still
    // running, which fires SelectionChanged before the other controls exist. Handlers do
    // nothing until the constructor has finished wiring everything up.
    private bool _wired;

    public MainWindow()
    {
        ThemeManager.Apply(ThemeManager.Named(ThemeManager.LoadSavedId()));
        InitializeComponent();

        _store = new IndexStore(AppPaths.IndexPath);
        ResultsBox.ItemsSource = _results;
        ThemePicker.ItemsSource = ThemeManager.All;
        ThemePicker.SelectedItem = ThemeManager.Current;
        TaskFolder.Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _debounce.Tick += (_, _) => { _debounce.Stop(); Refresh(); };

        _wired = true;
        Loaded += async (_, _) => await FirstIndex();
    }

    private async Task FirstIndex()
    {
        StatusLine.Text = "Indexing…";
        var root = AppPaths.ProjectsRoot;
        var result = await Task.Run(() => Indexer.Reindex(_store, root));
        _ready = true;
        StatusLine.Text = $"{result.Total} sessions · {_store.Projects().Count} projects";
        LoadProjects();
        Refresh();
    }

    private void LoadProjects()
    {
        var projects = _store.Projects();
        ProjectsBox.ItemsSource = projects;
        ProjectsHeader.Text = $"PROJECTS ({projects.Count})";
    }

    private void Refresh()
    {
        if (!_ready) return;
        long? since = _todayOnly
            ? new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds()
            : null;
        var hits = _store.Search(SearchBox.Text, _projectFilter, since, 200);
        _results.Clear();
        foreach (var h in hits) _results.Add(new ResultItem { Hit = h });
        NoResults.Visibility = hits.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SearchChanged(object sender, TextChangedEventArgs e)
    {
        if (!_wired) return;
        _debounce.Stop();
        _debounce.Start();
    }

    private void ListChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_wired) return;
        if (ListsBox.SelectedItem is not ListBoxItem item) return;
        _todayOnly = (item.Tag as string) == "today";
        _projectFilter = null;
        ProjectsBox.SelectedItem = null;
        Refresh();
    }

    private void ProjectChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_wired) return;
        if (ProjectsBox.SelectedItem is not ProjectRow row) return;
        _projectFilter = row.Id;
        _todayOnly = false;
        ListsBox.SelectedItem = null;
        Refresh();
    }

    private void SessionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_wired) return;
        if (ResultsBox.SelectedItem is not ResultItem item) return;
        ShowSession(item.Hit);
    }

    private void ShowSession(SearchHit hit)
    {
        DetailPanel.Children.Clear();

        DetailPanel.Children.Add(new TextBlock
        {
            Text = hit.Title, FontSize = 21, FontWeight = FontWeights.Bold,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
        });

        var meta = string.Join("   ·   ", new[]
        {
            hit.ProjectId, hit.GitBranch, ResultItem.Ago(hit.LastActivity), $"{hit.MessageCount} messages",
        }.Where(s => !string.IsNullOrWhiteSpace(s)));
        DetailPanel.Children.Add(Dim(meta));
        if (!string.IsNullOrEmpty(hit.Cwd)) DetailPanel.Children.Add(Dim(hit.Cwd!));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 16) };
        var open = new Button { Content = "Open in terminal" };
        open.Click += (_, _) => Launcher.OpenSession(AppPaths.ClaudeCommand, hit.Cwd ?? "", hit.SessionId);
        var reveal = new Button
        {
            Content = "Show folder", Margin = new Thickness(8, 0, 0, 0),
            Style = (Style)FindResource("Ghost"),
        };
        reveal.Click += (_, _) => Launcher.RevealFolder(hit.Cwd);
        buttons.Children.Add(open);
        buttons.Children.Add(reveal);
        DetailPanel.Children.Add(buttons);

        List<Turn> turns;
        try { turns = Scanner.LoadTurns(hit.FilePath); }
        catch (IOException) { turns = new List<Turn>(); }

        if (turns.Count == 0)
        {
            DetailPanel.Children.Add(Dim("No conversation in this transcript."));
            return;
        }

        foreach (var turn in turns)
        {
            var block = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
            block.Children.Add(new TextBlock
            {
                Text = turn.Role, FontSize = 10.5, FontWeight = FontWeights.Bold,
                Foreground = (Brush)FindResource(turn.Role == "You" ? "Accent" : "Hot"),
                Margin = new Thickness(0, 0, 0, 3),
            });
            block.Children.Add(new TextBlock { Text = turn.Text, TextWrapping = TextWrapping.Wrap });
            DetailPanel.Children.Add(new Border
            {
                Background = (Brush)FindResource("Surface"),
                CornerRadius = new CornerRadius(7),
                Padding = new Thickness(11, 9, 11, 9),
                Margin = new Thickness(0, 0, 0, 8),
                Child = block,
            });
        }
    }

    private TextBlock Dim(string text) => new()
    {
        Text = text, Style = (Style)FindResource("Dim"), TextWrapping = TextWrapping.Wrap,
    };

    private void ThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_wired) return;
        if (ThemePicker.SelectedItem is not Theme theme) return;
        ThemeManager.Apply(theme);
        ThemeManager.Save(theme.Id);
        FontFamily = new FontFamily(theme.FontFamily);
        if (ResultsBox.SelectedItem is ResultItem item) ShowSession(item.Hit);
    }

    private async void Rescan(object sender, RoutedEventArgs e)
    {
        RescanButton.IsEnabled = false;
        StatusLine.Text = "Rescanning…";
        var root = AppPaths.ProjectsRoot;
        var result = await Task.Run(() => Indexer.Reindex(_store, root));
        StatusLine.Text = $"{result.Total} sessions · {result.Indexed} updated";
        LoadProjects();
        Refresh();
        RescanButton.IsEnabled = true;
    }

    private async void RunQuickTask(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(TaskPrompt.Text)) return;
        _taskRun?.Cancel();
        _taskRun = new CancellationTokenSource();
        TaskOutput.Text = "";
        RunTask.IsEnabled = false;
        StopTask.IsEnabled = true;
        try
        {
            await Launcher.RunQuickTask(AppPaths.ClaudeCommand, TaskFolder.Text, TaskPrompt.Text,
                line => Dispatcher.Invoke(() =>
                {
                    TaskOutput.Text += line + "\n";
                    TaskScroll.ScrollToEnd();
                }), _taskRun.Token);
        }
        catch (OperationCanceledException) { TaskOutput.Text += "\n[stopped]\n"; }
        catch (Exception ex) { TaskOutput.Text += $"\n[failed: {ex.Message}]\n"; }
        finally
        {
            RunTask.IsEnabled = true;
            StopTask.IsEnabled = false;
        }
    }

    private void StopQuickTask(object sender, RoutedEventArgs e) => _taskRun?.Cancel();

    protected override void OnClosed(EventArgs e)
    {
        _taskRun?.Cancel();
        _store.Dispose();
        base.OnClosed(e);
    }
}
