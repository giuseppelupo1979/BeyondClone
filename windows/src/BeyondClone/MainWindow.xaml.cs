using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using BeyondClone.Core;

namespace BeyondClone;

public enum SidebarKind { Header, Profile, Adhoc, Recent, Volume, Action }

/// <summary>Una riga della barra laterale.</summary>
public sealed class SidebarEntry
{
    public SidebarKind Kind { get; init; }
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public Brush SubtitleBrush { get; init; } = UI.Secondary;
    public string Glyph { get; init; } = "";
    public Brush GlyphBrush { get; init; } = Brushes.White;
    public Brush GlyphBack { get; init; } = Brushes.Transparent;
    public string Badge { get; init; } = "";
    public Brush BadgeBack { get; init; } = Brushes.Transparent;
    public double ProgressValue { get; init; }
    public bool Indeterminate { get; init; }
    public bool ShowProgress { get; init; }
    public string ToolTip { get; init; } = "";
    public object? Payload { get; init; }

    public bool IsHeader => Kind == SidebarKind.Header;
    public Visibility HeaderVisibility => IsHeader ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ItemVisibility => IsHeader ? Visibility.Collapsed : Visibility.Visible;
    public Visibility SubtitleVisibility => Subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BadgeVisibility => Badge.Length > 0 && !ShowProgress ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProgressVisibility => ShowProgress ? Visibility.Visible : Visibility.Collapsed;
}

public partial class MainWindow : Window
{
    readonly AppState app = AppState.Instance;
    FolderSession? session;
    List<VolumeInfo> volumes = [];
    bool suppressSidebar, suppressTree;
    readonly Dictionary<FolderFilter, (RadioButton Button, TextBlock Count)> filters = [];
    string? selectedKey;

    public MainWindow(string? left, string? right)
    {
        InitializeComponent();
        BuildFilters();
        Tree.SizeChanged += (_, _) => FitColumns();
        SizeChanged += (_, _) => ApplyInspectorVisibility();
        app.SidebarChanged += () => Dispatcher.BeginInvoke(RefreshSidebar);
        InspectorToggle.IsChecked = app.Settings.ShowInspector;
        Loaded += async (_, _) =>
        {
            if (left != null && right != null) Select("adhoc:" + app.OpenPair(left, right).Id);
            else RestoreLast();
            RefreshSidebar();
            await RefreshVolumes();
        };
        Closing += (_, e) =>
        {
            if (app.Running.Any() && !UI.Confirm("Sincronizzazione in corso", "Una o più sincronizzazioni sono in corso. Chiudendo vengono interrotte.", "Chiudi comunque"))
                e.Cancel = true;
        };
        ShowWelcome();
    }

    // ===================== Barra laterale =====================

    async Task RefreshVolumes()
    {
        volumes = await VolumeInfo.ListAsync();
        RefreshSidebar();
    }

    void RestoreLast()
    {
        var last = app.Settings.LastSelection;
        if (last?.StartsWith("profile:") == true && Guid.TryParse(last[8..], out var id) && app.Profile(id) != null)
            Select("profile:" + id);
        else if (last?.StartsWith("pair:") == true && last[5..].Split('\u001F') is [var l, var r])
            Select("adhoc:" + app.OpenPair(l, r).Id);
        else if (app.Profiles.FirstOrDefault() is { } first)
            Select("profile:" + first.Id);
    }

    static SolidColorBrush Solid(Brush b) => (SolidColorBrush)b;

    void RefreshSidebar()
    {
        var list = new List<SidebarEntry> { new() { Kind = SidebarKind.Header, Title = "Sincronizzazioni" } };
        foreach (var p in app.Profiles)
        {
            var s = app.Existing(p.Id);
            string sub;
            Brush subBrush = UI.Secondary;
            string badge = "";
            bool progress = false, indeterminate = false;
            double value = 0;
            if (s?.Progress is { } pr)
            {
                sub = $"{(int)(pr.Fraction * 100)}% · {Fmt.Speed(pr.Speed)}";
                subBrush = UI.Accent;
                progress = true;
                value = pr.Fraction;
            }
            else if (s != null)
            {
                switch (s.State)
                {
                    case ScanState.Connecting: sub = "Connessione…"; progress = indeterminate = true; break;
                    case ScanState.Scanning: sub = $"Analisi · {Fmt.Number(s.StatItems)} elementi"; progress = indeterminate = true; break;
                    case ScanState.Failed: sub = s.FailMessage ?? "Errore"; subBrush = UI.ChangedBrush; break;
                    case ScanState.Done when s.ModePlan is { IsEmpty: false } plan:
                        sub = plan.Summary; subBrush = UI.MirrorBrush; badge = Fmt.Number(plan.Ops.Count); break;
                    case ScanState.Done: sub = "Allineate"; subBrush = UI.SameBrush; break;
                    default: sub = "Da configurare"; break;
                }
            }
            else sub = p.LastRun is { } d ? "Ultima: " + Fmt.Relative(d) : Path.GetFileName(p.Right.TrimEnd('\\'));
            list.Add(new SidebarEntry
            {
                Kind = SidebarKind.Profile, Key = "profile:" + p.Id, Title = p.Name, Subtitle = sub, SubtitleBrush = subBrush,
                Glyph = p.Mode.Glyph(), GlyphBack = p.Mode.IsMirror() ? UI.MirrorBrush : UI.Accent,
                Badge = badge, BadgeBack = UI.Tint(UI.MirrorBrush, 0.22), ShowProgress = progress, Indeterminate = indeterminate, ProgressValue = value,
                ToolTip = $"{p.Name}: {p.Mode.Title().ToLowerInvariant()}\n{p.Left}\n→ {p.Right}\nTasto destro per modificare, duplicare o eliminare",
                Payload = p,
            });
        }
        if (app.Profiles.Count == 0)
            list.Add(new SidebarEntry
            {
                Kind = SidebarKind.Action, Key = "action:newprofile", Title = "Crea un profilo", Glyph = "", GlyphBrush = UI.Accent,
                ToolTip = "Crea un profilo: una coppia di cartelle da sincronizzare quando vuoi",
            });

        if (app.Adhoc.Count > 0)
        {
            list.Add(new SidebarEntry { Kind = SidebarKind.Header, Title = "Confronti" });
            foreach (var s in app.Adhoc)
            {
                var d = s.LiveTally.Diffs;
                list.Add(new SidebarEntry
                {
                    Kind = SidebarKind.Adhoc, Key = "adhoc:" + s.Id, Title = s.Name,
                    Subtitle = s.IsScanning ? "Analisi…" : s.State == ScanState.Done ? (d == 0 ? "Identiche" : $"{Fmt.Number(d)} differenze") : "",
                    SubtitleBrush = s.State == ScanState.Done ? (d == 0 ? UI.SameBrush : UI.MirrorBrush) : UI.Secondary,
                    Glyph = "", GlyphBrush = UI.Secondary, ShowProgress = s.IsRunning || s.IsScanning, Indeterminate = !s.IsRunning,
                    ProgressValue = s.Progress?.Fraction ?? 0,
                    ToolTip = "Confronto al volo, non salvato. Tasto destro per salvarlo come profilo o chiuderlo", Payload = s,
                });
            }
        }

        var open = app.Adhoc.Where(s => s.LeftPath != null && s.RightPath != null)
            .Select(s => s.LeftPath + "\u001F" + s.RightPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var recents = app.Settings.Recents.Where(r => !open.Contains(r.Id)).Take(8).ToList();
        if (recents.Count > 0)
        {
            list.Add(new SidebarEntry { Kind = SidebarKind.Header, Title = "Recenti" });
            foreach (var r in recents)
                list.Add(new SidebarEntry
                {
                    Kind = SidebarKind.Recent, Key = "recent:" + r.Id, Title = r.Title, Subtitle = Fmt.Relative(r.Date),
                    Glyph = "", GlyphBrush = UI.Secondary,
                    ToolTip = $"{r.Left}\n↔ {r.Right}\nUltimo confronto: {r.Date.ToLocalTime():g}\nClic per riaprire · tasto destro per salvarlo come profilo",
                    Payload = r,
                });
        }

        list.Add(new SidebarEntry { Kind = SidebarKind.Header, Title = "Unità e rete" });
        foreach (var v in volumes)
            list.Add(new SidebarEntry
            {
                Kind = SidebarKind.Volume, Key = "volume:" + v.Root, Title = v.Name,
                Subtitle = (v.Free is { } f ? Fmt.Size(f) + " liberi" : "") + (v.Server != null ? " · " + v.Server : ""),
                Glyph = v.Glyph, GlyphBrush = v.IsNetwork ? UI.NetworkBrush : UI.Secondary,
                ShowProgress = v.Total > 0, ProgressValue = v.Total > 0 && v.Free != null ? 1 - (double)v.Free.Value / v.Total!.Value : 0,
                ToolTip = $"{v.Name}{(v.Server != null ? " · " + v.Server : "")}\n{(v.Free is { } fr ? Fmt.Size(fr) + " liberi" : "")}\nClic per iniziare un confronto da qui · tasto destro per altre azioni",
                Payload = v,
            });
        list.Add(new SidebarEntry
        {
            Kind = SidebarKind.Action, Key = "action:connect", Title = "Connetti al server…", Glyph = "", GlyphBrush = UI.Accent,
            ToolTip = "Collega una condivisione del NAS (SMB) per usarla nei confronti",
        });

        suppressSidebar = true;
        SidebarList.ItemsSource = list;
        SidebarList.SelectedItem = list.FirstOrDefault(e => e.Key == selectedKey);
        suppressSidebar = false;
        RefreshWelcomeRecents();
    }

    void Sidebar_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressSidebar || SidebarList.SelectedItem is not SidebarEntry entry) return;
        switch (entry.Kind)
        {
            case SidebarKind.Action:
                Dispatcher.BeginInvoke(() =>
                {
                    RefreshSidebar();
                    if (entry.Key == "action:connect") Connect_Click(this, new RoutedEventArgs());
                    else NewProfile_Click(this, new RoutedEventArgs());
                });
                return;
            case SidebarKind.Recent when entry.Payload is RecentPair r:
                Select("adhoc:" + app.OpenPair(r.Left, r.Right).Id);
                return;
            case SidebarKind.Volume when entry.Payload is VolumeInfo v:
                Select("adhoc:" + app.OpenPair(v.Root, null).Id);
                return;
            default:
                Select(entry.Key);
                return;
        }
    }

    void Select(string key)
    {
        selectedKey = key;
        FolderSession? s = null;
        if (key.StartsWith("profile:") && Guid.TryParse(key[8..], out var pid))
        {
            s = app.OpenProfile(pid);
            app.SetLastSelection(key);
        }
        else if (key.StartsWith("adhoc:") && Guid.TryParse(key[6..], out var aid))
        {
            s = app.Existing(aid);
            if (s?.LeftPath != null && s.RightPath != null) app.SetLastSelection("pair:" + s.LeftPath + "\u001F" + s.RightPath);
        }
        Show(s);
        RefreshSidebar();
    }

    void Sidebar_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = SidebarList.ContextMenu!;
        menu.Items.Clear();
        var element = e.OriginalSource as FrameworkElement;
        var entry = element?.DataContext as SidebarEntry;
        if (entry == null || entry.IsHeader) { e.Handled = true; return; }
        switch (entry.Payload)
        {
            case SyncProfile p:
                Add(menu, "Modifica…", "", () => EditProfile(p.Clone()));
                Add(menu, "Duplica", "", () => { if (app.Duplicate(p.Id) is { } d) Select("profile:" + d.Id); });
                Add(menu, "Sposta su", "", () => app.MoveProfile(p.Id, -1));
                Add(menu, "Sposta giù", "", () => app.MoveProfile(p.Id, 1));
                Add(menu, "Apri le cartelle in Esplora file", "", () => { UI.Open(p.Left); UI.Open(p.Right); });
                menu.Items.Add(new Separator());
                Add(menu, "Elimina profilo…", "", () =>
                {
                    if (!UI.Confirm($"Eliminare il profilo «{p.Name}»?", "Vengono eliminate solo le impostazioni: i file non vengono toccati.", "Elimina")) return;
                    if (selectedKey == "profile:" + p.Id) { selectedKey = null; Show(null); }
                    app.DeleteProfile(p.Id);
                });
                break;
            case FolderSession s:
                Add(menu, "Salva come profilo…", "", () => SaveAsProfile(s));
                Add(menu, "Chiudi confronto", "", () =>
                {
                    if (selectedKey == "adhoc:" + s.Id) { selectedKey = null; Show(null); }
                    app.Close(s.Id);
                });
                break;
            case RecentPair r:
                Add(menu, "Salva come profilo…", "", () => EditProfile(new SyncProfile { Name = r.Title, Left = r.Left, Right = r.Right }));
                Add(menu, "Apri le cartelle in Esplora file", "", () => { UI.Open(r.Left); UI.Open(r.Right); });
                menu.Items.Add(new Separator());
                Add(menu, "Rimuovi dai recenti", "", () => app.RemoveRecent(r.Id));
                Add(menu, "Svuota i recenti", "", app.ClearRecents);
                break;
            case VolumeInfo v:
                Add(menu, "Confronta da qui…", "", () => Select("adhoc:" + app.OpenPair(v.Root, null).Id));
                Add(menu, "Apri in Esplora file", "", () => UI.Open(v.Root));
                Add(menu, "Aggiorna l'elenco", "", () => _ = RefreshVolumes());
                break;
            default:
                e.Handled = true;
                break;
        }
    }

    static void Add(ItemsControl menu, string header, string glyph, Action action, bool enabled = true, string? tip = null)
    {
        var item = new MenuItem
        {
            Header = header,
            IsEnabled = enabled,
            Icon = new TextBlock { Text = glyph, FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 14 },
        };
        if (tip != null) item.ToolTip = tip;
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    void RefreshWelcomeRecents()
    {
        WelcomeRecents.Children.Clear();
        var recents = app.Settings.Recents.Take(6).ToList();
        WelcomeRecentsTitle.Visibility = recents.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var r in recents)
        {
            var b = new Button
            {
                HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(6, 2, 6, 2), Padding = new Thickness(12, 7, 12, 7),
                ToolTip = $"Riapri il confronto tra\n{r.Left}\ne\n{r.Right}",
            };
            var g = new DockPanel();
            var date = new TextBlock { Text = Fmt.Relative(r.Date), Style = (Style)FindResource("Caption"), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(date, Dock.Right);
            g.Children.Add(date);
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = r.Title, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = $"{r.Left}  ↔  {r.Right}", Style = (Style)FindResource("Caption"), TextTrimming = TextTrimming.CharacterEllipsis });
            g.Children.Add(sp);
            b.Content = g;
            b.Click += (_, _) => Select("adhoc:" + app.OpenPair(r.Left, r.Right).Id);
            WelcomeRecents.Children.Add(b);
        }
    }

    // ===================== Sessione corrente =====================

    void ShowWelcome()
    {
        WelcomePanel.Visibility = Visibility.Visible;
        WorkspacePanel.Visibility = Visibility.Collapsed;
        InspectorPanel.Visibility = Visibility.Collapsed;
        InspectorColumn.Width = new GridLength(0);
        Title = "BeyondClone";
    }

    void Show(FolderSession? s)
    {
        if (session != null)
        {
            session.Changed -= OnChanged;
            session.RowsChanged -= OnRowsChanged;
            session.PreviewRequested -= ShowPreview;
        }
        session = s;
        if (s == null)
        {
            Tree.DataContext = null;
            ShowWelcome();
            return;
        }
        s.Changed += OnChanged;
        s.RowsChanged += OnRowsChanged;
        s.PreviewRequested += ShowPreview;
        WelcomePanel.Visibility = Visibility.Collapsed;
        WorkspacePanel.Visibility = Visibility.Visible;
        ApplyInspectorVisibility();
        Tree.DataContext = s;
        SearchBox.Text = s.Search;
        UpdateWorkspace();
    }

    void OnChanged() => UpdateWorkspace();

    void OnRowsChanged()
    {
        if (session == null) return;
        suppressTree = true;
        Tree.SelectedItems.Clear();
        var wanted = session.Selection.ToHashSet();
        foreach (var row in session.Rows)
            if (wanted.Contains(row.Node)) Tree.SelectedItems.Add(row);
        suppressTree = false;
    }

    void ApplyInspectorVisibility()
    {
        // Sotto i 1400 punti di larghezza il pannello dei dettagli lascia spazio all'albero (si può riaprire a mano).
        bool wide = ActualWidth == 0 || ActualWidth >= 1400 || inspectorForced;
        bool show = InspectorToggle.IsChecked == true && session != null && wide;
        InspectorPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        InspectorColumn.Width = show ? new GridLength(310) : new GridLength(0);
    }

    void UpdateWorkspace()
    {
        var s = session;
        if (s == null) return;
        Title = $"{s.Name} – BeyondClone";
        TitleText.Text = s.Name;
        SubtitleText.Text = s.State switch
        {
            ScanState.Done => s.LiveTally.Diffs == 0 ? "Identiche" : $"{Fmt.Number(s.LiveTally.Diffs)} differenze",
            ScanState.Scanning => "Analisi in corso",
            ScanState.Connecting => "Connessione",
            ScanState.Failed => "Errore",
            _ => "",
        };
        SaveProfileButton.Visibility = s.ProfileId == null ? Visibility.Visible : Visibility.Collapsed;
        SaveProfileButton.IsEnabled = s.LeftPath != null && s.RightPath != null;
        RefreshButton.IsEnabled = !s.IsRunning;
        SyncButton.IsEnabled = s.State == ScanState.Done && !s.IsRunning;
        SyncButton.Background = s.Mode.IsMirror() ? UI.MirrorBrush : UI.Accent;
        SyncButton.ToolTip = $"{s.Mode.Title()}: mostra le operazioni e poi le esegue (Ctrl+Invio)";
        BuildCard(LeftCard, Side.Left);
        BuildCard(RightCard, Side.Right);
        ModeButton.Background = s.Mode.IsMirror() ? UI.MirrorBrush : UI.Accent;
        ModeGlyph.Text = s.Mode.Glyph();
        ModeTitle.Text = s.Mode.Title();
        ModeSubtitle.Text = s.ModePlan is { } plan ? (plan.IsEmpty ? "niente da fare" : $"{Fmt.Number(plan.Ops.Count)} operazioni") : " ";
        ModeSubtitle.Foreground = s.ModePlan is { IsEmpty: true } ? UI.SameBrush : UI.Secondary;
        ModeButton.ToolTip = $"{s.Mode.Title()}: {s.Mode.Detail()}\nClic per cambiare modalità o scambiare i lati";
        UpdateFilters();
        UpdateStatus();
        UpdateOverlay();
        BuildInspector();
    }

    // ---------- Schede delle cartelle ----------

    void BuildCard(Border card, Side side)
    {
        var s = session!;
        var path = s.PathOf(side);
        var vol = s.VolumeOf(side);
        bool net = vol?.IsNetwork ?? path?.StartsWith(@"\\") ?? false;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var iconBorder = new Border
        {
            Width = 46, Height = 46, CornerRadius = new CornerRadius(10),
            Background = UI.Tint(net ? UI.NetworkBrush : UI.Accent, 0.15), HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = $"Cartella {side.Label()}: clic sulla scheda per sceglierne un'altra, oppure trascinaci sopra una cartella da Esplora file",
        };
        iconBorder.Child = new TextBlock
        {
            Text = path == null ? "" : vol?.Glyph ?? "", Style = (Style)FindResource("Glyph"), FontSize = 20,
            Foreground = net ? UI.NetworkBrush : UI.Accent,
        };
        grid.Children.Add(iconBorder);

        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(info, 1);
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(new TextBlock
        {
            Text = path != null ? Path.GetFileName(path.TrimEnd('\\')) is { Length: > 0 } n ? n : path : side == Side.Left ? "Cartella sinistra" : "Cartella destra",
            FontSize = 15, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (net && vol?.Server is { } srv)
        {
            titleRow.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(7), Padding = new Thickness(6, 0, 6, 0), Margin = new Thickness(8, 0, 0, 0),
                Background = UI.Tint(UI.NetworkBrush, 0.18), VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = srv.TrimStart('\\').Split('\\')[0], FontSize = 11 },
                ToolTip = "Condivisione di rete: " + srv,
            });
        }
        info.Children.Add(titleRow);
        info.Children.Add(new TextBlock
        {
            Text = path != null ? Path.GetDirectoryName(path.TrimEnd('\\')) ?? path : "Clic per scegliere, oppure trascina qui una cartella",
            Style = (Style)FindResource("Caption"), TextTrimming = TextTrimming.CharacterEllipsis,
            ToolTip = path != null ? path + "\nClic sulla scheda per cambiare cartella" : $"Clic per scegliere la cartella {side.Label()}",
        });
        var metrics = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 0) };
        if (s.Root != null)
        {
            var t = s.LiveTally;
            metrics.Children.Add(new TextBlock
            {
                Text = $"{Fmt.Number(t.Files(side))} file · {Fmt.Size(t.Bytes(side))}{(s.State == ScanState.Done ? "" : "…")}",
                Style = (Style)FindResource("Caption"), FontSize = 11,
            });
        }
        if (vol?.Free is { } free)
        {
            metrics.Children.Add(new TextBlock { Text = $"   ·   {Fmt.Size(free)} liberi su {vol.Name}", Style = (Style)FindResource("Caption"), FontSize = 11 });
            if (vol.Total is > 0)
            {
                double used = 1 - (double)free / vol.Total.Value;
                metrics.Children.Add(new ProgressBar
                {
                    Width = 44, Height = 4, Minimum = 0, Maximum = 1, Value = used, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
                    Foreground = used > 0.9 ? UI.ChangedBrush : used > 0.75 ? UI.MirrorBrush : UI.Accent,
                    ToolTip = $"Spazio occupato: {used:P0}",
                });
            }
        }
        info.Children.Add(metrics);
        grid.Children.Add(info);

        var more = new Button
        {
            Content = "", Style = (Style)FindResource("IconButton"), VerticalAlignment = VerticalAlignment.Center,
            ToolTip = $"Scegli la cartella {side.Label()}, recenti, apri in Esplora file", IsEnabled = !s.IsRunning,
        };
        more.Click += (_, e) =>
        {
            e.Handled = true;
            var menu = new ContextMenu();
            Add(menu, "Scegli cartella…", "", () => ChooseFolder(side));
            Add(menu, "Connetti al server e scegli…", "", () => ConnectAndChoose(side));
            if (app.Settings.RecentFolders.Count > 0)
            {
                var rec = new MenuItem { Header = "Recenti" };
                foreach (var f in app.Settings.RecentFolders) Add(rec, f, "", () => s.SetPath(f, side));
                menu.Items.Add(rec);
            }
            if (path != null)
            {
                menu.Items.Add(new Separator());
                Add(menu, "Apri in Esplora file", "", () => UI.Open(path));
                Add(menu, "Copia percorso", "", () => Clipboard.SetText(path));
            }
            menu.PlacementTarget = more;
            menu.IsOpen = true;
        };
        Grid.SetColumn(more, 2);
        grid.Children.Add(more);
        card.Child = grid;
        card.ToolTip = null;
    }

    void ChooseFolder(Side side)
    {
        if (session == null || session.IsRunning) return;
        if (UI.PickFolder(session.PathOf(side)) is { } f) session.SetPath(f, side);
    }

    void ConnectAndChoose(Side side)
    {
        var w = new ConnectWindow { Owner = this };
        if (w.ShowDialog() == true && w.ConnectedRoot is { } root && session != null && UI.PickFolder(root) is { } f)
            session.SetPath(f, side);
    }

    void Card_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && FindParent<Button>(d) != null) return;
        ChooseFolder(((Border)sender).Tag as string == "Left" ? Side.Left : Side.Right);
    }

    void Card_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    void Card_Drop(object sender, DragEventArgs e)
    {
        if (session == null || session.IsRunning || e.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
        var side = ((Border)sender).Tag as string == "Left" ? Side.Left : Side.Right;
        if (Directory.Exists(files[0])) session.SetPath(files[0], side);
        if (files.Length > 1 && Directory.Exists(files[1])) session.SetPath(files[1], side.Other());
    }

    static T? FindParent<T>(DependencyObject d) where T : DependencyObject
    {
        for (var p = d; p != null; p = VisualTreeHelper.GetParent(p)) if (p is T t) return t;
        return null;
    }

    void Mode_Click(object sender, RoutedEventArgs e)
    {
        if (session == null || session.IsRunning) return;
        var menu = new ContextMenu();
        foreach (var m in Enum.GetValues<SyncMode>())
        {
            var mode = m;
            var item = new MenuItem
            {
                Header = m.Title(), IsCheckable = true, IsChecked = session.Mode == m, ToolTip = m.Detail(),
                Icon = new TextBlock { Text = m.Glyph(), FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 14 },
            };
            item.Click += (_, _) => session.Mode = mode;
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        Add(menu, "Scambia sinistra e destra", "", () => session.SwapSides());
        menu.PlacementTarget = ModeButton;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    // ---------- Filtri ----------

    void BuildFilters()
    {
        foreach (var f in Enum.GetValues<FolderFilter>())
        {
            var filter = f;
            var count = new TextBlock { Margin = new Thickness(6, 0, 0, 0), Foreground = UI.Secondary };
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new TextBlock { Text = f.Glyph(), FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) });
            content.Children.Add(new TextBlock { Text = f.Title() });
            content.Children.Add(count);
            var rb = new RadioButton { Content = content, GroupName = "filtri", Style = (Style)FindResource("PillRadio"), ToolTip = f.Help(), IsChecked = f == FolderFilter.All };
            rb.Checked += (_, _) => { if (session != null) session.Filter = filter; };
            filters[f] = (rb, count);
            FilterPanel.Children.Add(rb);
        }
    }

    void UpdateFilters()
    {
        var s = session!;
        var t = s.LiveTally;
        foreach (var (f, (rb, count)) in filters)
        {
            rb.IsChecked = s.Filter == f;
            int? n = s.Root == null ? null : f switch
            {
                FolderFilter.All => t.Compared,
                FolderFilter.Diffs => t.Diffs,
                FolderFilter.Changed => t.Changed,
                FolderFilter.LeftOnly => t.LeftOnly,
                FolderFilter.RightOnly => t.RightOnly,
                _ => t.Same,
            };
            count.Text = n is { } v ? Fmt.Number(v) : "";
        }
    }

    void Search_TextChanged(object sender, TextChangedEventArgs e)
    {
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (session != null) session.Search = SearchBox.Text;
    }

    // ---------- Barra di stato e sovrapposizioni ----------

    void UpdateStatus()
    {
        var s = session!;
        StatusProgress.Visibility = Visibility.Collapsed;
        StatusStop.Visibility = Visibility.Collapsed;
        StatusRight.Text = "";
        StatusText.Foreground = UI.Primary;
        if (s.Progress is { } p)
        {
            StatusProgress.Visibility = Visibility.Visible;
            StatusProgress.Value = p.Fraction;
            StatusStop.Visibility = Visibility.Visible;
            StatusStop.ToolTip = "Interrompi la sincronizzazione: il file in copia viene annullato, quelli già copiati restano";
            var eta = p.Eta is { } e ? $" · mancano {Fmt.Duration(e)}" : "";
            var err = p.Errors > 0 ? $" · {p.Errors} errori" : "";
            StatusText.Text = $"{(int)(p.Fraction * 100)}% · {Fmt.Size(p.DoneBytes)} di {Fmt.Size(p.TotalBytes)} · {Fmt.Number(p.DoneOps)}/{Fmt.Number(p.TotalOps)} · {Fmt.Speed(p.Speed)}{eta}{err} · {(p.Active.LastOrDefault() ?? p.Phase)}";
            return;
        }
        switch (s.State)
        {
            case ScanState.Scanning or ScanState.Connecting:
                StatusProgress.Visibility = Visibility.Visible;
                StatusProgress.IsIndeterminate = true;
                StatusStop.Visibility = Visibility.Visible;
                StatusStop.ToolTip = "Interrompi l'analisi delle cartelle";
                StatusText.Text = $"Analisi: {Fmt.Number(s.StatDirs)} cartelle, {Fmt.Number(s.StatItems)} elementi · {Fmt.Duration(s.Elapsed)}";
                break;
            case ScanState.Done:
                StatusProgress.IsIndeterminate = false;
                var d = s.LiveTally.Diffs;
                StatusText.Text = (d == 0 ? "Le due cartelle sono identiche" : $"{Fmt.Number(d)} differenze su {Fmt.Number(s.LiveTally.Compared)} elementi")
                                  + (s.ModePlan is { } plan ? $" · {s.Mode.Title()}: {plan.Summary.ToLowerInvariant()}" : "");
                StatusText.Foreground = d == 0 ? UI.SameBrush : UI.Primary;
                StatusRight.Text = (s.StatErrors.Count > 0 ? $"{s.StatErrors.Count} cartelle non leggibili · " : "") +
                                   $"{Fmt.Number(s.StatItems)} elementi in {Fmt.Duration(s.Elapsed)}";
                StatusRight.ToolTip = s.StatErrors.Count > 0 ? string.Join("\n", s.StatErrors.Take(30)) : "Tempo impiegato dall'analisi";
                break;
            case ScanState.Failed:
                StatusText.Text = s.FailMessage ?? "";
                StatusText.Foreground = UI.ChangedBrush;
                break;
            default:
                StatusText.Text = "Scegli le due cartelle da confrontare";
                break;
        }
    }

    void UpdateOverlay()
    {
        var s = session!;
        OverlayProgress.Visibility = Visibility.Collapsed;
        OverlayButton.Visibility = Visibility.Collapsed;
        Overlay.Visibility = Visibility.Visible;
        switch (s.State)
        {
            case ScanState.Idle:
                OverlayGlyph.Text = "";
                OverlayTitle.Text = "Scegli le due cartelle";
                OverlayText.Text = "Clic sulle schede in alto, oppure trascinaci sopra una cartella da Esplora file.";
                break;
            case ScanState.Connecting:
                OverlayGlyph.Text = "";
                OverlayTitle.Text = "Connessione alle cartelle…";
                OverlayText.Text = "";
                OverlayProgress.Visibility = Visibility.Visible;
                break;
            case ScanState.Failed:
                OverlayGlyph.Text = "";
                OverlayTitle.Text = "Confronto non disponibile";
                OverlayText.Text = s.FailMessage ?? "";
                OverlayButton.Visibility = Visibility.Visible;
                break;
            default:
                if (s.Root is { Listed: true } && s.Rows.Count == 0)
                {
                    bool plain = s.Filter == FolderFilter.All && s.Search.Length == 0;
                    OverlayGlyph.Text = plain ? "" : "";
                    OverlayTitle.Text = plain ? "Cartelle vuote" : "Nessun elemento";
                    OverlayText.Text = plain ? "" : $"Nessun elemento corrisponde al filtro «{s.Filter.Title()}»{(s.Search.Length > 0 ? " e alla ricerca" : "")}.";
                }
                else Overlay.Visibility = Visibility.Collapsed;
                break;
        }
    }

    // ---------- Ispettore ----------

    TextBlock Text(string text, double size = 13, bool bold = false, Brush? brush = null, bool wrap = true) => new()
    {
        Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = brush ?? UI.Primary, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, Margin = new Thickness(0, 0, 0, 4),
    };

    Button ActionButton(string glyph, string label, string tip, Action action, bool enabled = true)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(new TextBlock { Text = glyph, FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        sp.Children.Add(new TextBlock { Text = label });
        var b = new Button { Content = sp, Margin = new Thickness(0, 0, 6, 6), Padding = new Thickness(10, 4, 10, 4), ToolTip = tip, IsEnabled = enabled, HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += (_, _) => action();
        return b;
    }

    static UIElement DiffBar(Tally t)
    {
        var g = new Grid { Height = 8, Margin = new Thickness(0, 6, 0, 8), ToolTip = $"Verde: uguali · rosso: modificati · viola: presenti da un solo lato" };
        double total = Math.Max(1, t.Compared);
        void Seg(double v, Brush b)
        {
            if (v <= 0) return;
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(v / total, 0.01), GridUnitType.Star) });
            var r = new Border { Background = b };
            Grid.SetColumn(r, g.ColumnDefinitions.Count - 1);
            g.Children.Add(r);
        }
        Seg(t.Same, UI.SameBrush);
        Seg(t.Changed, UI.ChangedBrush);
        Seg(t.LeftOnly + t.RightOnly, UI.OrphanBrush);
        return new Border { CornerRadius = new CornerRadius(4), ClipToBounds = true, Child = g };
    }

    void BuildInspector()
    {
        var s = session!;
        var c = InspectorContent;
        c.Children.Clear();
        var sel = s.Selection;
        if (sel.Count == 1) NodeDetail(c, sel[0]);
        else if (sel.Count > 1)
        {
            c.Children.Add(Text($"{sel.Count} elementi selezionati", 15, true));
            long l = sel.Sum(n => n.IsDir ? n.Tally.LeftBytes : n.Left?.Size ?? 0), r = sel.Sum(n => n.IsDir ? n.Tally.RightBytes : n.Right?.Size ?? 0);
            c.Children.Add(Text($"Sinistra: {Fmt.Size(l)} · Destra: {Fmt.Size(r)}", 12, brush: UI.Secondary));
            Actions(c, sel);
        }
        else Overview(c);
    }

    void Overview(StackPanel c)
    {
        var s = session!;
        var t = s.LiveTally;
        c.Children.Add(Text("Riepilogo", 15, true));
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition());
        void Row(int i, string k, string a, string b, Brush? brush = null)
        {
            g.RowDefinitions.Add(new RowDefinition());
            var kt = Text(k, 12, brush: UI.Secondary); Grid.SetRow(kt, i); g.Children.Add(kt);
            var at = Text(a, 12, i == 0, brush ?? UI.Primary); Grid.SetRow(at, i); Grid.SetColumn(at, 1); g.Children.Add(at);
            var bt = Text(b, 12, i == 0, brush ?? UI.Primary); Grid.SetRow(bt, i); Grid.SetColumn(bt, 2); g.Children.Add(bt);
        }
        Row(0, "", "Sinistra", "Destra");
        Row(1, "File", Fmt.Number(t.LeftFiles), Fmt.Number(t.RightFiles));
        Row(2, "Dimensione", Fmt.Size(t.LeftBytes), Fmt.Size(t.RightBytes));
        Row(3, "Solo qui", Fmt.Number(t.LeftOnly), Fmt.Number(t.RightOnly), UI.OrphanBrush);
        Row(4, "Più recenti", Fmt.Number(t.LeftNewer), Fmt.Number(t.RightNewer), UI.ChangedBrush);
        c.Children.Add(g);
        if (t.Compared > 0) c.Children.Add(DiffBar(t));
        c.Children.Add(new Separator { Margin = new Thickness(0, 6, 0, 10) });
        c.Children.Add(Text(s.Mode.Title(), 13, true));
        c.Children.Add(Text(s.Mode.Detail(), 12, brush: UI.Secondary));
        if (s.ModePlan is { } plan) c.Children.Add(Text(plan.Summary, 13, brush: plan.IsEmpty ? UI.SameBrush : UI.Primary));
        c.Children.Add(Text("Eliminati e sovrascritti: " + s.DeleteMode.Title().ToLowerInvariant(), 12, brush: s.DeleteMode == DeleteMode.Permanent ? UI.ChangedBrush : UI.Secondary));
        if (s.LastRun is { } run)
        {
            c.Children.Add(new Separator { Margin = new Thickness(0, 6, 0, 10) });
            c.Children.Add(Text("Ultima esecuzione", 13, true));
            c.Children.Add(Text(run.Summary, 12));
            foreach (var n in run.Notes) c.Children.Add(Text(n, 12, brush: UI.MirrorBrush));
            var wrap = new WrapPanel();
            if (run.LogPath is { } log) wrap.Children.Add(ActionButton("", "Apri registro", "Apri il registro dettagliato dell'ultima esecuzione", () => UI.Open(log)));
            if (run.ArchiveFolders.FirstOrDefault() is { } a) wrap.Children.Add(ActionButton("", "Apri archivio", "Apri la cartella con i file eliminati o sovrascritti dall'ultima esecuzione", () => UI.Open(a)));
            c.Children.Add(wrap);
            if (run.Errors.Count > 0) c.Children.Add(Text(string.Join("\n", run.Errors.Take(8)), 11, brush: UI.ChangedBrush));
        }
        c.Children.Add(new Separator { Margin = new Thickness(0, 6, 0, 10) });
        c.Children.Add(ActionButton("", "Cartella dei registri", "Apri la cartella con i registri di tutte le esecuzioni", () =>
        {
            Directory.CreateDirectory(SyncLog.Folder);
            UI.Open(SyncLog.Folder);
        }));
    }

    void NodeDetail(StackPanel c, FolderNode n)
    {
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(new Image { Source = ShellIcons.For(n.Left ?? n.Right), Width = 32, Height = 32, Margin = new Thickness(0, 0, 10, 0) });
        var hs = new StackPanel();
        hs.Children.Add(Text(n.Name, 15, true));
        var (label, brush) = n.IsDir && !n.Complete ? ("In analisi", UI.Secondary) : n.Status switch
        {
            NodeStatus.Same => ("Uguali", UI.SameBrush),
            NodeStatus.Different => n.TypeMismatch ? ("File e cartella", UI.MismatchBrush) : (n.IsDir ? "Contiene differenze" : "Diversi", UI.ChangedBrush),
            NodeStatus.LeftNewer => ("Più recente a sinistra", UI.ChangedBrush),
            NodeStatus.RightNewer => ("Più recente a destra", UI.ChangedBrush),
            NodeStatus.LeftOnly => ("Solo a sinistra", UI.OrphanBrush),
            NodeStatus.RightOnly => ("Solo a destra", UI.OrphanBrush),
            _ => ("In analisi", UI.Secondary),
        };
        hs.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8), Padding = new Thickness(7, 1, 7, 1), Background = UI.Tint(brush, 0.15), HorizontalAlignment = HorizontalAlignment.Left,
            Child = new TextBlock { Text = label, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = brush },
        });
        head.Children.Add(hs);
        c.Children.Add(head);
        c.Children.Add(Text(n.RelPath, 11, brush: UI.Secondary));
        SideBox(c, "Sinistra", n.Left, n, Side.Left);
        SideBox(c, "Destra", n.Right, n, Side.Right);
        if (n.IsDir && n.Complete)
        {
            c.Children.Add(DiffBar(n.Tally));
            c.Children.Add(Text($"{Fmt.Number(n.Tally.Diffs)} differenze su {Fmt.Number(n.Tally.Compared)} elementi", 12, brush: UI.Secondary));
        }
        Actions(c, [n]);
    }

    void SideBox(StackPanel c, string title, FileEntry? info, FolderNode n, Side side)
    {
        var box = new StackPanel();
        box.Children.Add(Text(title, 11, true, UI.Secondary));
        if (info == null) box.Children.Add(Text("Non presente", 13, brush: UI.OrphanBrush));
        else
        {
            if (info.IsDir)
            {
                box.Children.Add(Text(n.Complete ? $"{Fmt.Number(n.Tally.Files(side))} file · {Fmt.Size(n.Tally.Bytes(side))}" : "analisi…", 12));
            }
            else
            {
                box.Children.Add(Text($"{Fmt.Size(info.Size)} ({Fmt.Number(info.Size)} byte)", 12));
                bool newer = (side == Side.Left && n.Status == NodeStatus.LeftNewer) || (side == Side.Right && n.Status == NodeStatus.RightNewer);
                box.Children.Add(Text("Modificato: " + Fmt.DateLong(info.ModifiedUtc), 12, newer, newer ? UI.ChangedBrush : UI.Primary));
            }
            var link = new Button
            {
                Content = new TextBlock { Text = info.Path, FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = UI.Secondary },
                Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Left,
                ToolTip = "Mostra in Esplora file", Cursor = Cursors.Hand,
            };
            link.Click += (_, _) => UI.Reveal(info.Path);
            box.Children.Add(link);
        }
        c.Children.Add(new Border { Style = (Style)FindResource("Card"), Padding = new Thickness(10), Margin = new Thickness(0, 6, 0, 0), Child = box });
    }

    void Actions(StackPanel c, List<FolderNode> nodes)
    {
        var s = session!;
        bool hasL = nodes.Any(n => n.Left != null), hasR = nodes.Any(n => n.Right != null), busy = s.IsRunning;
        var w = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        w.Children.Add(ActionButton("", "Copia a sinistra", "Copia la selezione da destra a sinistra (Alt+←), dopo un'anteprima", () => s.PrepareCopy(nodes, Side.Left), hasR && !busy));
        w.Children.Add(ActionButton("", "Copia a destra", "Copia la selezione da sinistra a destra (Alt+→), dopo un'anteprima", () => s.PrepareCopy(nodes, Side.Right), hasL && !busy));
        w.Children.Add(ActionButton("", "Elimina sx", "Elimina la selezione dal lato sinistro, dopo un'anteprima", () => s.PrepareDelete(nodes, Side.Left), hasL && !busy));
        w.Children.Add(ActionButton("", "Elimina dx", "Elimina la selezione dal lato destro, dopo un'anteprima", () => s.PrepareDelete(nodes, Side.Right), hasR && !busy));
        w.Children.Add(ActionButton("", "Escludi", "Aggiunge questi nomi alle esclusioni: non verranno più confrontati né copiati", () => s.Exclude(nodes)));
        if (nodes is [{ IsDir: false, Left: { } l, Right: { } r }])
            w.Children.Add(ActionButton("", "Confronta contenuto", "Apri il confronto del contenuto dei due file", () => OpenFiles(l.Path, r.Path)));
        c.Children.Add(w);
    }

    // ===================== Albero =====================

    List<FolderNode> SelectedNodes => Tree.SelectedItems.OfType<RowVM>().Select(r => r.Node).ToList();

    void Tree_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressTree || session == null) return;
        session.SetSelection(SelectedNodes);
    }

    void Expander_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: RowVM row }) session?.Toggle(row.Node);
        e.Handled = true;
    }

    void Tree_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && FindParent<GridViewColumnHeader>(d) != null) return;
        if (Tree.SelectedItem is not RowVM row || session == null) return;
        var n = row.Node;
        if (n.IsDir) session.Toggle(n);
        else if (n is { Left: { } l, Right: { } r }) OpenFiles(l.Path, r.Path);
        else if ((n.Left ?? n.Right) is { } only) UI.Open(only.Path);
    }

    void Tree_KeyDown(object sender, KeyEventArgs e)
    {
        if (session == null) return;
        var nodes = SelectedNodes;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) && nodes.Count > 0)
        {
            if (key == Key.Right) { session.PrepareCopy(nodes, Side.Right); e.Handled = true; }
            if (key == Key.Left) { session.PrepareCopy(nodes, Side.Left); e.Handled = true; }
            return;
        }
        if (nodes.Count == 1 && nodes[0].IsDir)
        {
            if (key == Key.Right && !nodes[0].Expanded) { session.Toggle(nodes[0], true); e.Handled = true; }
            if (key == Key.Left && nodes[0].Expanded) { session.Toggle(nodes[0], false); e.Handled = true; }
            if (key == Key.Enter) { session.Toggle(nodes[0]); e.Handled = true; }
        }
    }

    void Tree_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = Tree.ContextMenu!;
        menu.Items.Clear();
        var nodes = SelectedNodes;
        if (session == null || nodes.Count == 0) { e.Handled = true; return; }
        var s = session;
        bool hasL = nodes.Any(n => n.Left != null), hasR = nodes.Any(n => n.Right != null), busy = s.IsRunning;
        Add(menu, "Copia a destra   Alt+→", "", () => s.PrepareCopy(nodes, Side.Right), hasL && !busy);
        Add(menu, "Copia a sinistra   Alt+←", "", () => s.PrepareCopy(nodes, Side.Left), hasR && !busy);
        menu.Items.Add(new Separator());
        Add(menu, "Elimina a sinistra…", "", () => s.PrepareDelete(nodes, Side.Left), hasL && !busy);
        Add(menu, "Elimina a destra…", "", () => s.PrepareDelete(nodes, Side.Right), hasR && !busy);
        menu.Items.Add(new Separator());
        Add(menu, nodes.Count == 1 ? $"Escludi «{nodes[0].Name}» dal confronto" : $"Escludi {nodes.Count} nomi dal confronto", "", () => s.Exclude(nodes));
        menu.Items.Add(new Separator());
        if (nodes is [{ IsDir: false, Left: { } l, Right: { } r }])
            Add(menu, "Confronta il contenuto dei due file", "", () => OpenFiles(l.Path, r.Path));
        Add(menu, "Mostra a sinistra in Esplora file", "", () => { if (nodes.FirstOrDefault(n => n.Left != null)?.Left is { } x) UI.Reveal(x.Path); }, hasL);
        Add(menu, "Mostra a destra in Esplora file", "", () => { if (nodes.FirstOrDefault(n => n.Right != null)?.Right is { } x) UI.Reveal(x.Path); }, hasR);
        Add(menu, "Copia percorso relativo", "", () => Clipboard.SetText(string.Join(Environment.NewLine, nodes.Select(n => n.RelPath))));
    }

    void OpenFiles(string l, string r)
    {
        var w = FileKindDetector.Open(l, r);
        w.Owner = this;
        w.Show();
    }

    /// <summary>Le due colonne dei nomi si dividono lo spazio libero: tutte le colonne restano visibili.</summary>
    void FitColumns()
    {
        if (Tree.View is not GridView gv || gv.Columns.Count < 7) return;
        double avail = Tree.ActualWidth - SystemParameters.VerticalScrollBarWidth - 8;
        // Se lo spazio è poco si nascondono prima le date, poi le dimensioni: i nomi restano leggibili.
        bool dates = avail - (104 + 120) * 2 - 46 >= 2 * 190;
        bool sizes = avail - (dates ? 120 * 2 : 0) - 104 * 2 - 46 >= 2 * 150;
        gv.Columns[1].Width = gv.Columns[5].Width = sizes ? 104 : 0;
        gv.Columns[2].Width = gv.Columns[6].Width = dates ? 120 : 0;
        double free = avail - (sizes ? 208 : 0) - (dates ? 240 : 0) - 46;
        double name = Math.Max(120, Math.Floor(free / 2));
        gv.Columns[0].Width = name;
        gv.Columns[4].Width = name;
    }

    // ===================== Comandi =====================

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.F5 && session != null && !session.IsRunning) { session.Rescan(); e.Handled = true; }
        else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control && session != null) { session.PrepareSync(); e.Handled = true; }
        else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { SearchBox.Focus(); SearchBox.SelectAll(); e.Handled = true; }
        base.OnPreviewKeyDown(e);
    }

    void ExpandAll_Click(object sender, RoutedEventArgs e) => session?.ExpandAll(true);
    void CollapseAll_Click(object sender, RoutedEventArgs e) => session?.ExpandAll(false);
    void Refresh_Click(object sender, RoutedEventArgs e) => session?.Rescan();
    void Swap_Click(object sender, RoutedEventArgs e) => session?.SwapSides();
    void Sync_Click(object sender, RoutedEventArgs e) => session?.PrepareSync();
    void SaveProfile_Click(object sender, RoutedEventArgs e) { if (session != null) SaveAsProfile(session); }

    void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (session?.IsRunning == true) session.StopRun();
        else session?.StopScan();
    }

    bool inspectorForced;

    void InspectorToggle_Click(object sender, RoutedEventArgs e)
    {
        inspectorForced = ActualWidth < 1400 && InspectorToggle.IsChecked == true;
        app.Settings.ShowInspector = InspectorToggle.IsChecked == true;
        app.SaveSettings();
        ApplyInspectorVisibility();
    }

    void Options_Click(object sender, RoutedEventArgs e)
    {
        if (session == null) return;
        var w = new OptionsWindow(session) { Owner = this };
        w.ShowDialog();
    }

    void ShowPreview(PlanRequest req)
    {
        var s = session;
        var w = new PlanPreviewWindow(req) { Owner = this };
        if (w.ShowDialog() == true) s?.Run(req.Plan);
    }

    void SaveAsProfile(FolderSession s) => EditProfile(s.MakeProfile(), s);

    void EditProfile(SyncProfile p, FolderSession? replacing = null)
    {
        var w = new ProfileEditorWindow(p) { Owner = this };
        if (w.ShowDialog() != true) return;
        var saved = w.Profile;
        if (replacing != null) app.Close(replacing.Id);
        app.Close(saved.Id);
        app.SaveProfile(saved);
        Select("profile:" + saved.Id);
    }

    void NewProfile_Click(object sender, RoutedEventArgs e) => EditProfile(new SyncProfile());
    void NewCompare_Click(object sender, RoutedEventArgs e) => Select("adhoc:" + app.OpenPair(null, null).Id);

    void Connect_Click(object sender, RoutedEventArgs e)
    {
        var w = new ConnectWindow { Owner = this };
        if (w.ShowDialog() == true) _ = RefreshVolumes();
    }

    void Add_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        Add(menu, "Nuovo profilo di sincronizzazione…", "", () => NewProfile_Click(this, e));
        Add(menu, "Nuovo confronto al volo", "", () => NewCompare_Click(this, e));
        menu.Items.Add(new Separator());
        Add(menu, "Connetti al server…", "", () => Connect_Click(this, e));
        menu.PlacementTarget = AddButton;
        menu.Placement = PlacementMode.Top;
        menu.IsOpen = true;
    }

    void SyncAll_Click(object sender, RoutedEventArgs e)
    {
        if (app.Profiles.Count == 0)
        {
            UI.Info("Sincronizza tutti", "Non ci sono profili. Crea prima un profilo di sincronizzazione.");
            return;
        }
        new SyncAllWindow { Owner = this }.ShowDialog();
    }
}
