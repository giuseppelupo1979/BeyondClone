using System.Buffers;
using System.Runtime.InteropServices;

namespace BeyondClone.Core;

public enum SyncMode { UpdateRight, UpdateLeft, UpdateBoth, MirrorRight, MirrorLeft }

public static class SyncModeExtensions
{
    public static string Title(this SyncMode m) => m switch
    {
        SyncMode.UpdateRight => "Aggiorna destra",
        SyncMode.UpdateLeft => "Aggiorna sinistra",
        SyncMode.UpdateBoth => "Aggiorna entrambe",
        SyncMode.MirrorRight => "Specchia a destra",
        _ => "Specchia a sinistra",
    };

    public static string Detail(this SyncMode m) => m switch
    {
        SyncMode.UpdateRight => "Copia a destra i file nuovi e più recenti. Non elimina nulla.",
        SyncMode.UpdateLeft => "Copia a sinistra i file nuovi e più recenti. Non elimina nulla.",
        SyncMode.UpdateBoth => "In entrambe le direzioni vince il più recente. Non elimina nulla.",
        SyncMode.MirrorRight => "Destra diventa identica a sinistra, eliminazioni comprese.",
        _ => "Sinistra diventa identica a destra, eliminazioni comprese.",
    };

    /// <summary>Glifo del font Segoe Fluent Icons.</summary>
    public static string Glyph(this SyncMode m) => m switch
    {
        SyncMode.UpdateRight => "\uE72A",
        SyncMode.UpdateLeft => "\uE72B",
        SyncMode.UpdateBoth => "\uE8AB",
        SyncMode.MirrorRight => "\uE893",
        _ => "\uE892",
    };

    public static bool IsMirror(this SyncMode m) => m is SyncMode.MirrorLeft or SyncMode.MirrorRight;
}

public enum DeleteMode { Archive, RecycleBin, Permanent }

public static class DeleteModeExtensions
{
    public static string Title(this DeleteMode d) => d switch
    {
        DeleteMode.Archive => "Archivio sulla destinazione",
        DeleteMode.RecycleBin => "Cestino di Windows",
        _ => "Eliminazione definitiva",
    };

    public static string Detail(this DeleteMode d) => d switch
    {
        DeleteMode.Archive => $"Eliminati e sovrascritti vanno in «{DirLister.ArchiveName}\\data-ora\\» nella cartella di destinazione. Funziona anche sul NAS.",
        DeleteMode.RecycleBin => "Nel Cestino di Windows; sulle cartelle di rete, che non hanno Cestino, si usa l'archivio.",
        _ => "Nessuna copia di sicurezza: i file eliminati o sovrascritti non si recuperano.",
    };
}

public enum OpKind { Copy, Mkdir, Delete }

public sealed class PlannedOp
{
    public required OpKind Kind { get; init; }
    public required Side Dest { get; init; }
    public required string Rel { get; init; }
    public string? Source { get; init; }
    public required string Target { get; init; }
    public required string DestRoot { get; init; }
    public long Size { get; init; }
    public bool Replaces { get; init; }
    public bool IsDir { get; init; }

    public string ActionTitle => Kind switch
    {
        OpKind.Copy => Replaces ? "Sovrascrivi" : "Copia",
        OpKind.Mkdir => "Crea cartella",
        _ => IsDir ? "Elimina cartella" : "Elimina",
    };
}

public sealed class SyncPlan
{
    public List<PlannedOp> Ops { get; } = [];
    public List<string> Conflicts { get; } = [];

    public IEnumerable<PlannedOp> Copies(Side s) => Ops.Where(o => o.Kind == OpKind.Copy && o.Dest == s);
    public long Bytes(Side s) => Copies(s).Sum(o => o.Size);
    public int CopyCount => Ops.Count(o => o.Kind == OpKind.Copy);
    public long CopyBytes => Ops.Where(o => o.Kind == OpKind.Copy).Sum(o => o.Size);
    public int DeleteCount => Ops.Count(o => o.Kind == OpKind.Delete);
    public int MkdirCount => Ops.Count(o => o.Kind == OpKind.Mkdir);
    public bool IsEmpty => Ops.Count == 0;

    public string Summary
    {
        get
        {
            if (Ops.Count == 0) return Conflicts.Count == 0 ? "Già allineate" : $"{Conflicts.Count} conflitti, nient'altro da fare";
            var parts = new List<string>();
            if (CopyCount > 0) parts.Add($"{Fmt.Number(CopyCount)} da copiare ({Fmt.Size(CopyBytes)})");
            if (MkdirCount > 0) parts.Add($"{Fmt.Number(MkdirCount)} cartelle");
            if (DeleteCount > 0) parts.Add($"{Fmt.Number(DeleteCount)} da eliminare");
            if (Conflicts.Count > 0) parts.Add($"{Conflicts.Count} conflitti");
            return string.Join(" · ", parts);
        }
    }
}

public sealed record Roots(string Left, string Right)
{
    public string Of(Side s) => s == Side.Left ? Left : Right;
}

public static class Planner
{
    public static SyncPlan Plan(SyncMode mode, FolderNode root, Roots roots)
    {
        var plan = new SyncPlan();
        Sync(mode, root.Children, roots.Left, roots.Right, roots, plan);
        return plan;
    }

    public static SyncPlan PlanCopy(IEnumerable<FolderNode> nodes, Side dest, Roots roots)
    {
        var plan = new SyncPlan();
        foreach (var n in nodes) Copy(n, dest, DestParent(n, dest, roots), roots, plan);
        return plan;
    }

    public static SyncPlan PlanDelete(IEnumerable<FolderNode> nodes, Side side, Roots roots)
    {
        var plan = new SyncPlan();
        foreach (var n in nodes)
            if (n.Info(side) is { } info) plan.Ops.Add(Del(info, n, side, roots));
        return plan;
    }

    /// <summary>Cartella di destinazione reale del genitore (rispetta il nome effettivo).</summary>
    static string DestParent(FolderNode n, Side side, Roots roots)
    {
        var p = n.Parent;
        if (p?.Parent == null) return roots.Of(side);
        if (p.Info(side) is { IsDir: true } info) return info.Path;
        return Path.Combine(DestParent(p, side, roots), p.Name);
    }

    static PlannedOp Del(FileEntry info, FolderNode n, Side side, Roots roots) => new()
    {
        Kind = OpKind.Delete, Dest = side, Rel = n.RelPath, Target = info.Path, DestRoot = roots.Of(side),
        Size = info.IsDir ? n.Tally.Bytes(side) : info.Size, IsDir = info.IsDir,
    };

    static void Copy(FolderNode node, Side dest, string destParent, Roots roots, SyncPlan plan)
    {
        var src = node.Info(dest.Other());
        if (src == null) return;
        var dst = node.Info(dest);
        var target = dst?.Path ?? Path.Combine(destParent, node.Name);
        if (src.IsDir)
        {
            if (dst is { IsDir: false }) plan.Ops.Add(Del(dst, node, dest, roots));
            if (dst == null || !dst.IsDir)
                plan.Ops.Add(new PlannedOp { Kind = OpKind.Mkdir, Dest = dest, Rel = node.RelPath, Target = target, DestRoot = roots.Of(dest), IsDir = true });
            foreach (var c in node.Children) Copy(c, dest, target, roots, plan);
        }
        else
        {
            if (node.Status == NodeStatus.Same) return;
            if (dst is { IsDir: true }) plan.Ops.Add(Del(dst, node, dest, roots));
            plan.Ops.Add(new PlannedOp
            {
                Kind = OpKind.Copy, Dest = dest, Rel = node.RelPath, Source = src.Path, Target = target,
                DestRoot = roots.Of(dest), Size = src.Size, Replaces = dst is { IsDir: false },
            });
        }
    }

    static void Sync(SyncMode mode, List<FolderNode> nodes, string leftParent, string rightParent, Roots roots, SyncPlan plan)
    {
        foreach (var n in nodes)
        {
            if (n.Status == NodeStatus.Same) continue;
            string Parent(Side s) => s == Side.Left ? leftParent : rightParent;
            void Recurse() => Sync(mode, n.Children, n.Left!.Path, n.Right!.Path, roots, plan);
            switch (mode)
            {
                case SyncMode.UpdateRight or SyncMode.UpdateLeft:
                {
                    var dest = mode == SyncMode.UpdateRight ? Side.Right : Side.Left;
                    var orphan = dest == Side.Right ? NodeStatus.LeftOnly : NodeStatus.RightOnly;
                    var newer = dest == Side.Right ? NodeStatus.LeftNewer : NodeStatus.RightNewer;
                    if (n.IsDirBoth) Recurse();
                    else if (n.Status == orphan || n.Status == newer) Copy(n, dest, Parent(dest), roots, plan);
                    else if (!n.Status.IsOrphan()) plan.Conflicts.Add(n.RelPath);
                    break;
                }
                case SyncMode.UpdateBoth:
                    if (n.IsDirBoth) Recurse();
                    else if (n.Status is NodeStatus.LeftOnly or NodeStatus.LeftNewer) Copy(n, Side.Right, rightParent, roots, plan);
                    else if (n.Status is NodeStatus.RightOnly or NodeStatus.RightNewer) Copy(n, Side.Left, leftParent, roots, plan);
                    else plan.Conflicts.Add(n.RelPath);
                    break;
                default:
                {
                    var dest = mode == SyncMode.MirrorRight ? Side.Right : Side.Left;
                    var extra = dest == Side.Right ? NodeStatus.RightOnly : NodeStatus.LeftOnly;
                    if (n.Status == extra)
                    {
                        if (n.Info(dest) is { } info) plan.Ops.Add(Del(info, n, dest, roots));
                    }
                    else if (n.IsDirBoth) Recurse();
                    else Copy(n, dest, Parent(dest), roots, plan);
                    break;
                }
            }
        }
    }
}

// MARK: - Esecuzione

public sealed class SyncProgress
{
    public int DoneOps, TotalOps, Errors;
    public long DoneBytes, TotalBytes;
    public double Speed;
    public string Phase = "Preparazione";
    public List<string> Active = [];
    public DateTime Started = DateTime.UtcNow;

    public double Fraction => TotalBytes > 0 ? Math.Clamp((double)DoneBytes / TotalBytes, 0, 1) : TotalOps > 0 ? (double)DoneOps / TotalOps : 0;
    public TimeSpan? Eta => Speed > 1 && TotalBytes > DoneBytes ? TimeSpan.FromSeconds((TotalBytes - DoneBytes) / Speed) : null;

    public SyncProgress Snapshot()
    {
        var c = (SyncProgress)MemberwiseClone();
        c.Active = [.. Active];
        return c;
    }
}

public sealed class SyncResult
{
    public int Done;
    public long Bytes;
    public List<string> Errors { get; } = [];
    public List<string> Notes { get; } = [];
    public bool Cancelled;
    public HashSet<string> ArchiveFolders { get; } = [];
    public TimeSpan Duration;
    public string? LogPath;

    public string Summary
    {
        get
        {
            var text = $"{Fmt.Number(Done)} operazioni · {Fmt.Size(Bytes)} in {Fmt.Duration(Duration)}";
            if (Cancelled) text = "Interrotta: " + text;
            if (Errors.Count > 0) text += $" · {Errors.Count} errori";
            return text;
        }
    }
}

/// <summary>Registro testuale di un'esecuzione, in %LOCALAPPDATA%\BeyondClone\Registri.</summary>
public sealed class SyncLog : IDisposable
{
    public string Path { get; }
    readonly StreamWriter writer;
    readonly Lock gate = new();

    public static string Folder => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BeyondClone", "Registri");

    public SyncLog(string name)
    {
        Directory.CreateDirectory(Folder);
        var safe = string.Concat(name.Select(c => System.IO.Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
        Path = System.IO.Path.Combine(Folder, $"{DateTime.Now:yyyy-MM-dd_HH-mm-ss} {safe}.log");
        writer = new StreamWriter(Path, false, new System.Text.UTF8Encoding(true)) { AutoFlush = true };
    }

    public void Write(string line)
    {
        lock (gate) writer.WriteLine($"[{DateTime.Now:HH:mm:ss}] {line}");
    }

    public void Dispose()
    {
        lock (gate) writer.Dispose();
    }
}

public sealed class SyncExecutor
{
    readonly SyncPlan plan;
    readonly DeleteMode deleteMode;
    readonly int parallel;
    readonly CancellationToken ct;
    readonly SyncLog? log;
    readonly Action<SyncProgress> onProgress;
    readonly Lock gate = new();
    readonly SyncProgress progress;
    readonly SyncResult result = new();
    readonly string stamp = DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss");
    DateTime lastEmit = DateTime.MinValue;
    (DateTime t, long b) lastSample = (DateTime.UtcNow, 0);
    bool recycleFallbackNoted;

    public SyncExecutor(SyncPlan plan, DeleteMode deleteMode, int parallel, CancellationToken ct, SyncLog? log, Action<SyncProgress> onProgress)
    {
        this.plan = plan;
        this.deleteMode = deleteMode;
        this.parallel = Math.Clamp(parallel, 1, 16);
        this.ct = ct;
        this.log = log;
        this.onProgress = onProgress;
        progress = new SyncProgress { TotalOps = plan.Ops.Count, TotalBytes = plan.CopyBytes };
    }

    void Emit(bool force = false)
    {
        SyncProgress? snap = null;
        lock (gate)
        {
            var now = DateTime.UtcNow;
            var dt = (now - lastSample.t).TotalSeconds;
            if (dt >= 0.5)
            {
                var inst = (progress.DoneBytes - lastSample.b) / dt;
                progress.Speed = progress.Speed == 0 ? inst : progress.Speed * 0.7 + inst * 0.3;
                lastSample = (now, progress.DoneBytes);
            }
            if (force || (now - lastEmit).TotalSeconds >= 0.1)
            {
                lastEmit = now;
                snap = progress.Snapshot();
            }
        }
        if (snap != null) onProgress(snap);
    }

    void AddBytes(long n)
    {
        lock (gate) progress.DoneBytes += n;
        Emit();
    }

    void Begin(PlannedOp op)
    {
        lock (gate) progress.Active.Add(op.Rel);
        Emit();
    }

    void End(PlannedOp op, Exception? error)
    {
        lock (gate)
        {
            progress.Active.Remove(op.Rel);
            progress.DoneOps++;
            if (error != null)
            {
                progress.Errors++;
                result.Errors.Add($"{op.Rel}: {error.Message}");
            }
            else
            {
                result.Done++;
                if (op.Kind == OpKind.Copy) result.Bytes += op.Size;
            }
        }
        var arrow = op.Dest == Side.Right ? "→" : "←";
        log?.Write(error != null
            ? $"ERRORE {op.ActionTitle} {op.Rel}: {error.Message}"
            : $"{op.ActionTitle} {arrow} {op.Rel}{(op.Kind == OpKind.Copy ? $" ({Fmt.Size(op.Size)})" : "")}");
        Emit();
    }

    public async Task<SyncResult> RunAsync()
    {
        var start = DateTime.UtcNow;
        log?.Write($"Inizio: {plan.Summary}. Eliminazioni: {deleteMode.Title()}. Copie parallele: {parallel}");
        var replacing = plan.Ops.Where(o => o.Kind != OpKind.Delete).Select(o => o.Rel).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var before = new List<PlannedOp>();
        var copies = new List<PlannedOp>();
        var after = new List<PlannedOp>();
        foreach (var op in plan.Ops)
        {
            switch (op.Kind)
            {
                case OpKind.Mkdir: before.Add(op); break;
                case OpKind.Copy: copies.Add(op); break;
                default: (replacing.Contains(op.Rel) ? before : after).Add(op); break;
            }
        }

        await Task.Run(() =>
        {
            lock (gate) progress.Phase = "Preparazione cartelle";
            foreach (var op in before) { if (ct.IsCancellationRequested) break; Perform(op); }

            lock (gate) progress.Phase = "Copia";
            try
            {
                Parallel.ForEach(copies, new ParallelOptions { MaxDegreeOfParallelism = parallel, CancellationToken = ct }, Perform);
            }
            catch (OperationCanceledException) { }

            lock (gate) progress.Phase = "Eliminazioni";
            foreach (var op in after) { if (ct.IsCancellationRequested) break; Perform(op); }
        });

        lock (gate)
        {
            result.Cancelled = ct.IsCancellationRequested;
            result.Duration = DateTime.UtcNow - start;
            result.LogPath = log?.Path;
            progress.Phase = "Fine";
        }
        Emit(force: true);
        log?.Write($"Fine: {result.Summary}");
        log?.Dispose();
        return result;
    }

    void Perform(PlannedOp op)
    {
        Begin(op);
        try
        {
            switch (op.Kind)
            {
                case OpKind.Mkdir:
                    Directory.CreateDirectory(op.Target);
                    break;
                case OpKind.Delete:
                    if (File.Exists(op.Target) || Directory.Exists(op.Target)) Remove(op.Target, op.DestRoot, op.Rel);
                    break;
                default:
                    Copy(op);
                    break;
            }
            End(op, null);
        }
        catch (Exception e)
        {
            End(op, e is OperationCanceledException ? new Exception("annullata") : e);
        }
    }

    void Copy(PlannedOp op)
    {
        var parent = Path.GetDirectoryName(op.Target)!;
        Directory.CreateDirectory(parent);
        // Copia su un file temporaneo e poi rinomina: un'interruzione non lascia file a metà.
        var tmp = Path.Combine(parent, "." + Path.GetFileName(op.Target) + DirLister.PartSuffix);
        if (File.Exists(tmp)) TryDelete(tmp);
        long reported = 0;
        try
        {
            CopyFile(op.Source!, tmp, ct, d => { reported += d; AddBytes(d); });
        }
        catch
        {
            TryDelete(tmp);
            AddBytes(op.Size - reported);
            throw;
        }
        if (reported != op.Size) AddBytes(op.Size - reported);
        if (File.Exists(op.Target))
        {
            try { Remove(op.Target, op.DestRoot, op.Rel); }
            catch { TryDelete(tmp); throw; }
        }
        File.Move(tmp, op.Target);
        var attr = File.GetAttributes(op.Source!) & ~FileAttributes.Hidden;
        if (Path.GetFileName(op.Source!).StartsWith('.') || (File.GetAttributes(op.Source!) & FileAttributes.Hidden) != 0) attr |= FileAttributes.Hidden;
        try { File.SetAttributes(op.Target, attr); } catch { }
    }

    /// <summary>Copia a blocchi da 1 MB: avanzamento per byte e interruzione a metà file. Mantiene le date.</summary>
    public static void CopyFile(string src, string dst, CancellationToken ct, Action<long> onBytes)
    {
        const int n = 1 << 20;
        var buf = ArrayPool<byte>.Shared.Rent(n);
        try
        {
            using (var input = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, n, FileOptions.SequentialScan))
            using (var output = new FileStream(dst, FileMode.CreateNew, FileAccess.Write, FileShare.None, n, FileOptions.SequentialScan))
            {
                int r;
                while ((r = input.Read(buf, 0, n)) > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    output.Write(buf, 0, r);
                    onBytes(r);
                }
            }
            File.SetCreationTimeUtc(dst, File.GetCreationTimeUtc(src));
            File.SetLastWriteTimeUtc(dst, File.GetLastWriteTimeUtc(src));
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buf);
        }
    }

    static void TryDelete(string path)
    {
        try
        {
            File.SetAttributes(path, FileAttributes.Normal);
            File.Delete(path);
        }
        catch { }
    }

    static void ClearReadOnly(string path)
    {
        if (File.Exists(path))
        {
            var a = File.GetAttributes(path);
            if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(path, a & ~FileAttributes.ReadOnly);
        }
        else if (Directory.Exists(path))
        {
            foreach (var f in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                var a = File.GetAttributes(f);
                if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(f, a & ~FileAttributes.ReadOnly);
            }
        }
    }

    void Archive(string path, string root, string rel)
    {
        var baseDir = Path.Combine(root, DirLister.ArchiveName, stamp);
        var dest = Path.Combine(baseDir, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        if (Directory.Exists(path))
        {
            if (Directory.Exists(dest)) Directory.Delete(dest, true);
            Directory.Move(path, dest);
        }
        else File.Move(path, dest, overwrite: true);
        lock (gate) result.ArchiveFolders.Add(baseDir);
    }

    void Remove(string path, string root, string rel)
    {
        switch (deleteMode)
        {
            case DeleteMode.Permanent:
                ClearReadOnly(path);
                if (Directory.Exists(path)) Directory.Delete(path, true); else File.Delete(path);
                break;
            case DeleteMode.Archive:
                Archive(path, root, rel);
                break;
            default:
                if (!RecycleBin.IsLocal(path) || !RecycleBin.Send(path))
                {
                    // Le cartelle di rete non hanno Cestino: si ripiega sull'archivio.
                    Archive(path, root, rel);
                    lock (gate)
                    {
                        if (!recycleFallbackNoted)
                        {
                            recycleFallbackNoted = true;
                            result.Notes.Add($"Cestino non disponibile su {root}: usato l'archivio");
                        }
                    }
                }
                break;
        }
    }
}

/// <summary>Cestino di Windows tramite SHFileOperation (solo dischi locali).</summary>
public static class RecycleBin
{
    public static bool IsLocal(string path)
    {
        if (path.StartsWith(@"\\")) return false;
        try
        {
            var root = Path.GetPathRoot(path);
            if (string.IsNullOrEmpty(root)) return false;
            var t = new DriveInfo(root).DriveType;
            return t is DriveType.Fixed or DriveType.Removable;
        }
        catch { return false; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    const uint FO_DELETE = 3;
    const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    public static bool Send(string path)
    {
        var op = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = path + "\0\0",
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
        };
        return SHFileOperation(ref op) == 0 && op.fAnyOperationsAborted == 0 && !File.Exists(path) && !Directory.Exists(path);
    }
}
