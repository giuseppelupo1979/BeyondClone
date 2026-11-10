using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using BeyondClone.Core;

namespace BeyondClone;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected void RaiseAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}

/// <summary>Icone di file e cartelle come le mostra Esplora file (lette per estensione, senza toccare il disco).</summary>
public static class ShellIcons
{
    static readonly Dictionary<string, ImageSource> Cache = new(StringComparer.OrdinalIgnoreCase);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr h);

    const uint SHGFI_ICON = 0x100, SHGFI_SMALLICON = 0x1, SHGFI_USEFILEATTRIBUTES = 0x10;
    const uint FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_NORMAL = 0x80;

    public static ImageSource? For(FileEntry? e)
    {
        if (e == null) return null;
        var ext = e.IsDir ? "<dir>" : Path.GetExtension(e.Name);
        if (Cache.TryGetValue(ext, out var img)) return img;
        var info = new SHFILEINFO();
        var probe = e.IsDir ? "cartella" : "file" + ext;
        SHGetFileInfo(probe, e.IsDir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(),
                      SHGFI_ICON | SHGFI_SMALLICON | SHGFI_USEFILEATTRIBUTES);
        if (info.hIcon == IntPtr.Zero) return null;
        var src = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
        DestroyIcon(info.hIcon);
        src.Freeze();
        Cache[ext] = src;
        return src;
    }
}

public static class UI
{
    public static Brush Res(string key) => (Brush)Application.Current.Resources[key];
    public static Brush ChangedBrush => Res("ChangedBrush");
    public static Brush OrphanBrush => Res("OrphanBrush");
    public static Brush MismatchBrush => Res("MismatchBrush");
    public static Brush SameBrush => Res("SameBrush");
    public static Brush MirrorBrush => Res("MirrorBrush");
    public static Brush NetworkBrush => Res("NetworkBrush");

    public static Brush Theme(string key) => Application.Current.TryFindResource(key) as Brush ?? SystemColors.ControlTextBrush;
    public static Brush Primary => Theme("TextFillColorPrimaryBrush");
    public static Brush Secondary => Theme("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Theme("TextFillColorTertiaryBrush");
    public static Brush Accent => Theme("AccentFillColorDefaultBrush");

    public static Brush Tint(Brush b, double alpha)
    {
        var c = ((SolidColorBrush)b).Color;
        var t = new SolidColorBrush(Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B));
        t.Freeze();
        return t;
    }

    public static Window? Owner => Application.Current.Windows.OfType<Window>().FirstOrDefault(w => w.IsActive) ?? Application.Current.MainWindow;

    public static bool Confirm(string title, string text, string action = "Procedi")
    {
        var r = MessageBox.Show(Owner!, text + $"\n\nPremi OK per «{action}».", title, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        return r == MessageBoxResult.OK;
    }

    public static void Info(string title, string text) =>
        MessageBox.Show(Owner!, text, title, MessageBoxButton.OK, MessageBoxImage.Information);

    public static string? PickFolder(string? start = null)
    {
        var d = new Microsoft.Win32.OpenFolderDialog { Title = "Scegli una cartella" };
        if (start != null && Directory.Exists(start)) d.InitialDirectory = start;
        return d.ShowDialog(Owner) == true ? d.FolderName : null;
    }

    public static string? PickFile()
    {
        var d = new Microsoft.Win32.OpenFileDialog { Title = "Scegli un file" };
        return d.ShowDialog(Owner) == true ? d.FileName : null;
    }

    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path) || Directory.Exists(path)) Process.Start("explorer.exe", $"/select,\"{path}\"");
        }
        catch { }
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }

    public static IntPtr Handle(Window? w) => w == null ? IntPtr.Zero : new WindowInteropHelper(w).Handle;
}
