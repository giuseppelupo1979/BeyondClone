using System.Text;

namespace BeyondClone.Core;

public enum Side { Left, Right }

public static class SideExtensions
{
    public static Side Other(this Side s) => s == Side.Left ? Side.Right : Side.Left;
    public static string Label(this Side s) => s == Side.Left ? "sinistra" : "destra";
}

/// <summary>Un file o una cartella su un lato del confronto.</summary>
public sealed record FileEntry(string Path, string Name, bool IsDir, long Size, DateTime? ModifiedUtc, bool Hidden);

public enum NodeStatus { Same, Different, LeftNewer, RightNewer, LeftOnly, RightOnly, Pending }

public static class NodeStatusExtensions
{
    public static bool IsChanged(this NodeStatus s) => s is NodeStatus.Different or NodeStatus.LeftNewer or NodeStatus.RightNewer;
    public static bool IsOrphan(this NodeStatus s) => s is NodeStatus.LeftOnly or NodeStatus.RightOnly;
}

/// <summary>Conteggi di un sottoalbero (per un file: il file stesso).</summary>
public struct Tally
{
    public int Same, Changed, LeftNewer, RightNewer, LeftOnly, RightOnly, LeftFiles, RightFiles;
    public long LeftBytes, RightBytes;

    public readonly int Diffs => Changed + LeftOnly + RightOnly;
    public readonly int Compared => Same + Diffs;

    public void Add(in Tally b)
    {
        Same += b.Same; Changed += b.Changed; LeftNewer += b.LeftNewer; RightNewer += b.RightNewer;
        LeftOnly += b.LeftOnly; RightOnly += b.RightOnly; LeftFiles += b.LeftFiles; RightFiles += b.RightFiles;
        LeftBytes += b.LeftBytes; RightBytes += b.RightBytes;
    }

    public static Tally File(NodeStatus s, FileEntry? l, FileEntry? r)
    {
        var t = new Tally();
        if (l != null) { t.LeftFiles = 1; t.LeftBytes = l.Size; }
        if (r != null) { t.RightFiles = 1; t.RightBytes = r.Size; }
        switch (s)
        {
            case NodeStatus.Same: t.Same = 1; break;
            case NodeStatus.Different: t.Changed = 1; break;
            case NodeStatus.LeftNewer: t.Changed = 1; t.LeftNewer = 1; break;
            case NodeStatus.RightNewer: t.Changed = 1; t.RightNewer = 1; break;
            case NodeStatus.LeftOnly: t.LeftOnly = 1; break;
            case NodeStatus.RightOnly: t.RightOnly = 1; break;
        }
        return t;
    }

    public readonly long Bytes(Side s) => s == Side.Left ? LeftBytes : RightBytes;
    public readonly int Files(Side s) => s == Side.Left ? LeftFiles : RightFiles;
}

public sealed class FolderNode
{
    public string Name { get; }
    public string RelPath { get; }
    public FileEntry? Left { get; set; }
    public FileEntry? Right { get; set; }
    public FolderNode? Parent { get; set; }
    public List<FolderNode> Children { get; set; } = [];
    public NodeStatus Status { get; set; }
    public Tally Tally;
    /// <summary>Contenuto letto (per le cartelle).</summary>
    public bool Listed { get; set; }
    /// <summary>Lettura già richiesta.</summary>
    public bool Requested { get; set; }
    /// <summary>Sottoalbero interamente analizzato.</summary>
    public bool Complete { get; set; }
    public int PendingDirs { get; set; }
    public string? Error { get; set; }

    // Cache della vista filtrata.
    public int ViewGen = -1;
    public List<FolderNode> ViewChildren = [];
    public bool Expanded;

    public FolderNode(string name, string relPath, FileEntry? left, FileEntry? right, NodeStatus status)
    {
        Name = name; RelPath = relPath; Left = left; Right = right; Status = status;
    }

    public static FolderNode Root(string l, string r) =>
        new("", "", new FileEntry(l, System.IO.Path.GetFileName(l.TrimEnd('\\')), true, 0, null, false),
                    new FileEntry(r, System.IO.Path.GetFileName(r.TrimEnd('\\')), true, 0, null, false), NodeStatus.Pending);

    public bool IsDir => (Left?.IsDir ?? false) || (Right?.IsDir ?? false);
    public bool IsDirBoth => (Left?.IsDir ?? false) && (Right?.IsDir ?? false);
    public string? LeftDirPath => Left?.IsDir == true ? Left.Path : null;
    public string? RightDirPath => Right?.IsDir == true ? Right.Path : null;
    public bool TypeMismatch => Left != null && Right != null && Left.IsDir != Right.IsDir;
    public FileEntry? Info(Side s) => s == Side.Left ? Left : Right;

    public int Depth
    {
        get
        {
            int d = 0;
            for (var p = Parent; p?.Parent != null; p = p.Parent) d++;
            return d;
        }
    }
}

public enum CompareMethod { SizeDate, Size, Content }

public static class CompareMethodExtensions
{
    public static string Title(this CompareMethod m) => m switch
    {
        CompareMethod.SizeDate => "Dimensione e data",
        CompareMethod.Size => "Solo dimensione",
        _ => "Contenuto (lento, legge i file)",
    };
}

public sealed class DirOptions
{
    public const string DefaultExcludes = "desktop.ini, Thumbs.db, $RECYCLE.BIN, System Volume Information, .DS_Store, ._*, .Spotlight-V100, .Trashes, .fseventsd, @eaDir, #recycle, #snapshot, .SynologyWorkingDirectory, ~$*";

    public CompareMethod Method { get; set; } = CompareMethod.SizeDate;
    public double TimeTolerance { get; set; } = 2;
    public bool IgnoreHourShift { get; set; } = true;
    public bool IncludeHidden { get; set; } = true;
    /// <summary>Su Windows i nomi non distinguono maiuscole e minuscole: è il valore predefinito.</summary>
    public bool CaseInsensitive { get; set; } = true;
    public string Excludes { get; set; } = DefaultExcludes;
    public int ParallelCopies { get; set; } = 4;

    public DirOptions Clone() => (DirOptions)MemberwiseClone();

    public List<string> ExcludeList => Excludes.Split([',', ';', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    /// <summary>Le opzioni che cambiano il risultato del confronto.</summary>
    public string ScanKey => $"{Method}|{TimeTolerance}|{IgnoreHourShift}|{IncludeHidden}|{CaseInsensitive}|{Excludes}";
}

public sealed class SyncError(string message) : Exception(message)
{
    public static SyncError Unreachable(string path) => new($"Cartella non raggiungibile: {path}");
}

public static class Fmt
{
    static readonly string[] Units = ["byte", "KB", "MB", "GB", "TB", "PB"];

    public static string Size(long bytes)
    {
        if (bytes < 1000) return bytes == 1 ? "1 byte" : $"{bytes} byte";
        double v = bytes;
        int u = 0;
        while (v >= 1000 && u < Units.Length - 1) { v /= 1000; u++; }
        return v >= 100 ? $"{v:0} {Units[u]}" : v >= 10 ? $"{v:0.0} {Units[u]}" : $"{v:0.00} {Units[u]}";
    }

    public static string Speed(double bps) => bps < 1 ? "—" : Size((long)bps) + "/s";

    public static string Duration(TimeSpan t)
    {
        int s = (int)Math.Round(t.TotalSeconds);
        if (s < 60) return $"{Math.Max(0, s)} s";
        if (s < 3600) return $"{s / 60} min {s % 60} s";
        return $"{s / 3600} h {s % 3600 / 60} min";
    }

    public static string Number(long n) => n.ToString("N0", System.Globalization.CultureInfo.GetCultureInfo("it-IT"));

    public static string Date(DateTime? utc) => utc?.ToLocalTime().ToString("dd/MM/yy  HH:mm") ?? "";
    public static string DateLong(DateTime? utc) => utc?.ToLocalTime().ToString("dd/MM/yyyy HH:mm:ss") ?? "—";

    public static string Relative(DateTime utc)
    {
        var d = DateTime.UtcNow - utc;
        if (d.TotalMinutes < 1) return "adesso";
        if (d.TotalMinutes < 60) return $"{(int)d.TotalMinutes} minuti fa";
        if (d.TotalHours < 24) return $"{(int)d.TotalHours} ore fa";
        if (d.TotalDays < 2) return "ieri";
        return $"{(int)d.TotalDays} giorni fa";
    }
}
