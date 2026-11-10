using System.IO.Enumeration;
using System.Text;

namespace BeyondClone.Core;

public sealed record ListEntry(string Name, FileEntry? Left, FileEntry? Right, NodeStatus Status);

public sealed class ListResult
{
    public List<ListEntry> Entries { get; } = [];
    public string? Error { get; set; }
}

/// <summary>Lettura di una cartella su entrambi i lati e classificazione degli elementi.</summary>
public static class DirLister
{
    public const string ArchiveName = ".beyondclone-archivio";
    public const string PartSuffix = ".bcpart";

    static readonly EnumerationOptions Enum = new()
    {
        IgnoreInaccessible = false,
        AttributesToSkip = 0,
        RecurseSubdirectories = false,
        ReturnSpecialDirectories = false,
    };

    public static (List<FileEntry> items, string? error) ReadSide(string? dir)
    {
        var list = new List<FileEntry>();
        if (dir == null) return (list, null);
        try
        {
            foreach (var fsi in new DirectoryInfo(dir).EnumerateFileSystemInfos("*", Enum))
            {
                var attr = fsi.Attributes;
                bool isDir = (attr & FileAttributes.Directory) != 0;
                // Giunzioni e collegamenti a cartelle: non si seguono (possono creare cicli).
                if (isDir && (attr & FileAttributes.ReparsePoint) != 0) continue;
                long size = fsi is FileInfo fi ? fi.Length : 0;
                bool hidden = (attr & (FileAttributes.Hidden | FileAttributes.System)) != 0 || fsi.Name.StartsWith('.');
                list.Add(new FileEntry(fsi.FullName, fsi.Name, isDir, size, fsi.LastWriteTimeUtc, hidden));
            }
            return (list, null);
        }
        catch (Exception e)
        {
            return (list, $"{Path.GetFileName(dir.TrimEnd('\\'))}: {e.Message}");
        }
    }

    public static bool Excluded(FileEntry e, string rel, DirOptions o, List<string> patterns)
    {
        var name = e.Name;
        if (name == ArchiveName || name.EndsWith(PartSuffix, StringComparison.OrdinalIgnoreCase)) return true;
        if (!o.IncludeHidden && e.Hidden) return true;
        foreach (var p in patterns)
        {
            if (p.Contains('/') || p.Contains('\\'))
            {
                if (FileSystemName.MatchesSimpleExpression(p.Replace('/', '\\'), rel, ignoreCase: true)) return true;
            }
            else if (FileSystemName.MatchesSimpleExpression(p, name, ignoreCase: true)) return true;
        }
        return false;
    }

    public static string Key(string name, DirOptions o)
    {
        var k = name.Normalize(NormalizationForm.FormC);
        return o.CaseInsensitive ? k.ToLowerInvariant() : k;
    }

    public static ListResult List(string? left, string? right, string rel, DirOptions o, List<string> patterns, CancellationToken ct)
    {
        var (l, le) = ReadSide(left);
        var (r, re) = ReadSide(right);
        var res = new ListResult { Error = le ?? re };
        var map = new Dictionary<string, (FileEntry? L, FileEntry? R)>(l.Count + r.Count);
        foreach (var f in l)
        {
            var k = Key(f.Name, o);
            map[k] = (f, map.TryGetValue(k, out var v) ? v.R : null);
        }
        foreach (var f in r)
        {
            var k = Key(f.Name, o);
            map[k] = (map.TryGetValue(k, out var v) ? v.L : null, f);
        }
        foreach (var (_, pair) in map)
        {
            if (ct.IsCancellationRequested) break;
            var first = (pair.L ?? pair.R)!;
            var childRel = rel.Length == 0 ? first.Name : rel + "\\" + first.Name;
            if (Excluded(first, childRel, o, patterns)) continue;
            res.Entries.Add(new ListEntry(first.Name, pair.L, pair.R, Classify(pair.L, pair.R, o, ct)));
        }
        res.Entries.Sort((a, b) =>
        {
            bool ad = (a.Left?.IsDir ?? false) || (a.Right?.IsDir ?? false);
            bool bd = (b.Left?.IsDir ?? false) || (b.Right?.IsDir ?? false);
            if (ad != bd) return ad ? -1 : 1;
            return NaturalCompare(a.Name, b.Name);
        });
        return res;
    }

    public static NodeStatus Classify(FileEntry? l, FileEntry? r, DirOptions o, CancellationToken ct)
    {
        if (l == null) return NodeStatus.RightOnly;
        if (r == null) return NodeStatus.LeftOnly;
        if (l.IsDir != r.IsDir) return NodeStatus.Different;
        if (l.IsDir) return NodeStatus.Pending;
        double dt = ((l.ModifiedUtc ?? DateTime.MinValue) - (r.ModifiedUtc ?? DateTime.MinValue)).TotalSeconds;
        double adt = Math.Abs(dt);
        // Ora legale o fuso diverso tra PC e NAS: scarto di un'ora esatta.
        if (o.IgnoreHourShift && Math.Abs(adt - 3600) <= o.TimeTolerance) adt = 0;
        var newer = adt <= o.TimeTolerance ? NodeStatus.Different : (dt > 0 ? NodeStatus.LeftNewer : NodeStatus.RightNewer);
        switch (o.Method)
        {
            case CompareMethod.Size:
                return l.Size == r.Size ? NodeStatus.Same : newer;
            case CompareMethod.SizeDate:
                if (l.Size != r.Size) return newer;
                return adt <= o.TimeTolerance ? NodeStatus.Same : newer;
            default:
                if (l.Size != r.Size) return newer;
                return SameContent(l.Path, r.Path, ct) ? NodeStatus.Same : newer;
        }
    }

    public static bool SameContent(string a, string b, CancellationToken ct)
    {
        try
        {
            const int n = 1 << 20;
            using var fa = new FileStream(a, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, n, FileOptions.SequentialScan);
            using var fb = new FileStream(b, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, n, FileOptions.SequentialScan);
            var ba = new byte[n];
            var bb = new byte[n];
            while (true)
            {
                if (ct.IsCancellationRequested) return false;
                int ra = fa.ReadAtLeast(ba, n, throwOnEndOfStream: false);
                int rb = fb.ReadAtLeast(bb, n, throwOnEndOfStream: false);
                if (ra != rb || !ba.AsSpan(0, ra).SequenceEqual(bb.AsSpan(0, rb))) return false;
                if (ra == 0) return true;
            }
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Ordinamento "naturale" come in Esplora file (IMG_2 prima di IMG_10).</summary>
    public static int NaturalCompare(string a, string b) => StrCmpLogicalW(a, b);

    [System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int StrCmpLogicalW(string x, string y);
}

/// <summary>Costruzione dell'albero, condivisa da analisi progressiva e analisi completa.</summary>
public static class Tree
{
    /// <summary>Aggancia il contenuto letto; ritorna le sottocartelle da leggere.</summary>
    public static List<FolderNode> Attach(FolderNode node, ListResult res)
    {
        node.Listed = true;
        node.Error = res.Error;
        var subdirs = new List<FolderNode>();
        var children = new List<FolderNode>(res.Entries.Count);
        foreach (var e in res.Entries)
        {
            var rel = node.RelPath.Length == 0 ? e.Name : node.RelPath + "\\" + e.Name;
            var c = new FolderNode(e.Name, rel, e.Left, e.Right, e.Status) { Parent = node };
            if (c.IsDir) subdirs.Add(c);
            else
            {
                c.Tally = Tally.File(e.Status, e.Left, e.Right);
                c.Listed = c.Requested = c.Complete = true;
            }
            children.Add(c);
        }
        node.Children = children;
        node.PendingDirs = subdirs.Count;
        return subdirs;
    }

    /// <summary>Da chiamare quando la cartella è letta e non ha sottocartelle in sospeso.
    /// Risale l'albero chiudendo i genitori completati. Ritorna true se si è chiusa la radice.</summary>
    public static bool Finish(FolderNode node)
    {
        for (var n = node; n != null;)
        {
            n.Complete = true;
            var t = new Tally();
            foreach (var c in n.Children) t.Add(c.Tally);
            if (n.TypeMismatch) { n.Status = NodeStatus.Different; t.Changed++; }
            else if (n.Left == null) { n.Status = NodeStatus.RightOnly; if (n.Children.Count == 0) t.RightOnly++; }
            else if (n.Right == null) { n.Status = NodeStatus.LeftOnly; if (n.Children.Count == 0) t.LeftOnly++; }
            else n.Status = t.Diffs == 0 && n.Error == null ? NodeStatus.Same : NodeStatus.Different;
            n.Tally = t;
            var p = n.Parent;
            if (p == null) return true;
            p.PendingDirs--;
            n = p.Listed && p.PendingDirs == 0 ? p : null;
        }
        return false;
    }

    /// <summary>Analisi completa sincrona (autotest e uso senza interfaccia).</summary>
    public static FolderNode ScanSync(string left, string right, DirOptions o, CancellationToken ct = default)
    {
        foreach (var u in new[] { left, right })
            if (!Directory.Exists(u)) throw SyncError.Unreachable(u);
        var root = FolderNode.Root(left, right);
        var patterns = o.ExcludeList;
        var stack = new Stack<FolderNode>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var n = stack.Pop();
            var res = DirLister.List(n.LeftDirPath, n.RightDirPath, n.RelPath, o, patterns, ct);
            var subs = Attach(n, res);
            if (subs.Count == 0) Finish(n);
            foreach (var s in subs) stack.Push(s);
        }
        return root;
    }
}
