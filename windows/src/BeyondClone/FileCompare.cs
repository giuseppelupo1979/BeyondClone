using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using BeyondClone.Core;

namespace BeyondClone;

public enum FileKind { Text, Binary, Image }

/// <summary>Riconoscimento del tipo di confronto da usare per due file.</summary>
public static class FileKindDetector
{
    static readonly HashSet<string> ImageExt = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".ico", ".heic", ".webp" };

    public static FileKind Detect(string l, string r)
    {
        if (ImageExt.Contains(Path.GetExtension(l)) && ImageExt.Contains(Path.GetExtension(r)) && Decodable(l) && Decodable(r)) return FileKind.Image;
        return LooksBinary(l) || LooksBinary(r) ? FileKind.Binary : FileKind.Text;
    }

    /// <summary>Un file con estensione da immagine che non si riesce a decodificare va confrontato come testo o binario.</summary>
    static bool Decodable(string path)
    {
        try
        {
            using var s = File.OpenRead(path);
            var d = BitmapDecoder.Create(s, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            return d.Frames.Count > 0;
        }
        catch { return false; }
    }

    public static Window Open(string l, string r) => Detect(l, r) switch
    {
        FileKind.Image => new ImageCompareWindow(l, r),
        FileKind.Binary => new HexCompareWindow(l, r),
        _ => new TextCompareWindow(l, r),
    };

    public static bool LooksBinary(string path)
    {
        try
        {
            using var f = File.OpenRead(path);
            var buf = new byte[8192];
            int n = f.Read(buf, 0, buf.Length);
            if (n >= 2 && ((buf[0] == 0xFF && buf[1] == 0xFE) || (buf[0] == 0xFE && buf[1] == 0xFF))) return false;
            return buf.AsSpan(0, n).Contains((byte)0);
        }
        catch { return false; }
    }
}

// ===================== Testo con evidenziazione =====================

/// <summary>TextBlock che mostra segmenti con le parti diverse evidenziate.</summary>
public sealed class SegmentBlock : TextBlock
{
    public static readonly DependencyProperty SegmentsProperty = DependencyProperty.Register(
        nameof(Segments), typeof(IReadOnlyList<Segment>), typeof(SegmentBlock), new PropertyMetadata(null, (d, _) => ((SegmentBlock)d).Rebuild()));

    public IReadOnlyList<Segment>? Segments
    {
        get => (IReadOnlyList<Segment>?)GetValue(SegmentsProperty);
        set => SetValue(SegmentsProperty, value);
    }

    static readonly Brush Highlight = UI.Tint(new SolidColorBrush(Color.FromRgb(0xF5, 0x9E, 0x0B)), 0.45);

    void Rebuild()
    {
        Inlines.Clear();
        if (Segments == null) return;
        foreach (var s in Segments)
        {
            var run = new Run(s.Text.Replace("\t", "    "));
            if (s.Changed) run.Background = Highlight;
            Inlines.Add(run);
        }
    }
}

// ===================== Confronto testo =====================

public sealed class TextRowVM(DiffRow row, int index)
{
    public DiffRow Row => row;
    public int Index => index;
    (List<Segment> L, List<Segment> R)? inline;

    (List<Segment> L, List<Segment> R) Inline => inline ??= row.Kind == RowKind.Changed
        ? TextDiff.Inline(row.Left ?? "", row.Right ?? "")
        : ([new Segment(Trim(row.Left), false)], [new Segment(Trim(row.Right), false)]);

    static string Trim(string? s) => s == null ? "" : s.Length > 600 ? s[..600] + "…" : s;

    public IReadOnlyList<Segment> LeftSegments => Inline.L;
    public IReadOnlyList<Segment> RightSegments => Inline.R;
    public string LeftNo => row.LeftNo?.ToString() ?? "";
    public string RightNo => row.RightNo?.ToString() ?? "";
    public string Marker => row.Kind switch { RowKind.Changed => "≠", RowKind.LeftOnly => "−", RowKind.RightOnly => "+", _ => "" };
    public Brush MarkerBrush => row.Kind switch { RowKind.Changed => UI.MismatchBrush, RowKind.LeftOnly => UI.ChangedBrush, RowKind.RightOnly => UI.SameBrush, _ => Brushes.Transparent };
    public Brush Back => row.Kind switch
    {
        RowKind.Changed => UI.Tint(UI.MismatchBrush, 0.12),
        RowKind.LeftOnly => UI.Tint(UI.ChangedBrush, 0.14),
        RowKind.RightOnly => UI.Tint(UI.SameBrush, 0.14),
        _ => Brushes.Transparent,
    };
}

public sealed class TextCompareWindow : Window
{
    sealed class SideText
    {
        public string? Path;
        public List<string> Lines = [];
        public Encoding Encoding = new UTF8Encoding(false);
        public string Ending = "\r\n";
        public bool Trailing = true;
        public bool Dirty;
    }

    readonly SideText left = new(), right = new();
    List<DiffRow> rows = [];
    List<int> visible = [];
    List<(int Start, int End)> blocks = [];
    readonly Stack<(List<string> L, List<string> R, bool LD, bool RD)> undo = new();
    DiffOptions options = new();
    int filter; // 0 tutte, 1 differenze, 2 uguali

    readonly ListView list = new() { SelectionMode = SelectionMode.Extended, BorderThickness = new Thickness(0) };
    readonly TextBlock status = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock leftPath = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock rightPath = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly SegmentBlock detailLeft = new() { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
    readonly SegmentBlock detailRight = new() { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };

    public TextCompareWindow(string l, string r)
    {
        Title = $"{Path.GetFileName(l)} ↔ {Path.GetFileName(r)} – Confronto testo";
        Width = 1400;
        Height = 860;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        left.Path = l;
        right.Path = r;
        Content = Build();
        Load(left);
        Load(right);
        Rediff();
    }

    UIElement Build()
    {
        var root = new DockPanel();
        // Barra dei comandi
        var bar = new WrapPanel { Margin = new Thickness(10, 6, 10, 6) };
        Button Icon(string glyph, string tip, Action a, string? text = null)
        {
            var b = new Button { Style = (Style)Application.Current.FindResource("IconButton"), ToolTip = tip };
            if (text == null) b.Content = glyph;
            else
            {
                b.Width = double.NaN;
                b.Padding = new Thickness(8, 0, 8, 0);
                var sp = new StackPanel { Orientation = Orientation.Horizontal };
                sp.Children.Add(new TextBlock { Text = glyph, FontFamily = (FontFamily)Application.Current.FindResource("IconFont"), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
                sp.Children.Add(new TextBlock { Text = text, FontFamily = new FontFamily("Segoe UI Variable, Segoe UI"), FontSize = 13 });
                b.Content = sp;
            }
            b.Click += (_, _) => a();
            bar.Children.Add(b);
            return b;
        }
        foreach (var (i, name, tip) in new[] { (0, "Tutte", "Mostra tutte le righe"), (1, "Differenze", "Mostra solo le righe diverse"), (2, "Uguali", "Mostra solo le righe uguali") })
        {
            var rb = new RadioButton { Content = name, GroupName = "tf", Style = (Style)Application.Current.FindResource("PillRadio"), IsChecked = i == 0, ToolTip = tip, VerticalAlignment = VerticalAlignment.Center };
            int idx = i;
            rb.Checked += (_, _) => { filter = idx; RebuildVisible(); };
            bar.Children.Add(rb);
        }
        bar.Children.Add(new Border { Width = 16 });
        Icon("", "Differenza precedente (Alt+↑)", PrevDiff);
        Icon("", "Differenza successiva (Alt+↓)", NextDiff);
        Icon("", "Copia le righe selezionate a sinistra (Alt+←)", () => CopySelection(Side.Left), "A sinistra");
        Icon("", "Copia le righe selezionate a destra (Alt+→)", () => CopySelection(Side.Right), "A destra");
        Icon("", "Annulla l'ultima modifica (Ctrl+Z)", Undo);
        Icon("", "Scambia i due lati", Swap);
        Icon("", "Ricarica dal disco (F5)", Reload);
        Icon("", "Salva i lati modificati (Ctrl+S)", SaveAll, "Salva");
        var ws = new CheckBox { Content = "Ignora spazi", Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, ToolTip = "Ignora spazi e tabulazioni nel confronto delle righe" };
        var cs = new CheckBox { Content = "Ignora maiuscole", Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, ToolTip = "Ignora la differenza tra maiuscole e minuscole" };
        ws.Click += (_, _) => { options = options with { IgnoreWhitespace = ws.IsChecked == true }; Rediff(); };
        cs.Click += (_, _) => { options = options with { IgnoreCase = cs.IsChecked == true }; Rediff(); };
        bar.Children.Add(ws);
        bar.Children.Add(cs);
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);

        // Percorsi
        var paths = new Grid { Margin = new Thickness(10, 0, 10, 4) };
        paths.ColumnDefinitions.Add(new ColumnDefinition());
        paths.ColumnDefinitions.Add(new ColumnDefinition());
        paths.Children.Add(leftPath);
        Grid.SetColumn(rightPath, 1);
        paths.Children.Add(rightPath);
        DockPanel.SetDock(paths, Dock.Top);
        root.Children.Add(paths);

        // Barra di stato e dettaglio della riga
        var bottom = new Border { Padding = new Thickness(10, 5, 10, 5), BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = UI.Theme("CardStrokeColorDefaultBrush"), Child = status };
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(bottom);
        var detail = new StackPanel { Margin = new Thickness(10, 4, 10, 4) };
        detail.Children.Add(detailLeft);
        detail.Children.Add(detailRight);
        var detailBox = new ScrollViewer { Content = detail, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Height = 52,
                                           ToolTip = "Le due righe selezionate per intero, una sopra l'altra" };
        DockPanel.SetDock(detailBox, Dock.Bottom);
        root.Children.Add(detailBox);

        // Lista
        var gv = new GridView();
        gv.Columns.Add(TextCol("", 54, "LeftNo", true));
        gv.Columns.Add(SegCol("Sinistra", 560, "LeftSegments"));
        gv.Columns.Add(MarkerCol());
        gv.Columns.Add(TextCol("", 54, "RightNo", true));
        gv.Columns.Add(SegCol("Destra", 560, "RightSegments"));
        list.View = gv;
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        var style = new Style(typeof(ListViewItem), (Style)Application.Current.FindResource(typeof(ListViewItem)));
        style.Setters.Add(new Setter(BackgroundProperty, new Binding("Back")));
        style.Setters.Add(new Setter(HeightProperty, 22.0));
        style.Setters.Add(new Setter(MinHeightProperty, 22.0));
        style.Setters.Add(new Setter(PaddingProperty, new Thickness(0)));
        list.ItemContainerStyle = style;
        list.SelectionChanged += (_, _) => UpdateDetail();
        list.MouseDoubleClick += (_, _) => EditRow();
        root.Children.Add(list);

        PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (Keyboard.Modifiers == ModifierKeys.Alt)
            {
                if (key == Key.Down) { NextDiff(); e.Handled = true; }
                if (key == Key.Up) { PrevDiff(); e.Handled = true; }
                if (key == Key.Left) { CopySelection(Side.Left); e.Handled = true; }
                if (key == Key.Right) { CopySelection(Side.Right); e.Handled = true; }
            }
            else if (Keyboard.Modifiers == ModifierKeys.Control && key == Key.Z) { Undo(); e.Handled = true; }
            else if (Keyboard.Modifiers == ModifierKeys.Control && key == Key.S) { SaveAll(); e.Handled = true; }
            else if (key == Key.F5) { Reload(); e.Handled = true; }
        };
        Closing += (_, e) =>
        {
            if ((left.Dirty || right.Dirty) && !UI.Confirm("Modifiche non salvate", "Chiudere senza salvare le modifiche?", "Chiudi senza salvare")) e.Cancel = true;
        };
        return root;
    }

    static GridViewColumn TextCol(string header, double width, string path, bool gutter)
    {
        var f = new FrameworkElementFactory(typeof(TextBlock));
        f.SetBinding(TextBlock.TextProperty, new Binding(path));
        f.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Right);
        f.SetValue(TextBlock.FontFamilyProperty, new FontFamily("Cascadia Mono, Consolas"));
        f.SetValue(TextBlock.FontSizeProperty, 11.0);
        if (gutter) f.SetValue(TextBlock.ForegroundProperty, UI.Tertiary);
        return new GridViewColumn { Header = header, Width = width, CellTemplate = new DataTemplate { VisualTree = f } };
    }

    static GridViewColumn SegCol(string header, double width, string path)
    {
        var f = new FrameworkElementFactory(typeof(SegmentBlock));
        f.SetBinding(SegmentBlock.SegmentsProperty, new Binding(path));
        f.SetValue(TextBlock.FontFamilyProperty, new FontFamily("Cascadia Mono, Consolas"));
        f.SetValue(TextBlock.FontSizeProperty, 12.0);
        f.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        return new GridViewColumn { Header = header, Width = width, CellTemplate = new DataTemplate { VisualTree = f } };
    }

    static GridViewColumn MarkerCol()
    {
        var f = new FrameworkElementFactory(typeof(TextBlock));
        f.SetBinding(TextBlock.TextProperty, new Binding("Marker"));
        f.SetBinding(TextBlock.ForegroundProperty, new Binding("MarkerBrush"));
        f.SetValue(TextBlock.FontWeightProperty, FontWeights.Bold);
        f.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        return new GridViewColumn { Header = "", Width = 30, CellTemplate = new DataTemplate { VisualTree = f } };
    }

    // ---------- Caricamento e salvataggio ----------

    static (List<string> Lines, string Ending, bool Trailing) Split(string text)
    {
        if (text.Length == 0) return ([], "\r\n", true);
        var ending = text.Contains("\r\n") ? "\r\n" : "\n";
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').ToList();
        bool trailing = false;
        if (lines.Count > 0 && lines[^1].Length == 0) { lines.RemoveAt(lines.Count - 1); trailing = true; }
        return (lines, ending, trailing);
    }

    static void Load(SideText side)
    {
        try
        {
            var bytes = File.ReadAllBytes(side.Path!);
            Encoding enc;
            string text;
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) { enc = new UTF8Encoding(true); text = Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3); }
            else if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) { enc = Encoding.Unicode; text = Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2); }
            else if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) { enc = Encoding.BigEndianUnicode; text = Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2); }
            else
            {
                try { text = new UTF8Encoding(false, true).GetString(bytes); enc = new UTF8Encoding(false); }
                catch
                {
                    // Testi non UTF-8 su Windows: quasi sempre Windows-1252.
                    enc = Encoding.GetEncoding(1252);
                    text = enc.GetString(bytes);
                }
            }
            (side.Lines, side.Ending, side.Trailing) = Split(text);
            side.Encoding = enc;
            side.Dirty = false;
        }
        catch (Exception e)
        {
            side.Lines = [];
            UI.Info("Impossibile leggere il file", e.Message);
        }
    }

    void Save(SideText side)
    {
        if (side.Path == null) return;
        var text = string.Join(side.Ending, side.Lines) + (side.Trailing && side.Lines.Count > 0 ? side.Ending : "");
        try
        {
            File.WriteAllText(side.Path, text, side.Encoding);
            side.Dirty = false;
        }
        catch (Exception e) { UI.Info("Salvataggio non riuscito", e.Message); }
    }

    void SaveAll()
    {
        if (left.Dirty) Save(left);
        if (right.Dirty) Save(right);
        UpdateStatus();
    }

    void Reload()
    {
        if ((left.Dirty || right.Dirty) && !UI.Confirm("Ricaricare dal disco?", "Le modifiche non salvate andranno perse.", "Ricarica")) return;
        Load(left);
        Load(right);
        undo.Clear();
        Rediff();
    }

    void Swap()
    {
        (left.Path, right.Path) = (right.Path, left.Path);
        (left.Lines, right.Lines) = (right.Lines, left.Lines);
        (left.Encoding, right.Encoding) = (right.Encoding, left.Encoding);
        (left.Ending, right.Ending) = (right.Ending, left.Ending);
        (left.Dirty, right.Dirty) = (right.Dirty, left.Dirty);
        undo.Clear();
        Rediff();
    }

    // ---------- Diff ----------

    void Rediff()
    {
        rows = TextDiff.Rows(left.Lines, right.Lines, options);
        blocks = [];
        int? start = null;
        for (int i = 0; i < rows.Count; i++)
        {
            if (rows[i].Kind == RowKind.Equal) { if (start != null) { blocks.Add((start.Value, i)); start = null; } }
            else start ??= i;
        }
        if (start != null) blocks.Add((start.Value, rows.Count));
        RebuildVisible();
    }

    void RebuildVisible()
    {
        visible = Enumerable.Range(0, rows.Count).Where(i => filter switch
        {
            1 => rows[i].Kind != RowKind.Equal,
            2 => rows[i].Kind == RowKind.Equal,
            _ => true,
        }).ToList();
        list.ItemsSource = visible.Select(i => new TextRowVM(rows[i], i)).ToList();
        UpdateStatus();
    }

    void UpdateStatus()
    {
        leftPath.Text = (left.Dirty ? "● " : "") + left.Path;
        rightPath.Text = (right.Dirty ? "● " : "") + right.Path;
        leftPath.ToolTip = left.Dirty ? "Modificato, non salvato" : left.Path;
        rightPath.ToolTip = right.Dirty ? "Modificato, non salvato" : right.Path;
        int ch = rows.Count(r => r.Kind == RowKind.Changed), lo = rows.Count(r => r.Kind == RowKind.LeftOnly), ro = rows.Count(r => r.Kind == RowKind.RightOnly);
        status.Text = blocks.Count == 0
            ? "I due testi sono identici"
            : $"{blocks.Count} blocchi di differenze · ≠ {ch} modificate · − {lo} solo a sinistra · + {ro} solo a destra   |   {left.Encoding.WebName.ToUpperInvariant()} {(left.Ending == "\r\n" ? "CRLF" : "LF")}  ·  {right.Encoding.WebName.ToUpperInvariant()} {(right.Ending == "\r\n" ? "CRLF" : "LF")}";
        status.Foreground = blocks.Count == 0 ? UI.SameBrush : UI.Primary;
    }

    void UpdateDetail()
    {
        if (list.SelectedItems.Count == 1 && list.SelectedItem is TextRowVM r)
        {
            var seg = r.Row.Kind == RowKind.Changed ? TextDiff.Inline(r.Row.Left ?? "", r.Row.Right ?? "")
                : ([new Segment(r.Row.Left ?? "(riga assente)", false)], [new Segment(r.Row.Right ?? "(riga assente)", false)]);
            detailLeft.Segments = [new Segment("◀ ", false), .. seg.Item1];
            detailRight.Segments = [new Segment("▶ ", false), .. seg.Item2];
        }
        else
        {
            detailLeft.Segments = [new Segment(list.SelectedItems.Count > 1 ? $"{list.SelectedItems.Count} righe selezionate" : "Seleziona una riga per vederla per intero. Doppio clic per modificarla.", false)];
            detailRight.Segments = null;
        }
    }

    void Select(int start, int end)
    {
        list.SelectedItems.Clear();
        object? first = null;
        foreach (TextRowVM item in list.Items)
            if (item.Index >= start && item.Index < end) { list.SelectedItems.Add(item); first ??= item; }
        if (first != null) list.ScrollIntoView(first);
    }

    void NextDiff()
    {
        int cur = list.SelectedItems.OfType<TextRowVM>().Select(r => r.Index).DefaultIfEmpty(-1).Max();
        var b = blocks.FirstOrDefault(x => x.Start > cur, (Start: -1, End: -1));
        if (b.Start >= 0) Select(b.Start, b.End);
    }

    void PrevDiff()
    {
        int cur = list.SelectedItems.OfType<TextRowVM>().Select(r => r.Index).DefaultIfEmpty(rows.Count).Min();
        var b = blocks.LastOrDefault(x => x.End <= cur, (Start: -1, End: -1));
        if (b.Start >= 0) Select(b.Start, b.End);
    }

    // ---------- Modifiche ----------

    void Commit(List<string> newLeft, List<string> newRight)
    {
        undo.Push((left.Lines, right.Lines, left.Dirty, right.Dirty));
        if (!newLeft.SequenceEqual(left.Lines)) { left.Lines = newLeft; left.Dirty = true; }
        if (!newRight.SequenceEqual(right.Lines)) { right.Lines = newRight; right.Dirty = true; }
        Rediff();
    }

    void Undo()
    {
        if (undo.Count == 0) return;
        var u = undo.Pop();
        (left.Lines, right.Lines, left.Dirty, right.Dirty) = (u.L, u.R, u.LD, u.RD);
        Rediff();
    }

    HashSet<int> SelectedIndexes => list.SelectedItems.OfType<TextRowVM>().Select(r => r.Index).ToHashSet();

    void CopySelection(Side dest)
    {
        var sel = SelectedIndexes;
        if (sel.Count == 0) return;
        if (dest == Side.Right)
            Commit(left.Lines, rows.Select((r, i) => sel.Contains(i) ? r.Left : r.Right).Where(x => x != null).Select(x => x!).ToList());
        else
            Commit(rows.Select((r, i) => sel.Contains(i) ? r.Right : r.Left).Where(x => x != null).Select(x => x!).ToList(), right.Lines);
    }

    void EditRow()
    {
        if (list.SelectedItem is not TextRowVM vm) return;
        var row = vm.Row;
        var w = new Window
        {
            Title = "Modifica riga", Width = 760, Height = 260, Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var sp = new StackPanel { Margin = new Thickness(16) };
        var lt = new TextBox { Text = row.Left ?? "", FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 2, 0, 10), ToolTip = "Testo della riga a sinistra" };
        var rt = new TextBox { Text = row.Right ?? "", FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 2, 0, 10), ToolTip = "Testo della riga a destra" };
        sp.Children.Add(new TextBlock { Text = "Sinistra" + (row.Left == null ? " (assente: scrivi per inserirla)" : ""), Foreground = UI.Secondary });
        sp.Children.Add(lt);
        sp.Children.Add(new TextBlock { Text = "Destra" + (row.Right == null ? " (assente: scrivi per inserirla)" : ""), Foreground = UI.Secondary });
        sp.Children.Add(rt);
        var ok = new Button { Content = "Applica", IsDefault = true, Padding = new Thickness(16, 4, 16, 4), HorizontalAlignment = HorizontalAlignment.Right, ToolTip = "Applica la modifica alla riga (Invio)" };
        ok.Click += (_, _) => w.DialogResult = true;
        sp.Children.Add(ok);
        w.Content = sp;
        if (w.ShowDialog() != true) return;
        var copy = rows.Select(r => new DiffRow { Kind = r.Kind, Left = r.Left, Right = r.Right }).ToList();
        copy[vm.Index].Left = row.Left == null && lt.Text.Length == 0 ? null : lt.Text;
        copy[vm.Index].Right = row.Right == null && rt.Text.Length == 0 ? null : rt.Text;
        Commit(copy.Where(r => r.Left != null).Select(r => r.Left!).ToList(), copy.Where(r => r.Right != null).Select(r => r.Right!).ToList());
    }
}

// ===================== Confronto esadecimale =====================

public sealed class HexRowVM(int row, byte[] a, byte[] b)
{
    public string Offset => (row * 16).ToString("X8");
    public IReadOnlyList<Segment> LeftHex => Hex(a, b);
    public IReadOnlyList<Segment> RightHex => Hex(b, a);
    public IReadOnlyList<Segment> LeftAscii => Ascii(a, b);
    public IReadOnlyList<Segment> RightAscii => Ascii(b, a);

    List<Segment> Hex(byte[] mine, byte[] other)
    {
        var res = new List<Segment>();
        int off = row * 16;
        for (int i = 0; i < 16 && off + i < mine.Length; i++)
        {
            int p = off + i;
            bool diff = p >= other.Length || other[p] != mine[p];
            res.Add(new Segment(mine[p].ToString("X2"), diff));
            res.Add(new Segment(i == 7 ? "  " : " ", false));
        }
        return res;
    }

    List<Segment> Ascii(byte[] mine, byte[] other)
    {
        var res = new List<Segment>();
        int off = row * 16;
        for (int i = 0; i < 16 && off + i < mine.Length; i++)
        {
            int p = off + i;
            var c = mine[p] is >= 32 and < 127 ? ((char)mine[p]).ToString() : "·";
            res.Add(new Segment(c, p >= other.Length || other[p] != mine[p]));
        }
        return res;
    }
}

public sealed class HexCompareWindow : Window
{
    readonly byte[] a, b;
    readonly List<int> diffRows = [];
    readonly ListView list = new() { BorderThickness = new Thickness(0) };
    bool onlyDiffs;

    public HexCompareWindow(string l, string r)
    {
        Title = $"{Path.GetFileName(l)} ↔ {Path.GetFileName(r)} – Confronto esadecimale";
        Width = 1300;
        Height = 820;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        a = SafeRead(l);
        b = SafeRead(r);
        int common = Math.Min(a.Length, b.Length);
        long diffBytes = 0;
        int last = -1;
        for (int i = 0; i < common; i++)
            if (a[i] != b[i]) { diffBytes++; if (i >> 4 != last) { last = i >> 4; diffRows.Add(last); } }
        int longer = Math.Max(a.Length, b.Length);
        diffBytes += longer - common;
        for (int row = Math.Max(common >> 4, last + 1); row < (longer + 15) >> 4; row++) diffRows.Add(row);

        var root = new DockPanel();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 6, 10, 6) };
        var only = new CheckBox { Content = "Solo righe diverse", VerticalAlignment = VerticalAlignment.Center, ToolTip = "Mostra solo le righe con byte diversi" };
        only.Click += (_, _) => { onlyDiffs = only.IsChecked == true; Fill(); };
        bar.Children.Add(only);
        var prev = new Button { Content = "", Style = (Style)Application.Current.FindResource("IconButton"), ToolTip = "Differenza precedente", Margin = new Thickness(12, 0, 0, 0) };
        var next = new Button { Content = "", Style = (Style)Application.Current.FindResource("IconButton"), ToolTip = "Differenza successiva" };
        prev.Click += (_, _) => Jump(false);
        next.Click += (_, _) => Jump(true);
        bar.Children.Add(prev);
        bar.Children.Add(next);
        bar.Children.Add(new TextBlock
        {
            Text = diffBytes == 0 ? "I due file sono identici" : $"{Fmt.Number(diffBytes)} byte diversi in {Fmt.Number(diffRows.Count)} righe · sinistra {Fmt.Size(a.Length)} · destra {Fmt.Size(b.Length)}",
            Foreground = diffBytes == 0 ? UI.SameBrush : UI.ChangedBrush, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0),
        });
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);

        var gv = new GridView();
        gv.Columns.Add(Col("Offset", 90, "Offset", false));
        gv.Columns.Add(Col("Sinistra", 400, "LeftHex", true));
        gv.Columns.Add(Col("ASCII", 150, "LeftAscii", true));
        gv.Columns.Add(Col("Destra", 400, "RightHex", true));
        gv.Columns.Add(Col("ASCII", 150, "RightAscii", true));
        list.View = gv;
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        root.Children.Add(list);
        Content = root;
        Fill();
    }

    static byte[] SafeRead(string p)
    {
        try
        {
            var info = new FileInfo(p);
            if (info.Length > 512L * 1024 * 1024) throw new IOException("File oltre 512 MB: confronto esadecimale non disponibile");
            return File.ReadAllBytes(p);
        }
        catch (Exception e)
        {
            UI.Info("Impossibile leggere il file", e.Message);
            return [];
        }
    }

    static GridViewColumn Col(string header, double width, string path, bool segments)
    {
        FrameworkElementFactory f;
        if (segments)
        {
            f = new FrameworkElementFactory(typeof(SegmentBlock));
            f.SetBinding(SegmentBlock.SegmentsProperty, new Binding(path));
        }
        else
        {
            f = new FrameworkElementFactory(typeof(TextBlock));
            f.SetBinding(TextBlock.TextProperty, new Binding(path));
            f.SetValue(TextBlock.ForegroundProperty, UI.Secondary);
        }
        f.SetValue(TextBlock.FontFamilyProperty, new FontFamily("Cascadia Mono, Consolas"));
        f.SetValue(TextBlock.FontSizeProperty, 12.0);
        return new GridViewColumn { Header = header, Width = width, CellTemplate = new DataTemplate { VisualTree = f } };
    }

    int TotalRows => (Math.Max(a.Length, b.Length) + 15) >> 4;

    void Fill()
    {
        IEnumerable<int> rows = onlyDiffs ? diffRows : Enumerable.Range(0, TotalRows);
        list.ItemsSource = rows.Select(r => new HexRowVM(r, a, b)).ToList();
    }

    void Jump(bool forward)
    {
        if (diffRows.Count == 0) return;
        var items = (List<HexRowVM>)list.ItemsSource;
        int cur = list.SelectedIndex;
        int curRow = cur >= 0 ? Convert.ToInt32(items[cur].Offset, 16) >> 4 : (forward ? -1 : int.MaxValue);
        int target = forward ? diffRows.FirstOrDefault(r => r > curRow, -1) : diffRows.LastOrDefault(r => r < curRow, -1);
        if (target < 0) return;
        int idx = onlyDiffs ? diffRows.IndexOf(target) : target;
        list.SelectedIndex = idx;
        list.ScrollIntoView(list.SelectedItem);
    }
}

// ===================== Confronto immagini =====================

public sealed class ImageCompareWindow : Window
{
    readonly BitmapSource? left, right;
    readonly Grid stage = new();
    readonly TextBlock summary = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
    readonly Slider tolerance = new() { Minimum = 0, Maximum = 64, Width = 140, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center,
                                        ToolTip = "Differenza per canale (0–255) sotto la quale due pixel contano come uguali" };
    readonly Slider opacity = new() { Minimum = 0, Maximum = 1, Value = 0.5, Width = 160, VerticalAlignment = VerticalAlignment.Center,
                                      ToolTip = "Trasparenza dell'immagine destra sopra la sinistra" };
    int mode;

    public ImageCompareWindow(string l, string r)
    {
        Title = $"{Path.GetFileName(l)} ↔ {Path.GetFileName(r)} – Confronto immagini";
        Width = 1300;
        Height = 860;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        left = Load(l);
        right = Load(r);
        var root = new DockPanel();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 6, 10, 6) };
        foreach (var (i, name, tip) in new[] { (0, "Affiancate", "Le due immagini una accanto all'altra"), (1, "Differenza", "Pixel diversi in rosso sull'immagine sinistra attenuata"), (2, "Sovrapposte", "La destra sopra la sinistra, con trasparenza regolabile") })
        {
            var rb = new RadioButton { Content = name, GroupName = "im", Style = (Style)Application.Current.FindResource("PillRadio"), IsChecked = i == 0, ToolTip = tip, VerticalAlignment = VerticalAlignment.Center };
            int idx = i;
            rb.Checked += (_, _) => { mode = idx; Render(); };
            bar.Children.Add(rb);
        }
        bar.Children.Add(new TextBlock { Text = "Tolleranza", Margin = new Thickness(16, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        bar.Children.Add(tolerance);
        bar.Children.Add(new TextBlock { Text = "Trasparenza", Margin = new Thickness(16, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        bar.Children.Add(opacity);
        bar.Children.Add(summary);
        tolerance.ValueChanged += (_, _) => Render();
        opacity.ValueChanged += (_, _) => { if (mode == 2) Render(); };
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(stage);
        Content = root;
        Render();
    }

    static BitmapSource? Load(string p)
    {
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.UriSource = new Uri(p);
            img.EndInit();
            img.Freeze();
            return new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
        }
        catch { return null; }
    }

    static Image View(ImageSource? s) => new() { Source = s, Stretch = Stretch.Uniform, Margin = new Thickness(8) };

    void Render()
    {
        stage.Children.Clear();
        stage.ColumnDefinitions.Clear();
        if (left == null || right == null)
        {
            stage.Children.Add(new TextBlock { Text = "Impossibile leggere una delle due immagini", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
            return;
        }
        var (diff, changed, total) = Diff((int)tolerance.Value);
        summary.Text = diff == null
            ? $"Dimensioni diverse: {left.PixelWidth}×{left.PixelHeight} e {right.PixelWidth}×{right.PixelHeight}"
            : changed == 0 ? $"Immagini identiche ({left.PixelWidth}×{left.PixelHeight})" : $"{Fmt.Number(changed)} pixel diversi su {Fmt.Number(total)} ({100.0 * changed / total:0.00}%)";
        summary.Foreground = changed == 0 && diff != null ? UI.SameBrush : UI.ChangedBrush;
        switch (mode)
        {
            case 0:
                stage.ColumnDefinitions.Add(new ColumnDefinition());
                stage.ColumnDefinitions.Add(new ColumnDefinition());
                stage.Children.Add(View(left));
                var rv = View(right);
                Grid.SetColumn(rv, 1);
                stage.Children.Add(rv);
                break;
            case 1:
                stage.Children.Add(diff != null ? View(diff) : new TextBlock { Text = "La mappa delle differenze richiede immagini delle stesse dimensioni", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
                break;
            default:
                stage.Children.Add(View(left));
                var top = View(right);
                top.Opacity = opacity.Value;
                stage.Children.Add(top);
                break;
        }
    }

    (BitmapSource? Image, long Changed, long Total) Diff(int tol)
    {
        if (left!.PixelWidth != right!.PixelWidth || left.PixelHeight != right.PixelHeight) return (null, 0, 0);
        int w = left.PixelWidth, h = left.PixelHeight, stride = w * 4;
        if ((long)w * h > 80_000_000) return (null, 0, 0);
        var pa = new byte[stride * h];
        var pb = new byte[stride * h];
        left.CopyPixels(pa, stride, 0);
        right.CopyPixels(pb, stride, 0);
        var outp = new byte[stride * h];
        long changed = 0;
        for (int i = 0; i < pa.Length; i += 4)
        {
            int d = Math.Max(Math.Max(Math.Abs(pa[i] - pb[i]), Math.Abs(pa[i + 1] - pb[i + 1])), Math.Max(Math.Abs(pa[i + 2] - pb[i + 2]), Math.Abs(pa[i + 3] - pb[i + 3])));
            if (d > tol)
            {
                changed++;
                outp[i] = 60; outp[i + 1] = 30; outp[i + 2] = 255; outp[i + 3] = 255;
            }
            else
            {
                byte gray = (byte)((pa[i + 2] * 3 + pa[i + 1] * 6 + pa[i]) / 10);
                byte faded = (byte)(160 + gray * 95 / 255);
                outp[i] = outp[i + 1] = outp[i + 2] = faded;
                outp[i + 3] = 255;
            }
        }
        var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, outp, stride);
        bmp.Freeze();
        return (bmp, changed, (long)w * h);
    }
}
