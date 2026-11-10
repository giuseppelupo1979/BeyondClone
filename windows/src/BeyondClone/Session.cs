using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using BeyondClone.Core;

namespace BeyondClone;

public enum FolderFilter { All, Diffs, Changed, LeftOnly, RightOnly, Same }

public static class FolderFilterExtensions
{
    public static string Title(this FolderFilter f) => f switch
    {
        FolderFilter.All => "Tutto",
        FolderFilter.Diffs => "Differenze",
        FolderFilter.Changed => "Modificati",
        FolderFilter.LeftOnly => "Solo a sinistra",
        FolderFilter.RightOnly => "Solo a destra",
        _ => "Uguali",
    };

    public static string Help(this FolderFilter f) => f switch
    {
        FolderFilter.All => "Mostra tutto",
        FolderFilter.Diffs => "Mostra solo le differenze: modificati e presenti da un solo lato",
        FolderFilter.Changed => "Mostra solo i file presenti su entrambi i lati ma diversi",
        FolderFilter.LeftOnly => "Mostra solo gli elementi presenti soltanto a sinistra",
        FolderFilter.RightOnly => "Mostra solo gli elementi presenti soltanto a destra",
        _ => "Mostra solo gli elementi uguali",
    };

    public static string Glyph(this FolderFilter f) => f switch
    {
        FolderFilter.All => "",
        FolderFilter.Diffs => "",
        FolderFilter.Changed => "",
        FolderFilter.LeftOnly => "",
        FolderFilter.RightOnly => "",
        _ => "",
    };

    public static bool Matches(this FolderFilter f, NodeStatus s) => f switch
    {
        FolderFilter.All => true,
        FolderFilter.Diffs => s != NodeStatus.Same,
        FolderFilter.Changed => s.IsChanged(),
        FolderFilter.LeftOnly => s == NodeStatus.LeftOnly,
        FolderFilter.RightOnly => s == NodeStatus.RightOnly,
        _ => s == NodeStatus.Same,
    };
}

public enum ScanState { Idle, Connecting, Scanning, Done, Failed }

/// <summary>Collezione che si aggiorna con un'unica notifica (lista virtualizzata veloce).</summary>
public sealed class RowList : ObservableCollection<RowVM>
{
    public void ReplaceAll(List<RowVM> rows)
    {
        Items.Clear();
        foreach (var r in rows) Items.Add(r);
        OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs("Count"));
        OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}

/// <summary>Un confronto tra due cartelle: analisi progressiva, filtri, sincronizzazione.</summary>
public sealed class FolderSession : ObservableObject
{
    public Guid Id { get; }
    public Guid? ProfileId { get; }

    string name = "Nuovo confronto";
    public string Name { get => name; set { if (Set(ref name, value)) Persist(); } }

    public string? LeftPath { get; private set; }
    public string? RightPath { get; private set; }
    public string LeftServer { get; set; } = "";
    public string RightServer { get; set; } = "";

    DirOptions options;
    public DirOptions Options => options;

    SyncMode mode;
    public SyncMode Mode { get => mode; set { if (Set(ref mode, value)) { Persist(); RefreshModePlan(); } } }

    DeleteMode deleteMode;
    public DeleteMode DeleteMode { get => deleteMode; set { if (Set(ref deleteMode, value)) Persist(); } }

    public FolderNode? Root { get; private set; }
    public ScanState State { get; private set; }
    public string? FailMessage { get; private set; }
    public int StatDirs { get; private set; }
    public int StatItems { get; private set; }
    public List<string> StatErrors { get; } = [];
    public DateTime ScanStarted { get; private set; } = DateTime.UtcNow;
    public DateTime? ScanFinished { get; private set; }
    public TimeSpan Elapsed => (ScanFinished ?? DateTime.UtcNow) - ScanStarted;
    public Tally LiveTally { get; private set; }
    public SyncPlan? ModePlan { get; private set; }
    public VolumeInfo? LeftVolume { get; private set; }
    public VolumeInfo? RightVolume { get; private set; }

    FolderFilter filter;
    public FolderFilter Filter { get => filter; set { if (Set(ref filter, value)) BumpView(); } }

    string search = "";
    public string Search { get => search; set { if (Set(ref search, value ?? "")) BumpView(); } }

    public List<FolderNode> Selection { get; private set; } = [];
    public SyncProgress? Progress { get; private set; }
    public SyncResult? LastRun { get; private set; }
    public DateTime? LastRunDate { get; private set; }

    public RowList Rows { get; } = [];

    /// <summary>Lo stato è cambiato (contatori, fase, piano): ridisegnare intestazione, barra, ispettore.</summary>
    public event Action? Changed;
    /// <summary>L'albero visibile è cambiato.</summary>
    public event Action? RowsChanged;

    int viewGen;
    int gen;
    readonly Queue<FolderNode> queue = new();
    readonly Stack<FolderNode> urgent = new();
    int inFlight;
    bool dirty;
    readonly DispatcherTimer refreshTimer;
    CancellationTokenSource scanCts = new();
    CancellationTokenSource runCts = new();
    readonly List<TaskCompletionSource<bool>> waiters = [];
    Tally pendingTally;
    bool loading = true;

    /// <summary>Letture contemporanee: utile sulle condivisioni di rete, dove conta la latenza.</summary>
    const int MaxInFlight = 12;

    FolderSession(Guid id, Guid? profileId)
    {
        Id = id;
        ProfileId = profileId;
        options = new DirOptions();
        refreshTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(150), DispatcherPriority.Background, (_, _) => Flush(), Dispatcher.CurrentDispatcher);
    }

    public static FolderSession FromProfile(SyncProfile p)
    {
        var s = new FolderSession(p.Id, p.Id)
        {
            name = p.Name,
            LeftPath = p.Left.Length > 0 ? p.Left : null,
            RightPath = p.Right.Length > 0 ? p.Right : null,
            LeftServer = p.LeftServer,
            RightServer = p.RightServer,
            options = p.Options.Clone(),
            mode = p.Mode,
            deleteMode = p.DeleteMode,
        };
        s.loading = false;
        s.Rescan();
        return s;
    }

    public static FolderSession Adhoc(string? left, string? right)
    {
        var s = new FolderSession(Guid.NewGuid(), null) { LeftPath = left, RightPath = right };
        s.loading = false;
        s.UpdateName();
        s.Rescan();
        return s;
    }

    public SyncProfile? Profile => ProfileId is { } id ? AppState.Instance.Profile(id) : null;
    public bool IsRunning => Progress != null;
    public bool IsScanning => State is ScanState.Scanning or ScanState.Connecting;
    public Roots? Roots => LeftPath != null && RightPath != null ? new Roots(LeftPath, RightPath) : null;
    public string? PathOf(Side s) => s == Side.Left ? LeftPath : RightPath;
    public VolumeInfo? VolumeOf(Side s) => s == Side.Left ? LeftVolume : RightVolume;

    void NotifyChanged() => Changed?.Invoke();

    void UpdateName()
    {
        if (ProfileId != null) return;
        var l = LeftPath != null ? Path.GetFileName(LeftPath.TrimEnd('\\')) : "…";
        var r = RightPath != null ? Path.GetFileName(RightPath.TrimEnd('\\')) : "…";
        name = LeftPath == null && RightPath == null ? "Nuovo confronto" : $"{l} ↔ {r}";
        Raise(nameof(Name));
    }

    void Persist()
    {
        if (loading || ProfileId is not { } id || AppState.Instance.Profile(id) is not { } p) return;
        p.Name = name;
        p.Left = LeftPath ?? "";
        p.Right = RightPath ?? "";
        p.LeftServer = LeftServer;
        p.RightServer = RightServer;
        p.Options = options.Clone();
        p.Mode = mode;
        p.DeleteMode = deleteMode;
        AppState.Instance.SaveProfile(p);
    }

    public void SetOptions(DirOptions o)
    {
        var rescan = o.ScanKey != options.ScanKey;
        options = o.Clone();
        Persist();
        if (rescan) Rescan(); else NotifyChanged();
    }

    public void SetPath(string path, Side side)
    {
        if (side == Side.Left) LeftPath = path; else RightPath = path;
        var share = NasConnect.ShareRoot(path);
        if (share != null) { if (side == Side.Left) LeftServer = share; else RightServer = share; }
        AppState.Instance.AddRecentFolder(path);
        UpdateName();
        Persist();
        Rescan();
    }

    public void SwapSides()
    {
        if (IsRunning) return;
        (LeftPath, RightPath) = (RightPath, LeftPath);
        (LeftServer, RightServer) = (RightServer, LeftServer);
        mode = mode switch
        {
            SyncMode.UpdateLeft => SyncMode.UpdateRight,
            SyncMode.UpdateRight => SyncMode.UpdateLeft,
            SyncMode.MirrorLeft => SyncMode.MirrorRight,
            SyncMode.MirrorRight => SyncMode.MirrorLeft,
            _ => mode,
        };
        Raise(nameof(Mode));
        UpdateName();
        Persist();
        Rescan();
    }

    // ---------- Analisi progressiva ----------

    public void Rescan()
    {
        scanCts.Cancel();
        scanCts = new CancellationTokenSource();
        gen++;
        int g = gen;
        queue.Clear();
        urgent.Clear();
        inFlight = 0;
        Selection = [];
        ModePlan = null;
        LiveTally = pendingTally = new Tally();
        StatDirs = StatItems = 0;
        StatErrors.Clear();
        ScanStarted = DateTime.UtcNow;
        ScanFinished = null;
        FailMessage = null;
        if (LeftPath == null || RightPath == null)
        {
            Root = null;
            State = ScanState.Idle;
            _ = RefreshVolumes();
            BumpView();
            return;
        }
        if (ProfileId == null) AppState.Instance.AddRecent(LeftPath, RightPath);
        State = ScanState.Connecting;
        NotifyChanged();
        string l = LeftPath, r = RightPath;
        _ = StartAsync(g, l, r);
    }

    async Task StartAsync(int g, string l, string r)
    {
        try
        {
            foreach (var (path, server) in new[] { (l, LeftServer), (r, RightServer) })
            {
                if (await NasConnect.ReachableAsync(path)) continue;
                if (server.Trim().Length == 0) throw SyncError.Unreachable(path);
                var owner = UI.Handle(Application.Current.MainWindow);
                await Task.Run(() => NasConnect.Connect(server, owner));
                if (!await NasConnect.ReachableAsync(path, 8000)) throw new SyncError($"Cartella non trovata dopo il collegamento: {path}");
            }
        }
        catch (Exception e)
        {
            if (g == gen) Fail(e.Message);
            return;
        }
        if (g != gen) return;
        _ = RefreshVolumes();
        var node = FolderNode.Root(l, r);
        Root = node;
        State = ScanState.Scanning;
        ScanStarted = DateTime.UtcNow;
        queue.Enqueue(node);
        Pump();
        BumpView();
    }

    void Fail(string message)
    {
        Root = null;
        State = ScanState.Failed;
        FailMessage = message;
        ResolveWaiters(false);
        BumpView();
    }

    async Task RefreshVolumes()
    {
        string? l = LeftPath, r = RightPath;
        var lv = l == null ? null : await Task.Run(() => VolumeInfo.Of(l));
        var rv = r == null ? null : await Task.Run(() => VolumeInfo.Of(r));
        if (l != LeftPath || r != RightPath) return;
        LeftVolume = lv;
        RightVolume = rv;
        NotifyChanged();
    }

    FolderNode? NextNode()
    {
        while (urgent.Count > 0)
        {
            var n = urgent.Pop();
            if (!n.Requested) { n.Requested = true; return n; }
        }
        while (queue.Count > 0)
        {
            var n = queue.Dequeue();
            if (!n.Requested) { n.Requested = true; return n; }
        }
        return null;
    }

    void Pump()
    {
        var o = options.Clone();
        var patterns = o.ExcludeList;
        var ct = scanCts.Token;
        int g = gen;
        var dispatcher = Dispatcher.CurrentDispatcher;
        while (inFlight < MaxInFlight && NextNode() is { } node)
        {
            inFlight++;
            string? l = node.LeftDirPath, r = node.RightDirPath, rel = node.RelPath;
            Task.Run(() =>
            {
                var res = DirLister.List(l, r, rel, o, patterns, ct);
                dispatcher.BeginInvoke(DispatcherPriority.Normal, () => Merge(node, res, g));
            });
        }
    }

    void Merge(FolderNode node, ListResult res, int g)
    {
        if (g != gen) return;
        inFlight--;
        var subs = Tree.Attach(node, res);
        StatDirs++;
        StatItems += res.Entries.Count;
        if (res.Error != null) StatErrors.Add(res.Error);
        foreach (var c in node.Children) if (!c.IsDir) pendingTally.Add(c.Tally);
        if (subs.Count == 0 && Tree.Finish(node)) FinishScan();
        else
        {
            foreach (var s in subs) queue.Enqueue(s);
            Pump();
        }
        MarkDirty();
    }

    void FinishScan()
    {
        State = ScanState.Done;
        ScanFinished = DateTime.UtcNow;
        if (Root != null) pendingTally = Root.Tally;
        LiveTally = pendingTally;
        RefreshModePlan();
        BumpView();
        ResolveWaiters(true);
    }

    void ResolveWaiters(bool ok)
    {
        foreach (var w in waiters) w.TrySetResult(ok);
        waiters.Clear();
    }

    public Task<bool> WaitForScanAsync()
    {
        if (State == ScanState.Done) return Task.FromResult(true);
        if (State is ScanState.Failed or ScanState.Idle) return Task.FromResult(false);
        var t = new TaskCompletionSource<bool>();
        waiters.Add(t);
        return t.Task;
    }

    public void StopScan()
    {
        if (!IsScanning) return;
        scanCts.Cancel();
        gen++;
        State = ScanState.Failed;
        FailMessage = "Analisi interrotta";
        ResolveWaiters(false);
        BumpView();
    }

    /// <summary>Le cartelle che apri vengono lette per prime.</summary>
    public void Prioritize(FolderNode node)
    {
        if (!node.IsDir || node.Requested) return;
        urgent.Push(node);
        Pump();
    }

    void MarkDirty()
    {
        dirty = true;
        if (!refreshTimer.IsEnabled) refreshTimer.Start();
    }

    void Flush()
    {
        refreshTimer.Stop();
        if (!dirty) return;
        dirty = false;
        if (State == ScanState.Scanning) LiveTally = pendingTally;
        BumpView();
    }

    void BumpView()
    {
        viewGen++;
        RebuildRows();
        NotifyChanged();
    }

    // ---------- Vista filtrata ----------

    public List<FolderNode> VisibleChildren(FolderNode node)
    {
        if (node.ViewGen == viewGen) return node.ViewChildren;
        var kids = filter == FolderFilter.All && search.Length == 0 ? node.Children : node.Children.Where(IsVisible).ToList();
        node.ViewChildren = kids;
        node.ViewGen = viewGen;
        return kids;
    }

    bool NameMatches(FolderNode n) => search.Length == 0 || n.Name.Contains(search, StringComparison.CurrentCultureIgnoreCase);

    bool IsVisible(FolderNode n)
    {
        if (n.IsDir)
        {
            if (!n.Complete) return true;
            if (VisibleChildren(n).Count > 0) return true;
            bool leaf = n.Children.Count == 0 || n.Status.IsOrphan() || n.TypeMismatch;
            return leaf && filter.Matches(n.Status) && NameMatches(n);
        }
        return filter.Matches(n.Status) && NameMatches(n);
    }

    void RebuildRows()
    {
        var rows = new List<RowVM>();
        void Visit(FolderNode parent, int depth)
        {
            foreach (var n in VisibleChildren(parent))
            {
                rows.Add(new RowVM(this, n, depth));
                if (n.IsDir && n.Expanded) Visit(n, depth + 1);
            }
        }
        if (Root != null) Visit(Root, 0);
        Rows.ReplaceAll(rows);
        RowsChanged?.Invoke();
    }

    public bool IsExpandable(FolderNode n) => n.IsDir && (!n.Listed || VisibleChildren(n).Count > 0);

    public void Toggle(FolderNode n, bool? expand = null)
    {
        if (!n.IsDir) return;
        n.Expanded = expand ?? !n.Expanded;
        if (n.Expanded && !n.Listed) Prioritize(n);
        RebuildRows();
    }

    public void ExpandAll(bool expand)
    {
        void Visit(FolderNode p)
        {
            foreach (var c in p.Children.Where(c => c.IsDir))
            {
                c.Expanded = expand;
                Visit(c);
            }
        }
        if (Root != null) Visit(Root);
        RebuildRows();
    }

    public void SetSelection(List<FolderNode> nodes)
    {
        Selection = nodes;
        NotifyChanged();
    }

    // ---------- Piani e sincronizzazione ----------

    void RefreshModePlan()
    {
        ModePlan = State == ScanState.Done && Root != null && Roots is { } r ? Planner.Plan(mode, Root, r) : null;
        NotifyChanged();
    }

    /// <summary>Richiesta di anteprima: la mostra la finestra principale.</summary>
    public event Action<PlanRequest>? PreviewRequested;

    void Ask(string title, SyncMode? m, SyncPlan plan)
    {
        if (plan.IsEmpty)
        {
            UI.Info(title, plan.Conflicts.Count == 0 ? "Niente da fare: già allineate." : plan.Summary);
            return;
        }
        PreviewRequested?.Invoke(new PlanRequest(title, m, deleteMode, plan, LeftVolume?.Free, RightVolume?.Free,
            LeftPath != null ? Path.GetFileName(LeftPath.TrimEnd('\\')) : "Sinistra",
            RightPath != null ? Path.GetFileName(RightPath.TrimEnd('\\')) : "Destra"));
    }

    public void PrepareSync()
    {
        if (Root == null || Roots is not { } r) return;
        if (State != ScanState.Done)
        {
            UI.Info("Analisi in corso", "Attendi la fine dell'analisi per sincronizzare tutto l'albero.");
            return;
        }
        Ask(mode.Title(), mode, Planner.Plan(mode, Root, r));
    }

    static List<FolderNode> TopLevel(List<FolderNode> nodes)
    {
        var set = nodes.ToHashSet();
        return nodes.Where(n =>
        {
            for (var p = n.Parent; p != null; p = p.Parent) if (set.Contains(p)) return false;
            return true;
        }).ToList();
    }

    public void PrepareCopy(List<FolderNode> nodes, Side dest)
    {
        if (Roots is not { } r || nodes.Count == 0) return;
        if (nodes.Any(n => n.IsDir && !n.Complete))
        {
            UI.Info("Analisi in corso", "Alcune cartelle selezionate non sono ancora state analizzate per intero.");
            return;
        }
        Ask($"Copia a {dest.Label()}", null, Planner.PlanCopy(TopLevel(nodes), dest, r));
    }

    public void PrepareDelete(List<FolderNode> nodes, Side side)
    {
        if (Roots is not { } r || nodes.Count == 0) return;
        Ask($"Elimina a {side.Label()}", null, Planner.PlanDelete(TopLevel(nodes), side, r));
    }

    public void Exclude(List<FolderNode> nodes)
    {
        var o = options.Clone();
        var list = o.ExcludeList;
        foreach (var n in nodes.Select(n => n.Name).Distinct())
            if (!list.Contains(n, StringComparer.OrdinalIgnoreCase)) list.Add(n);
        o.Excludes = string.Join(", ", list);
        SetOptions(o);
    }

    public async void Run(SyncPlan plan)
    {
        if (IsRunning) return;
        runCts = new CancellationTokenSource();
        var log = new SyncLog(name);
        var dispatcher = Dispatcher.CurrentDispatcher;
        var exec = new SyncExecutor(plan, deleteMode, options.ParallelCopies, runCts.Token, log, p =>
            dispatcher.BeginInvoke(() => { if (Progress != null) { Progress = p; NotifyChanged(); } }));
        Progress = new SyncProgress { TotalOps = plan.Ops.Count, TotalBytes = plan.CopyBytes };
        NotifyChanged();
        var result = await exec.RunAsync();
        Progress = null;
        LastRun = result;
        LastRunDate = DateTime.UtcNow;
        if (Profile is { } p)
        {
            p.LastRun = DateTime.UtcNow;
            p.LastResult = result.Summary;
            AppState.Instance.SaveProfile(p);
        }
        if (result.Errors.Count > 0 || result.Notes.Count > 0) System.Media.SystemSounds.Exclamation.Play();
        else System.Media.SystemSounds.Asterisk.Play();
        Rescan();
    }

    public void StopRun() => runCts.Cancel();

    /// <summary>Per "Sincronizza tutti": analizza e ritorna il piano della modalità.</summary>
    public async Task<(SyncPlan? Plan, string? Error)> AnalyzeForBatchAsync()
    {
        if (!IsScanning && State != ScanState.Done) Rescan();
        var ok = await WaitForScanAsync();
        if (!ok || Root == null || Roots is not { } r) return (null, FailMessage ?? "Analisi non riuscita");
        return (Planner.Plan(mode, Root, r), null);
    }

    public SyncProfile MakeProfile() => new()
    {
        Name = name,
        Left = LeftPath ?? "",
        Right = RightPath ?? "",
        LeftServer = LeftServer,
        RightServer = RightServer,
        Mode = mode,
        DeleteMode = deleteMode,
        Options = options.Clone(),
    };
}

public sealed record PlanRequest(string Title, SyncMode? Mode, DeleteMode DeleteMode, SyncPlan Plan, long? FreeLeft, long? FreeRight, string LeftName, string RightName);

/// <summary>Una riga della vista: un elemento dell'albero con i dati di entrambi i lati.</summary>
public sealed class RowVM(FolderSession session, FolderNode node, int depth)
{
    public FolderNode Node { get; } = node;
    public int Depth { get; } = depth;

    public Thickness Indent => new(Depth * 16, 0, 0, 0);
    public bool HasExpander => session.IsExpandable(Node);
    public Visibility ExpanderVisibility => HasExpander ? Visibility.Visible : Visibility.Hidden;
    public string ExpanderGlyph => Node.Expanded ? "" : "";

    public ImageSource? LeftIcon => ShellIcons.For(Node.Left);
    public ImageSource? RightIcon => ShellIcons.For(Node.Right);
    public string LeftName => Node.Left?.Name ?? "";
    public string RightName => Node.Right?.Name ?? "";
    public FontWeight NameWeight => Node.IsDir ? FontWeights.SemiBold : FontWeights.Normal;
    public Brush LeftBrush => NameBrush(Side.Left);
    public Brush RightBrush => NameBrush(Side.Right);

    public string LeftSize => SizeText(Side.Left);
    public string RightSize => SizeText(Side.Right);
    public string LeftDate => Node.Left is { IsDir: false } l ? Fmt.Date(l.ModifiedUtc) : "";
    public string RightDate => Node.Right is { IsDir: false } r ? Fmt.Date(r.ModifiedUtc) : "";
    public Brush LeftDateBrush => Node.Status == NodeStatus.LeftNewer ? UI.ChangedBrush : UI.Secondary;
    public Brush RightDateBrush => Node.Status == NodeStatus.RightNewer ? UI.ChangedBrush : UI.Secondary;

    public string Badge => Node.IsDir && Node.Complete && Node.IsDirBoth && Node.Tally.Diffs > 0 ? Fmt.Number(Node.Tally.Diffs) : "";
    public Visibility BadgeVisibility => Badge.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Brush BadgeBrush => Node.Tally.Changed == 0 ? UI.OrphanBrush : UI.ChangedBrush;
    public Brush BadgeBack => UI.Tint(BadgeBrush, 0.16);

    public string StatusGlyph
    {
        get
        {
            if (Node.IsDir && !Node.Complete) return "⋯";
            return Node.Status switch
            {
                NodeStatus.Same => "=",
                NodeStatus.Different => Node.TypeMismatch ? "⇆" : "≠",
                NodeStatus.LeftNewer => "›",
                NodeStatus.RightNewer => "‹",
                NodeStatus.LeftOnly => "◀",
                NodeStatus.RightOnly => "▶",
                _ => "⋯",
            };
        }
    }

    public Brush StatusBrush
    {
        get
        {
            if (Node.IsDir && !Node.Complete) return UI.Tertiary;
            return Node.Status switch
            {
                NodeStatus.Same => UI.Tertiary,
                NodeStatus.Different => Node.TypeMismatch ? UI.MismatchBrush : UI.ChangedBrush,
                NodeStatus.LeftNewer or NodeStatus.RightNewer => UI.ChangedBrush,
                NodeStatus.LeftOnly or NodeStatus.RightOnly => UI.OrphanBrush,
                _ => UI.Tertiary,
            };
        }
    }

    public Brush StatusBack => StatusBrush == UI.Tertiary ? Brushes.Transparent : UI.Tint(StatusBrush, 0.15);

    public Brush RowTint => Node.Status switch
    {
        NodeStatus.LeftOnly or NodeStatus.RightOnly => UI.Tint(UI.OrphanBrush, 0.07),
        NodeStatus.LeftNewer or NodeStatus.RightNewer => UI.Tint(UI.ChangedBrush, 0.06),
        NodeStatus.Different when !Node.IsDir => UI.Tint(Node.TypeMismatch ? UI.MismatchBrush : UI.ChangedBrush, 0.06),
        _ => Brushes.Transparent,
    };

    public string RowToolTip
    {
        get
        {
            var paths = new List<string>();
            paths.Add(Node.Left != null ? "Sinistra: " + Node.Left.Path : "Non presente a sinistra");
            paths.Add(Node.Right != null ? "Destra: " + Node.Right.Path : "Non presente a destra");
            return Describe(Node) + "\n" + string.Join("\n", paths);
        }
    }

    public static string Describe(FolderNode n)
    {
        if (n.IsDir && !n.Complete) return "Cartella in analisi";
        return n.Status switch
        {
            NodeStatus.Same => n.IsDir ? "Cartelle identiche" : "File uguali",
            NodeStatus.Different when n.TypeMismatch => "Da un lato è un file, dall'altro una cartella",
            NodeStatus.Different when n.IsDir => $"Contiene {Fmt.Number(n.Tally.Diffs)} differenze: {Fmt.Number(n.Tally.Changed)} modificati, {Fmt.Number(n.Tally.LeftOnly)} solo a sinistra, {Fmt.Number(n.Tally.RightOnly)} solo a destra",
            NodeStatus.Different => "Diversi, con la stessa data",
            NodeStatus.LeftNewer => "Più recente a sinistra",
            NodeStatus.RightNewer => "Più recente a destra",
            NodeStatus.LeftOnly => "Presente solo a sinistra",
            NodeStatus.RightOnly => "Presente solo a destra",
            _ => "In analisi",
        };
    }

    Brush NameBrush(Side side) => Node.Status switch
    {
        NodeStatus.Same or NodeStatus.Pending => UI.Primary,
        NodeStatus.Different => Node.TypeMismatch ? UI.MismatchBrush : Node.IsDir ? UI.Primary : UI.ChangedBrush,
        NodeStatus.LeftNewer => side == Side.Left ? UI.ChangedBrush : UI.Secondary,
        NodeStatus.RightNewer => side == Side.Right ? UI.ChangedBrush : UI.Secondary,
        _ => UI.OrphanBrush,
    };

    string SizeText(Side side)
    {
        var info = Node.Info(side);
        if (info == null) return "";
        if (info.IsDir) return Node.Complete ? Fmt.Size(Node.Tally.Bytes(side)) : "…";
        return Fmt.Size(info.Size);
    }
}
