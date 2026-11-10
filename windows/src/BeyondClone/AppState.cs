using BeyondClone.Core;

namespace BeyondClone;

/// <summary>Profili, impostazioni e sessioni aperte. Più sessioni possono sincronizzare insieme.</summary>
public sealed class AppState
{
    public static AppState Instance { get; } = new();

    public List<SyncProfile> Profiles { get; }
    public AppSettings Settings { get; }
    readonly Dictionary<Guid, FolderSession> byProfile = [];
    public List<FolderSession> Adhoc { get; } = [];

    /// <summary>Qualcosa da mostrare nella barra laterale è cambiato.</summary>
    public event Action? SidebarChanged;

    AppState()
    {
        Profiles = Storage.LoadProfiles();
        Settings = Storage.LoadSettings();
    }

    public void NotifySidebar() => SidebarChanged?.Invoke();

    public SyncProfile? Profile(Guid id) => Profiles.FirstOrDefault(p => p.Id == id);

    public void SaveProfile(SyncProfile p)
    {
        var i = Profiles.FindIndex(x => x.Id == p.Id);
        if (i >= 0) Profiles[i] = p; else Profiles.Add(p);
        Storage.SaveProfiles(Profiles);
        NotifySidebar();
    }

    public void DeleteProfile(Guid id)
    {
        Close(id);
        Profiles.RemoveAll(p => p.Id == id);
        Storage.SaveProfiles(Profiles);
        NotifySidebar();
    }

    public SyncProfile? Duplicate(Guid id)
    {
        if (Profile(id) is not { } p) return null;
        var c = p.Clone();
        c.Id = Guid.NewGuid();
        c.Name += " (copia)";
        c.LastRun = null;
        c.LastResult = null;
        SaveProfile(c);
        return c;
    }

    public void MoveProfile(Guid id, int delta)
    {
        var i = Profiles.FindIndex(p => p.Id == id);
        var j = i + delta;
        if (i < 0 || j < 0 || j >= Profiles.Count) return;
        (Profiles[i], Profiles[j]) = (Profiles[j], Profiles[i]);
        Storage.SaveProfiles(Profiles);
        NotifySidebar();
    }

    public FolderSession? Existing(Guid id) => byProfile.GetValueOrDefault(id) ?? Adhoc.FirstOrDefault(s => s.Id == id);

    public FolderSession? OpenProfile(Guid id)
    {
        if (byProfile.TryGetValue(id, out var s)) return s;
        if (Profile(id) is not { } p) return null;
        s = FolderSession.FromProfile(p);
        Watch(s);
        byProfile[id] = s;
        NotifySidebar();
        return s;
    }

    public FolderSession OpenPair(string? left, string? right)
    {
        var s = Adhoc.FirstOrDefault(x => left != null && right != null &&
                                          string.Equals(x.LeftPath, left, StringComparison.OrdinalIgnoreCase) &&
                                          string.Equals(x.RightPath, right, StringComparison.OrdinalIgnoreCase));
        if (s != null) return s;
        s = FolderSession.Adhoc(left, right);
        Watch(s);
        Adhoc.Insert(0, s);
        NotifySidebar();
        return s;
    }

    public void Close(Guid id)
    {
        if (Existing(id) is { } s) s.StopScan();
        byProfile.Remove(id);
        Adhoc.RemoveAll(s => s.Id == id);
        NotifySidebar();
    }

    DateTime lastNotify = DateTime.MinValue;
    bool notifyPending;

    /// <summary>Le righe della barra laterale si aggiornano quando cambia lo stato di una sessione (al più 4 volte al secondo).</summary>
    void Watch(FolderSession s)
    {
        s.Changed += () =>
        {
            if (notifyPending) return;
            var wait = TimeSpan.FromMilliseconds(250) - (DateTime.UtcNow - lastNotify);
            if (wait <= TimeSpan.Zero)
            {
                lastNotify = DateTime.UtcNow;
                NotifySidebar();
                return;
            }
            notifyPending = true;
            _ = Task.Delay(wait).ContinueWith(_ => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
            {
                notifyPending = false;
                lastNotify = DateTime.UtcNow;
                NotifySidebar();
            }));
        };
    }

    public IEnumerable<FolderSession> Running => byProfile.Values.Concat(Adhoc).Where(s => s.IsRunning);

    // ---------- Impostazioni ----------

    public void SaveSettings() => Storage.SaveSettings(Settings);

    public void AddRecent(string left, string right)
    {
        Storage.AddRecent(Settings, left, right);
        Settings.LastSelection = "pair:" + left + "\u001F" + right;
        SaveSettings();
        NotifySidebar();
    }

    public void RemoveRecent(string id)
    {
        Settings.Recents.RemoveAll(r => r.Id == id);
        SaveSettings();
        NotifySidebar();
    }

    public void ClearRecents()
    {
        Settings.Recents.Clear();
        SaveSettings();
        NotifySidebar();
    }

    public void AddRecentFolder(string path)
    {
        Storage.AddRecentFolder(Settings, path);
        SaveSettings();
    }

    public void AddRecentServer(string server)
    {
        Storage.AddRecentServer(Settings, server);
        SaveSettings();
    }

    public void SetLastSelection(string? value)
    {
        Settings.LastSelection = value;
        SaveSettings();
    }
}
