using System.Text.Json;
using System.Text.Json.Serialization;

namespace BeyondClone.Core;

public sealed class SyncProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Nuovo profilo";
    public string Left { get; set; } = "";
    public string Right { get; set; } = "";
    /// <summary>Condivisione da collegare se la cartella non è raggiungibile, es. \\DS920\Foto</summary>
    public string LeftServer { get; set; } = "";
    public string RightServer { get; set; } = "";
    public SyncMode Mode { get; set; } = SyncMode.UpdateRight;
    public DeleteMode DeleteMode { get; set; } = DeleteMode.Archive;
    public DirOptions Options { get; set; } = new();
    public DateTime? LastRun { get; set; }
    public string? LastResult { get; set; }

    [JsonIgnore] public bool IsComplete => Left.Length > 0 && Right.Length > 0;

    public SyncProfile Clone()
    {
        var c = (SyncProfile)MemberwiseClone();
        c.Options = Options.Clone();
        return c;
    }
}

public sealed record RecentPair(string Left, string Right, DateTime Date)
{
    [JsonIgnore] public string Id => Left + "\u001F" + Right;
    [JsonIgnore] public string Title => $"{Path.GetFileName(Left.TrimEnd('\\'))} ↔ {Path.GetFileName(Right.TrimEnd('\\'))}";
}

/// <summary>Impostazioni dell'app: recenti, ultima selezione, server recenti.</summary>
public sealed class AppSettings
{
    public List<RecentPair> Recents { get; set; } = [];
    public List<string> RecentFolders { get; set; } = [];
    public List<string> RecentServers { get; set; } = [];
    /// <summary>"profile:{guid}" oppure "pair:{sinistra}\u001F{destra}"</summary>
    public string? LastSelection { get; set; }
    public bool ShowInspector { get; set; } = true;
    /// <summary>Aspetto: "Dark", "Light" oppure "System".</summary>
    public string Theme { get; set; } = "Dark";
}

public static class Storage
{
    public static string Folder
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BeyondClone");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    static string ProfilesPath => Path.Combine(Folder, "profili.json");
    static string SettingsPath => Path.Combine(Folder, "impostazioni.json");

    public static List<SyncProfile> LoadProfiles() => Load<List<SyncProfile>>(ProfilesPath) ?? [];
    public static void SaveProfiles(List<SyncProfile> list) => Save(ProfilesPath, list);
    public static AppSettings LoadSettings() => Load<AppSettings>(SettingsPath) ?? new AppSettings();
    public static void SaveSettings(AppSettings s) => Save(SettingsPath, s);

    static T? Load<T>(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) : default;
        }
        catch
        {
            return default;
        }
    }

    static void Save<T>(string path, T value)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(value, Json));
        File.Move(tmp, path, overwrite: true);
    }

    public static void AddRecent(AppSettings s, string left, string right)
    {
        var p = new RecentPair(left, right, DateTime.UtcNow);
        s.Recents.RemoveAll(r => r.Id == p.Id);
        s.Recents.Insert(0, p);
        if (s.Recents.Count > 15) s.Recents.RemoveRange(15, s.Recents.Count - 15);
    }

    public static void AddRecentFolder(AppSettings s, string folder)
    {
        s.RecentFolders.RemoveAll(f => string.Equals(f, folder, StringComparison.OrdinalIgnoreCase));
        s.RecentFolders.Insert(0, folder);
        if (s.RecentFolders.Count > 12) s.RecentFolders.RemoveRange(12, s.RecentFolders.Count - 12);
    }

    public static void AddRecentServer(AppSettings s, string server)
    {
        s.RecentServers.RemoveAll(f => string.Equals(f, server, StringComparison.OrdinalIgnoreCase));
        s.RecentServers.Insert(0, server);
        if (s.RecentServers.Count > 10) s.RecentServers.RemoveRange(10, s.RecentServers.Count - 10);
    }
}
