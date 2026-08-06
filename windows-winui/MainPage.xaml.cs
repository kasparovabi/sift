using System.Collections.ObjectModel;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SiftWinUI.Core;

namespace SiftWinUI;

public sealed class ResultItem
{
    public required SearchHit Hit { get; init; }
    public string Title => Hit.Title;
    public string Line => (Hit.Snippet ?? Hit.Preview).Replace('\n', ' ');
    public string Meta => string.Join("   ·   ", new[]
    {
        Hit.ProjectId, Hit.GitBranch, Ago(Hit.LastActivity), $"{Hit.MessageCount} messages",
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

public sealed class LoopItem
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Status { get; init; }
    public required string Where { get; init; }
}

public sealed class AtomItem
{
    public required Atom Atom { get; init; }
    public string Statement => Atom.Statement;
    public string Kind => Atom.Type.Label();
    public string Meta => string.Join("   ·   ", new[]
    {
        Atom.Project, $"importance {Atom.Importance}",
    }.Where(s => !string.IsNullOrWhiteSpace(s)));
}

public sealed class TurnItem
{
    public required string Who { get; init; }
    public required string Text { get; init; }
    public required Brush Colour { get; init; }
}

public sealed partial class MainPage : Page
{
    private readonly IndexStore _store = new(AppPaths.IndexPath);
    private readonly ObservableCollection<ResultItem> _results = new();
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private readonly LoopStore _loops = new(Path.Combine(AppPaths.SupportDir, "loops.sqlite"));
    private readonly Dictionary<string, CancellationTokenSource> _running = new();
    /// Opened on the first visit to Knowledge rather than at startup: a second database is
    /// work nobody asked for when the page may never be opened.
    private BrainStore? _brainStore;
    private BrainStore Brain => _brainStore ??= new BrainStore(Path.Combine(AppPaths.SupportDir, "brain.sqlite"));
    private readonly ObservableCollection<AtomItem> _atoms = new();
    private readonly DispatcherTimer _brainDebounce = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private readonly DispatcherTimer _ingest = new() { Interval = TimeSpan.FromSeconds(90) };
    private readonly CancellationTokenSource _ingestStop = new();
    private BrainIngester? _ingester;
    private CancellationTokenSource? _catchUp;
    private bool _catchingUp;
    private bool _ingesting;
    private double _spent;
    private List<NodePosition> _nodes = [];
    private List<GraphEdge> _edges = [];
    private CancellationTokenSource? _taskRun;
    private string? _projectFilter;
    private bool _todayOnly;
    private bool _ready;

    public MainPage()
    {
        InitializeComponent();
        ResultsBox.ItemsSource = _results;
        AppearancePicker.ItemsSource = ThemeService.All;

        var saved = ThemeService.Named(ThemeService.LoadSavedId());
        ThemeService.Apply(saved, this);
        AppearancePicker.SelectedItem = saved;

        AtomList.ItemsSource = _atoms;
        _debounce.Tick += (_, _) => { _debounce.Stop(); Refresh(); };
        _brainDebounce.Tick += (_, _) => { _brainDebounce.Stop(); RefreshAtoms(); };
        _ingest.Tick += async (_, _) => await IngestSome();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        TaskFolder.Text = home;
        LoopFolder.Text = home;
        Loaded += async (_, _) =>
        {
            try { await FirstIndex(); }
            catch (Exception error) { Report(error); throw; }
        };
    }

    /// A fault during startup fails the process with nothing on stderr and an address in the
    /// event log. Writing it down turns "it just closes" into something anyone can report.
    internal static void Report(Exception error)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.SupportDir);
            File.WriteAllText(Path.Combine(AppPaths.SupportDir, "crash.txt"), error.ToString());
        }
        catch { }
    }

    private async Task FirstIndex()
    {
        StatusLine.Text = "Indexing…";
        var root = AppPaths.ProjectsRoot;
        var result = await Task.Run(() => Indexer.Reindex(_store, root));
        _ready = true;
        Busy.IsActive = false;
        BuildSources();
        StatusLine.Text = $"{result.Total} sessions";
        ShowRetention();
        Refresh();
        // Extraction runs from launch, not from the first visit to Knowledge: a backlog that
        // only moves while someone is looking at it never finishes.
        if (Preferences.KnowledgeExtractionEnabled) _ingest.Start();
    }

    /// Says plainly what Claude Code is set to delete and what Sift has kept, and offers
    /// the fix rather than making anyone find settings.json.
    private void ShowRetention()
    {
        var days = ClaudeRetention.CurrentDays();
        RetentionBar.IsOpen = days is not null && days < 3650;
        if (days is not null && days < 3650)
            RetentionBar.Message =
                $"Claude Code removes transcripts after {days} days. Sift keeps its own copy, " +
                "but turning the cleanup off keeps the originals resumable too.";

        var (files, bytes) = Archive.Size();
        ArchiveLine.Text = files == 0 ? "Archive empty."
            : $"Archive: {files} sessions, {bytes / 1024 / 1024} MB";
    }

    private void DisableCleanup(object sender, RoutedEventArgs e)
    {
        if (ClaudeRetention.SetDays(ClaudeRetention.Forever))
        {
            RetentionBar.Severity = InfoBarSeverity.Success;
            RetentionBar.Title = "Cleanup turned off";
            RetentionBar.Message = "Claude Code will keep transcripts. Your previous settings.json " +
                                   "was saved beside it as settings.json.sift-backup.";
        }
        else
        {
            RetentionBar.Severity = InfoBarSeverity.Error;
            RetentionBar.Message = $"Could not write {ClaudeRetention.SettingsPath}.";
        }
    }

    private void RefreshBrain()
    {
        var on = Preferences.KnowledgeExtractionEnabled;
        BrainConsent.IsOpen = true;
        BrainConsent.Title = on ? "Extraction is on" : "Extraction is off";
        BrainConsent.Severity = on ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        BrainConsent.Message = on
            ? "Finished sessions are sent to claude under your own account, a couple at a time, " +
              "and what comes back is stored locally. Turning it off stops that immediately."
            : "Sift can read your finished sessions and pull durable facts out of them. Doing " +
              "that sends transcript text to Claude under your own account and uses your " +
              "allowance, so it stays off until you say otherwise.";
        BrainConsent.ActionButton = new Button
        {
            Content = on ? "Turn extraction off" : "Turn extraction on",
        };
        ((Button)BrainConsent.ActionButton).Click += ToggleExtraction;

        var atoms = Brain.AtomCount();
        var entities = Brain.EntityCount();
        BrainSubtitle.Text = atoms == 0
            ? "Durable facts pulled out of finished sessions, and the things they are about."
            : $"{atoms} facts about {entities} things, from your finished sessions.";

        ShowBacklog();
        RefreshAtoms();
        RefreshGraph();
        if (on) _ingest.Start();
    }

    /// A fresh install has the whole library waiting and nothing to show for it, which reads
    /// as broken. Saying how many sessions are left, and offering to work through them now
    /// rather than a couple every minute and a half, is the difference.
    private void ShowBacklog()
    {
        if (!Preferences.KnowledgeExtractionEnabled)
        {
            BacklogRow.Visibility = Visibility.Collapsed;
            return;
        }

        var read = Brain.ReadCount();
        var left = Ingester.Remaining();
        BacklogRow.Visibility = Visibility.Visible;
        CatchUpButton.IsEnabled = left > 0 || _catchingUp;
        CatchUpButton.Content = _catchingUp ? "Stop" : "Read everything now";
        BacklogLine.Text = left == 0
            ? $"All {read} sessions read. New ones are picked up as you finish them. {Spent()}"
            : $"{read} of {read + left} sessions read, {left} to go. Each one is a claude run " +
              $"against your own account, so it uses your allowance and takes a while. {Spent()}";
    }

    /// claude reports what a run would have cost at API prices. On a subscription that is not
    /// a bill, it is a measure of how much of the weekly allowance went in, so it is labelled
    /// rather than shown as money owed.
    private string Spent() => _spent <= 0 ? ""
        : $"So far this session: ${_spent.ToString("F2", System.Globalization.CultureInfo.InvariantCulture)} " +
          "at API rates, nothing extra on a subscription.";

    private async void CatchUp(object sender, RoutedEventArgs e)
    {
        if (_catchingUp)
        {
            _catchUp?.Cancel();
            return;
        }

        _catchingUp = true;
        _catchUp = CancellationTokenSource.CreateLinkedTokenSource(_ingestStop.Token);
        BacklogBusy.IsActive = true;
        CatchUpButton.Content = "Stop";
        try
        {
            while (!_catchUp.IsCancellationRequested)
            {
                var outcome = await Ingester.Tick(_catchUp.Token, limit: 1);
                if (outcome.Sessions == 0) break;
                _spent += outcome.CostUsd;
                var read = Brain.ReadCount();
                var left = Ingester.Remaining();
                BacklogLine.Text = $"{read} of {read + left} sessions read, {left} to go. " +
                                   Spent();
                RefreshAtoms();
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            _catchingUp = false;
            _catchUp = null;
            BacklogBusy.IsActive = false;
            RefreshGraph();
            RefreshBrain();
        }
    }

    private BrainIngester Ingester =>
        _ingester ??= new BrainIngester(Brain, _store, new Extractor(AppPaths.ClaudeCommand));

    private void RefreshAtoms()
    {
        _atoms.Clear();
        foreach (var atom in Brain.Atoms(BrainSearch.Text)) _atoms.Add(new AtomItem { Atom = atom });
    }

    private void BrainSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        _brainDebounce.Stop();
        _brainDebounce.Start();
    }

    private void ToggleExtraction(object sender, RoutedEventArgs e)
    {
        Preferences.KnowledgeExtractionEnabled = !Preferences.KnowledgeExtractionEnabled;
        if (!Preferences.KnowledgeExtractionEnabled) _ingest.Stop();
        RefreshBrain();
    }

    /// Runs a couple of sessions per tick while the app is open. Extraction spends tokens, so
    /// a backlog of thousands drains slowly and visibly rather than all at once.
    private async Task IngestSome()
    {
        if (_ingesting || _catchingUp || !Preferences.KnowledgeExtractionEnabled) return;
        _ingesting = true;
        try
        {
            var outcome = await Ingester.Tick(_ingestStop.Token);
            if (outcome.Atoms > 0 && BrainView.Visibility == Visibility.Visible) RefreshBrain();
        }
        catch (OperationCanceledException) { }
        finally { _ingesting = false; }
    }

    private void RefreshGraph()
    {
        var entities = Brain.Entities();
        _edges = Brain.Edges(entities.Select(e => e.Id));
        _nodes = GraphLayout.Compute(entities, _edges);
        GraphEmpty.Visibility = _nodes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        DrawGraph();
    }

    private void GraphResized(object sender, SizeChangedEventArgs e) => DrawGraph();

    /// Edges first, then nodes, then labels, so nothing is drawn over a name.
    private void DrawGraph()
    {
        GraphCanvas.Children.Clear();
        var width = GraphCanvas.ActualWidth;
        var height = GraphCanvas.ActualHeight;
        if (_nodes.Count == 0 || width < 40 || height < 40) return;

        var placed = _nodes.ToDictionary(n => n.Id, n => (X: n.X * width, Y: n.Y * height));
        var line = Resource("TextFillColorTertiaryBrush", Microsoft.UI.Colors.Gray);
        var fill = Resource("AccentFillColorDefaultBrush", Microsoft.UI.Colors.SteelBlue);
        var text = Resource("TextFillColorPrimaryBrush", Microsoft.UI.Colors.White);

        foreach (var edge in _edges)
        {
            if (!placed.TryGetValue(edge.FromId, out var a)) continue;
            if (!placed.TryGetValue(edge.ToId, out var b)) continue;
            GraphCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Line
            {
                X1 = a.X, Y1 = a.Y, X2 = b.X, Y2 = b.Y,
                Stroke = line, StrokeThickness = 1, Opacity = 0.35,
            });
        }

        foreach (var node in _nodes)
        {
            var point = placed[node.Id];
            var diameter = 10 + Math.Min(node.Weight, 14) * 1.6;
            var dot = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = diameter, Height = diameter, Fill = fill,
            };
            Canvas.SetLeft(dot, point.X - diameter / 2);
            Canvas.SetTop(dot, point.Y - diameter / 2);
            ToolTipService.SetToolTip(dot, $"{node.Label} — {node.Weight} facts");
            GraphCanvas.Children.Add(dot);

            var label = new TextBlock
            {
                Text = node.Label, FontSize = 11, Foreground = text, Opacity = 0.85,
                TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 120,
            };
            Canvas.SetLeft(label, point.X + diameter / 2 + 4);
            Canvas.SetTop(label, point.Y - 8);
            GraphCanvas.Children.Add(label);
        }
    }

    private Brush Resource(string key, Windows.UI.Color fallback) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush : new SolidColorBrush(fallback);

    /// The pane lists the two saved views, then the tools, then one entry per project. The
    /// tools sit above the projects because a long project list would otherwise push them
    /// off the bottom, where nobody found them.
    private void BuildSources()
    {
        Nav.MenuItems.Clear();
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "All sessions", Tag = "all",
            Icon = new FontIcon { Glyph = "" },
        });
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Today", Tag = "today",
            Icon = new FontIcon { Glyph = "" },
        });
        Nav.MenuItems.Add(new NavigationViewItemSeparator());
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Tools" });
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Quick task", Tag = "quick",
            Icon = new FontIcon { Glyph = "" },
        });
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Loops", Tag = "loops",
            Icon = new FontIcon { Glyph = "" },
        });
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Knowledge", Tag = "brain",
            Icon = new FontIcon { Glyph = "" },
        });

        Nav.MenuItems.Add(new NavigationViewItemSeparator());
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = "Projects" });

        foreach (var project in _store.Projects())
        {
            Nav.MenuItems.Add(new NavigationViewItem
            {
                Content = project.Name,
                Tag = "p:" + project.Id,
                Icon = new FontIcon { Glyph = "" },
                InfoBadge = new InfoBadge { Value = project.Count },
            });
            ToolTipService.SetToolTip((NavigationViewItem)Nav.MenuItems[^1], project.Path);
        }
        Nav.SelectedItem = Nav.MenuItems[0];
    }

    private void SourceSelected(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item || item.Tag is not string tag) return;

        var isTool = tag is "quick" or "loops" or "brain";
        SessionsView.Visibility = isTool ? Visibility.Collapsed : Visibility.Visible;
        QuickView.Visibility = tag == "quick" ? Visibility.Visible : Visibility.Collapsed;
        LoopsView.Visibility = tag == "loops" ? Visibility.Visible : Visibility.Collapsed;
        BrainView.Visibility = tag == "brain" ? Visibility.Visible : Visibility.Collapsed;
        if (isTool)
        {
            if (tag == "loops") RefreshLoops();
            if (tag == "brain") RefreshBrain();
            return;
        }

        _todayOnly = tag == "today";
        _projectFilter = tag.StartsWith("p:", StringComparison.Ordinal) ? tag[2..] : null;
        Refresh();
    }

    private void SearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        _debounce.Stop();
        _debounce.Start();
    }

    private void Refresh()
    {
        if (!_ready) return;
        long? since = _todayOnly ? new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds() : null;
        var hits = _store.Search(SearchBox.Text, _projectFilter, since, 200);
        _results.Clear();
        foreach (var hit in hits) _results.Add(new ResultItem { Hit = hit });
        EmptyResults.Visibility = hits.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SessionSelected(object sender, SelectionChangedEventArgs e)
    {
        if (ResultsBox.SelectedItem is ResultItem item) ShowSession(item.Hit);
    }

    private void ShowSession(SearchHit hit)
    {
        Detail.Children.Clear();

        Detail.Children.Add(new TextBlock
        {
            Text = hit.Title,
            Style = (Style)Application.Current.Resources["TitleTextBlockStyle"],
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10),
        });

        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var text in new[] { hit.ProjectId, hit.GitBranch, ResultItem.Ago(hit.LastActivity),
                                     $"{hit.MessageCount} messages" }.Where(s => !string.IsNullOrWhiteSpace(s)))
        {
            chips.Children.Add(new Border
            {
                Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                CornerRadius = new CornerRadius(11),
                Padding = new Thickness(10, 3, 10, 3),
                Child = new TextBlock
                {
                    Text = text!,
                    Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                },
            });
        }
        Detail.Children.Add(chips);

        if (!string.IsNullOrEmpty(hit.Cwd))
        {
            Detail.Children.Add(new TextBlock
            {
                Text = hit.Cwd,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                Margin = new Thickness(0, 8, 0, 0),
            });
        }

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Margin = new Thickness(0, 16, 0, 18),
        };
        var open = new Button
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8,
                Children = { new FontIcon { Glyph = "", FontSize = 14 },
                             new TextBlock { Text = "Open in terminal" } },
            },
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        open.Click += (_, _) => Launcher.OpenSession(AppPaths.ClaudeCommand, hit.Cwd ?? "", hit.SessionId);
        var reveal = new Button { Content = "Show folder" };
        reveal.Click += (_, _) => Launcher.RevealFolder(hit.Cwd);
        actions.Children.Add(open);
        actions.Children.Add(reveal);
        Detail.Children.Add(actions);

        List<Turn> turns;
        try { turns = Scanner.LoadTurns(hit.FilePath); }
        catch (IOException) { turns = new List<Turn>(); }

        if (turns.Count == 0)
        {
            Detail.Children.Add(new TextBlock
            {
                Text = "No conversation in this transcript.",
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
            return;
        }

        var you = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];
        var claude = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var list = new ItemsControl
        {
            ItemTemplate = (DataTemplate)Resources["TurnTemplate"],
            ItemsSource = turns.Select(t => new TurnItem
            {
                Who = t.Role, Text = t.Text, Colour = t.Role == "You" ? you : claude,
            }).ToList(),
        };
        Detail.Children.Add(list);
    }

    private void AppearanceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AppearancePicker.SelectedItem is not Appearance appearance) return;
        ThemeService.Apply(appearance, this);
        ThemeService.Save(appearance.Id);
    }

    private async void Rescan(object sender, RoutedEventArgs e)
    {
        RescanButton.IsEnabled = false;
        Busy.IsActive = true;
        StatusLine.Text = "Rescanning…";
        var root = AppPaths.ProjectsRoot;
        var result = await Task.Run(() => Indexer.Reindex(_store, root));
        Busy.IsActive = false;
        StatusLine.Text = $"{result.Total} sessions · {result.Indexed} updated";
        ShowRetention();
        BuildSources();
        Refresh();
        RescanButton.IsEnabled = true;
    }

    // MARK: Quick task

    private async void RunQuickTask(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(TaskPrompt.Text)) return;
        _taskRun?.Cancel();
        _taskRun = new CancellationTokenSource();
        TaskOutput.Text = "";
        RunTask.IsEnabled = false;
        StopTask.IsEnabled = true;
        TaskBusy.IsActive = true;
        try
        {
            await Launcher.RunQuickTask(AppPaths.ClaudeCommand, TaskFolder.Text, TaskPrompt.Text,
                line => DispatcherQueue.TryEnqueue(() =>
                {
                    TaskOutput.Text += line + "\n";
                    TaskScroll.ChangeView(null, TaskScroll.ScrollableHeight, null);
                }), _taskRun.Token);
        }
        catch (OperationCanceledException) { TaskOutput.Text += "\n[stopped]\n"; }
        catch (Exception ex) { TaskOutput.Text += $"\n[failed: {ex.Message}]\n"; }
        finally
        {
            RunTask.IsEnabled = true;
            StopTask.IsEnabled = false;
            TaskBusy.IsActive = false;
        }
    }

    private void StopQuickTask(object sender, RoutedEventArgs e) => _taskRun?.Cancel();

    // MARK: Loops

    private void RefreshLoops()
    {
        LoopList.ItemsSource = _loops.All().Select(t => new LoopItem
        {
            Id = t.Id,
            Title = string.IsNullOrWhiteSpace(t.Title) ? "Untitled loop" : t.Title,
            Status = t.State == "passed" ? $"passed · attempt {t.LastAttempt}"
                   : t.State == "failed" ? $"failed after {t.LastAttempt}"
                   : t.State == "idle" ? "ready" : t.State,
            Where = t.Cwd,
        }).ToList();
    }

    private void AddLoop(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(LoopPrompt.Text) || string.IsNullOrWhiteSpace(LoopDoneWhen.Text)) return;
        _loops.Upsert(new LoopTask
        {
            Title = LoopTitle.Text,
            Prompt = LoopPrompt.Text,
            Cwd = string.IsNullOrWhiteSpace(LoopFolder.Text)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : LoopFolder.Text,
            DoneWhen = LoopDoneWhen.Text,
            Check = LoopCheckKind.SelectedIndex == 1 ? CheckKind.Shell : CheckKind.Agent,
            MaxPasses = (int)LoopPasses.Value,
        });
        LoopTitle.Text = LoopPrompt.Text = LoopDoneWhen.Text = "";
        RefreshLoops();
    }

    private async void RunLoop(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not string id) return;
        var task = _loops.All().FirstOrDefault(t => t.Id == id);
        if (task is null || _running.ContainsKey(id)) return;

        var cts = new CancellationTokenSource();
        _running[id] = cts;
        LoopLog.Text = "";
        var engine = new LoopEngine(_loops, AppPaths.ClaudeCommand);
        try
        {
            await engine.RunAsync(task, (kind, line) => DispatcherQueue.TryEnqueue(() =>
            {
                LoopLog.Text += (kind == "phase" ? "\n▸ " : kind == "pass" ? "✓ " : kind == "fail" ? "✗ " : "  ")
                              + line + "\n";
                LoopLogScroll.ChangeView(null, LoopLogScroll.ScrollableHeight, null);
                RefreshLoops();
            }), cts.Token);
        }
        catch (OperationCanceledException) { LoopLog.Text += "\n[stopped]\n"; }
        catch (Exception ex) { LoopLog.Text += $"\n[failed: {ex.Message}]\n"; }
        finally
        {
            _running.Remove(id);
            RefreshLoops();
        }
    }

    private void StopLoop(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is string id && _running.TryGetValue(id, out var cts)) cts.Cancel();
    }

    private void DeleteLoop(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not string id) return;
        if (_running.TryGetValue(id, out var cts)) cts.Cancel();
        _loops.Delete(id);
        RefreshLoops();
    }
}
