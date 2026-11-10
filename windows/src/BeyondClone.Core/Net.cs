using System.Runtime.InteropServices;

namespace BeyondClone.Core;

/// <summary>Collegamento alle condivisioni di rete (SMB) con la finestra credenziali di Windows.</summary>
public static class NasConnect
{
    /// <summary>Accetta \\server\condivisione, smb://server/condivisione o server/condivisione. Ritorna la radice UNC.</summary>
    public static string ToUnc(string address)
    {
        var a = address.Trim();
        if (a.StartsWith("smb://", StringComparison.OrdinalIgnoreCase)) a = a[6..];
        a = a.Replace('/', '\\').TrimStart('\\');
        // Togli eventuale utente@
        var at = a.IndexOf('@');
        var slash = a.IndexOf('\\');
        if (at >= 0 && (slash < 0 || at < slash)) a = a[(at + 1)..];
        return @"\\" + a.TrimEnd('\\');
    }

    /// <summary>Radice \\server\condivisione di un percorso UNC (null se non è un percorso di rete).</summary>
    public static string? ShareRoot(string path)
    {
        if (!path.StartsWith(@"\\")) return null;
        var parts = path.TrimStart('\\').Split('\\');
        return parts.Length >= 2 ? $@"\\{parts[0]}\{parts[1]}" : null;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NETRESOURCE
    {
        public int dwScope, dwType, dwDisplayType, dwUsage;
        public string? lpLocalName;
        public string lpRemoteName;
        public string? lpComment;
        public string? lpProvider;
    }

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    static extern int WNetAddConnection3(IntPtr hwndOwner, ref NETRESOURCE res, string? password, string? user, int flags);

    const int RESOURCETYPE_DISK = 1;
    const int CONNECT_INTERACTIVE = 0x08, CONNECT_PROMPT = 0x10, CONNECT_UPDATE_PROFILE = 0x01;

    /// <summary>Collega la condivisione. Se servono credenziali Windows mostra la sua finestra (con "Memorizza credenziali").</summary>
    public static void Connect(string address, IntPtr owner, bool remember = false)
    {
        var unc = ShareRoot(ToUnc(address)) ?? ToUnc(address);
        if (Directory.Exists(unc)) return;
        var res = new NETRESOURCE { dwType = RESOURCETYPE_DISK, lpRemoteName = unc };
        int rc = WNetAddConnection3(owner, ref res, null, null, CONNECT_INTERACTIVE | (remember ? CONNECT_UPDATE_PROFILE : 0));
        if (rc == 1223) throw new OperationCanceledException("Connessione annullata");
        if (rc != 0 && rc != 1219)
        {
            rc = WNetAddConnection3(owner, ref res, null, null, CONNECT_INTERACTIVE | CONNECT_PROMPT);
            if (rc == 1223) throw new OperationCanceledException("Connessione annullata");
        }
        if (rc != 0 && rc != 1219 && !Directory.Exists(unc))
            throw new IOException($"Collegamento a {unc} non riuscito: {new System.ComponentModel.Win32Exception(rc).Message}");
    }

    /// <summary>Raggiungibilità con un tempo massimo: una condivisione che non risponde non blocca l'app.</summary>
    public static async Task<bool> ReachableAsync(string path, int timeoutMs = 4000)
    {
        if (string.IsNullOrEmpty(path)) return false;
        var t = Task.Run(() => Directory.Exists(path));
        return await Task.WhenAny(t, Task.Delay(timeoutMs)) == t && t.Result;
    }
}

public sealed record VolumeInfo(string Root, string Name, bool IsNetwork, bool IsRemovable, long? Free, long? Total, string? Server)
{
    /// <summary>Glifo del font Segoe Fluent Icons.</summary>
    public string Glyph => IsNetwork ? "\uE8CE" : IsRemovable ? "\uE88E" : "\uEDA2";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeForUser, out ulong total, out ulong totalFree);

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    static extern int WNetGetConnection(string local, System.Text.StringBuilder remote, ref int length);

    static string? MappedServer(string drive)
    {
        var sb = new System.Text.StringBuilder(512);
        int len = sb.Capacity;
        return WNetGetConnection(drive.TrimEnd('\\'), sb, ref len) == 0 ? sb.ToString() : null;
    }

    /// <summary>Volume che contiene il percorso (unità o condivisione UNC). Da chiamare fuori dal thread dell'interfaccia.</summary>
    public static VolumeInfo? Of(string path)
    {
        try
        {
            var share = NasConnect.ShareRoot(path);
            string root = share ?? Path.GetPathRoot(path) ?? path;
            bool net = share != null;
            string name = net ? root.TrimStart('\\').Split('\\')[1] : root.TrimEnd('\\');
            string? server = share;
            bool removable = false;
            if (!net)
            {
                var di = new DriveInfo(root);
                net = di.DriveType == DriveType.Network;
                removable = di.DriveType == DriveType.Removable;
                try { if (di.VolumeLabel.Length > 0) name = $"{di.VolumeLabel} ({root.TrimEnd('\\')})"; } catch { }
                if (net) server = MappedServer(root);
            }
            long? free = null, total = null;
            if (GetDiskFreeSpaceEx(root, out var f, out var t, out _)) { free = (long)f; total = (long)t; }
            return new VolumeInfo(root, name, net, removable, free, total, server);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Unità presenti, lette in parallelo con un tempo massimo per unità.</summary>
    public static async Task<List<VolumeInfo>> ListAsync()
    {
        var drives = DriveInfo.GetDrives().Select(d => d.Name).ToList();
        var tasks = drives.Select(async d =>
        {
            var t = Task.Run(() => Of(d));
            return await Task.WhenAny(t, Task.Delay(3000)) == t ? t.Result : null;
        });
        var res = await Task.WhenAll(tasks);
        return res.Where(v => v is { Total: > 0 }).Select(v => v!).ToList();
    }
}
