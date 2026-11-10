using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using BeyondClone.Core;

namespace BeyondClone;

/// <summary>Base per le finestre di dialogo costruite in codice.</summary>
public abstract class DialogBase : Window
{
    protected DialogBase(string title, double width, double height)
    {
        Title = title;
        Width = width;
        Height = height;
        MinWidth = Math.Min(width, 480);
        MinHeight = Math.Min(height, 320);
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/app.ico"));
    }

    protected static TextBlock Label(string text, double size = 13, bool bold = false, Brush? brush = null) => new()
    {
        Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = brush ?? UI.Primary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4),
    };

    protected Button Btn(string text, string tip, Action action, bool primary = false)
    {
        var b = new Button { Content = text, Padding = new Thickness(16, 5, 16, 5), Margin = new Thickness(8, 0, 0, 0), ToolTip = tip, MinWidth = 90 };
        if (primary)
        {
            b.IsDefault = true;
            b.Background = UI.Accent;
            b.Foreground = Brushes.White;
        }
        b.Click += (_, _) => action();
        return b;
    }

    protected static StackPanel Buttons(params Button[] buttons)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var b in buttons) sp.Children.Add(b);
        return sp;
    }

    protected static ComboBox Combo<T>(IEnumerable<T> items, T selected, Func<T, string> title, string tip)
    {
        var c = new ComboBox { Margin = new Thickness(0, 0, 0, 8), ToolTip = tip, MinWidth = 260, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var i in items) c.Items.Add(new ComboBoxItem { Content = title(i), Tag = i });
        c.SelectedIndex = items.ToList().IndexOf(selected);
        return c;
    }

    protected static T Selected<T>(ComboBox c) => (T)((ComboBoxItem)c.SelectedItem).Tag;

    protected static CheckBox Check(string text, bool value, string tip) =>
        new() { Content = text, IsChecked = value, ToolTip = tip, Margin = new Thickness(0, 2, 0, 6) };
}

// ===================== Anteprima delle operazioni =====================

public sealed class PlanPreviewWindow : DialogBase
{
    sealed class OpRow(PlannedOp op, PlanRequest req)
    {
        public PlannedOp Op => op;
        public string Glyph => op.Kind switch
        {
            OpKind.Copy => op.Replaces ? "" : op.Dest == Side.Right ? "" : "",
            OpKind.Mkdir => "",
            _ => "",
        };
        public Brush Brush => op.Kind == OpKind.Delete ? UI.ChangedBrush : op.Replaces ? UI.MirrorBrush : UI.Accent;
        public string Action => op.ActionTitle;
        public string Direction => op.Dest == Side.Right ? "→ " + req.RightName : "← " + req.LeftName;
        public string Rel => op.Rel;
        public string Size => op.Kind == OpKind.Mkdir ? "" : Fmt.Size(op.Size);
        public string Tip => op.Target;
    }

    public PlanPreviewWindow(PlanRequest req) : base(req.Title, 960, 660)
    {
        var plan = req.Plan;
        var root = new DockPanel { Margin = new Thickness(18) };

        var top = new StackPanel();
        DockPanel.SetDock(top, Dock.Top);
        top.Children.Add(Label(req.Title, 20, true));
        if (req.Mode is { } m) top.Children.Add(Label(m.Detail(), 13, brush: UI.Secondary));
        var stats = new UniformGrid { Columns = 4, Margin = new Thickness(0, 8, 0, 8) };
        stats.Children.Add(Stat("", $"{req.LeftName} → {req.RightName}", plan.Copies(Side.Right).Count(), plan.Bytes(Side.Right), UI.Accent));
        stats.Children.Add(Stat("", $"{req.RightName} → {req.LeftName}", plan.Copies(Side.Left).Count(), plan.Bytes(Side.Left), UI.Accent));
        stats.Children.Add(Stat("", "Eliminazioni", plan.DeleteCount, null, plan.DeleteCount > 0 ? UI.ChangedBrush : UI.Secondary));
        stats.Children.Add(Stat("", "Nuove cartelle", plan.MkdirCount, null, UI.Secondary));
        top.Children.Add(stats);

        var warnings = new List<string>();
        foreach (var side in new[] { Side.Left, Side.Right })
        {
            var free = side == Side.Left ? req.FreeLeft : req.FreeRight;
            long need = plan.Bytes(side) - (req.DeleteMode == DeleteMode.Permanent ? plan.Ops.Where(o => o.Dest == side && o.Kind == OpKind.Delete).Sum(o => o.Size) : 0);
            if (free is { } f && need > 0 && need > f)
                warnings.Add($"Spazio insufficiente a {(side == Side.Left ? req.LeftName : req.RightName)}: servono {Fmt.Size(need)}, liberi {Fmt.Size(f)}.");
        }
        if (plan.DeleteCount > 0 && req.DeleteMode == DeleteMode.Permanent)
            warnings.Add($"Le {plan.DeleteCount} eliminazioni sono definitive: niente archivio né Cestino.");
        if (warnings.Count > 0)
            top.Children.Add(new Border
            {
                Background = UI.Tint(UI.ChangedBrush, 0.1), CornerRadius = new CornerRadius(8), Padding = new Thickness(10), Margin = new Thickness(0, 0, 0, 8),
                Child = Label(string.Join("\n", warnings), 13, brush: UI.ChangedBrush),
            });

        var rows = plan.Ops.Select(o => new OpRow(o, req)).ToList();
        var list = new ListView { ItemsSource = rows };
        VirtualizingPanel.SetIsVirtualizing(list, true);
        var filterBar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        void AddFilter(string text, string tip, Func<OpRow, bool> pred, bool first = false)
        {
            var rb = new RadioButton { Content = text, GroupName = "op", Style = (Style)Application.Current.FindResource("PillRadio"), ToolTip = tip, IsChecked = first };
            rb.Checked += (_, _) => list.ItemsSource = rows.Where(pred).ToList();
            filterBar.Children.Add(rb);
        }
        AddFilter($"Tutte  {Fmt.Number(rows.Count)}", "Mostra tutte le operazioni", _ => true, true);
        AddFilter("→ Destra", $"Solo le operazioni verso {req.RightName}", r => r.Op.Dest == Side.Right && r.Op.Kind != OpKind.Delete);
        AddFilter("← Sinistra", $"Solo le operazioni verso {req.LeftName}", r => r.Op.Dest == Side.Left && r.Op.Kind != OpKind.Delete);
        AddFilter("Eliminazioni", "Solo le eliminazioni", r => r.Op.Kind == OpKind.Delete);
        top.Children.Add(filterBar);
        root.Children.Add(top);

        var cancel = Btn("Annulla", "Chiudi senza modificare nulla (Esc)", () => { DialogResult = false; });
        cancel.IsCancel = true;
        var run = Btn($"Esegui {Fmt.Number(plan.Ops.Count)} operazioni", "Esegue tutte le operazioni elencate (Invio)", () => { DialogResult = true; }, true);
        if (plan.DeleteCount > 0) run.Background = UI.MirrorBrush;
        var bottom = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(bottom, Dock.Bottom);
        var btns = Buttons(cancel, run);
        DockPanel.SetDock(btns, Dock.Right);
        bottom.Children.Add(btns);
        var del = Label((req.DeleteMode == DeleteMode.Permanent ? "⚠ " : "") + "Eliminati e sovrascritti: " + req.DeleteMode.Title().ToLowerInvariant(), 12,
                        brush: req.DeleteMode == DeleteMode.Permanent ? UI.ChangedBrush : UI.Secondary);
        del.VerticalAlignment = VerticalAlignment.Center;
        del.ToolTip = req.DeleteMode.Detail();
        bottom.Children.Add(del);
        if (plan.Conflicts.Count > 0)
        {
            var conf = new Expander
            {
                Header = $"{plan.Conflicts.Count} conflitti saltati: diversi ma con la stessa data, o file contro cartella",
                Content = new TextBox { Text = string.Join(Environment.NewLine, plan.Conflicts), IsReadOnly = true, MaxHeight = 100, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
                Margin = new Thickness(0, 8, 0, 0),
                ToolTip = "Elementi che la modalità scelta non sa a quale lato dare: vanno decisi a mano",
            };
            DockPanel.SetDock(conf, Dock.Bottom);
            root.Children.Add(bottom);
            root.Children.Add(conf);
        }
        else root.Children.Add(bottom);

        var gv = new GridView();
        gv.Columns.Add(Col("", 34, "Glyph", true));
        gv.Columns.Add(Col("Azione", 120, "Action"));
        gv.Columns.Add(Col("Verso", 150, "Direction"));
        gv.Columns.Add(Col("Percorso", 470, "Rel"));
        gv.Columns.Add(Col("Dimensione", 100, "Size"));
        list.View = gv;
        root.Children.Add(list);
        Content = root;
    }

    static GridViewColumn Col(string header, double width, string path, bool glyph = false)
    {
        var f = new FrameworkElementFactory(typeof(TextBlock));
        f.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(path));
        f.SetBinding(ToolTipProperty, new System.Windows.Data.Binding("Tip"));
        if (glyph)
        {
            f.SetValue(TextBlock.FontFamilyProperty, Application.Current.FindResource("IconFont"));
            f.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding("Brush"));
        }
        if (path == "Action") f.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding("Brush"));
        f.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        return new GridViewColumn { Header = header, Width = width, CellTemplate = new DataTemplate { VisualTree = f } };
    }

    static Border Stat(string glyph, string title, int count, long? bytes, Brush color)
    {
        var sp = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(new TextBlock { Text = glyph, FontFamily = (FontFamily)Application.Current.FindResource("IconFont"), FontSize = 12, Margin = new Thickness(0, 0, 6, 0), Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(new TextBlock { Text = title, FontSize = 12, Foreground = UI.Secondary, TextTrimming = TextTrimming.CharacterEllipsis });
        sp.Children.Add(head);
        sp.Children.Add(new TextBlock { Text = Fmt.Number(count), FontSize = 24, FontWeight = FontWeights.SemiBold, Foreground = count > 0 ? color : UI.Secondary });
        sp.Children.Add(new TextBlock { Text = bytes is { } b ? Fmt.Size(b) : " ", FontSize = 12, Foreground = UI.Secondary });
        return new Border { Style = (Style)Application.Current.FindResource("Card"), Margin = new Thickness(0, 0, 8, 0), Child = sp };
    }
}

// ===================== Editor del profilo =====================

public sealed class ProfileEditorWindow : DialogBase
{
    public SyncProfile Profile { get; }

    public ProfileEditorWindow(SyncProfile p) : base(AppState.Instance.Profile(p.Id) == null ? "Nuovo profilo di sincronizzazione" : "Modifica profilo", 700, 800)
    {
        Profile = p.Clone();
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(Label(Title, 18, true));

        panel.Children.Add(Label("Nome", 12, true, UI.Secondary));
        var name = new TextBox { Text = Profile.Name, Margin = new Thickness(0, 0, 0, 10), ToolTip = "Nome del profilo, come compare nella barra laterale" };
        panel.Children.Add(name);

        (TextBox Path, TextBox Server) SideFields(string title, string path, string server)
        {
            panel.Children.Add(Label(title, 14, true));
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
            var choose = new Button { Content = "Scegli…", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0), ToolTip = "Scegli la cartella" };
            DockPanel.SetDock(choose, Dock.Right);
            var tb = new TextBox { Text = path, ToolTip = "Percorso della cartella: unità locale, unità di rete o percorso \\\\server\\condivisione" };
            row.Children.Add(choose);
            row.Children.Add(tb);
            panel.Children.Add(row);
            var srow = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
            var connect = new Button { Content = "Connetti…", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0), ToolTip = "Collega la condivisione e scegli la cartella al suo interno" };
            DockPanel.SetDock(connect, Dock.Right);
            var sb = new TextBox { Text = server, ToolTip = "Condivisione da collegare in automatico se la cartella non è raggiungibile (facoltativo), es. \\\\DS920\\Foto" };
            srow.Children.Add(connect);
            srow.Children.Add(sb);
            panel.Children.Add(Label("Condivisione di rete da collegare (facoltativo)", 11, brush: UI.Secondary));
            panel.Children.Add(srow);
            choose.Click += (_, _) =>
            {
                if (UI.PickFolder(tb.Text) is { } f)
                {
                    tb.Text = f;
                    if (NasConnect.ShareRoot(f) is { } share) sb.Text = share;
                    AutoName(name, panel);
                }
            };
            connect.Click += (_, _) =>
            {
                try
                {
                    if (sb.Text.Trim().Length == 0) { UI.Info("Connetti", "Scrivi prima l'indirizzo della condivisione, ad esempio \\\\DS920\\Foto."); return; }
                    NasConnect.Connect(sb.Text, UI.Handle(this));
                    AppState.Instance.AddRecentServer(sb.Text);
                    if (UI.PickFolder(NasConnect.ShareRoot(NasConnect.ToUnc(sb.Text)) ?? NasConnect.ToUnc(sb.Text)) is { } f) tb.Text = f;
                }
                catch (OperationCanceledException) { }
                catch (Exception ex) { UI.Info("Connessione non riuscita", ex.Message); }
            };
            return (tb, sb);
        }

        var left = SideFields("Sinistra", Profile.Left, Profile.LeftServer);
        var right = SideFields("Destra", Profile.Right, Profile.RightServer);
        leftBox = left.Path;
        rightBox = right.Path;

        panel.Children.Add(Label("Sincronizzazione", 14, true));
        var mode = Combo(Enum.GetValues<SyncMode>(), Profile.Mode, m => m.Title(), "In che direzione copiare e se eliminare gli elementi in più");
        var modeDetail = Label(Profile.Mode.Detail(), 12, brush: UI.Secondary);
        mode.SelectionChanged += (_, _) => modeDetail.Text = Selected<SyncMode>(mode).Detail();
        panel.Children.Add(mode);
        panel.Children.Add(modeDetail);
        var del = Combo(Enum.GetValues<DeleteMode>(), Profile.DeleteMode, d => d.Title(), "Dove finiscono i file eliminati o sostituiti dalla sincronizzazione");
        var delDetail = Label(Profile.DeleteMode.Detail(), 12, brush: UI.Secondary);
        del.SelectionChanged += (_, _) => delDetail.Text = Selected<DeleteMode>(del).Detail();
        panel.Children.Add(Label("Eliminati e sovrascritti", 12, true, UI.Secondary));
        panel.Children.Add(del);
        panel.Children.Add(delDetail);

        panel.Children.Add(Label("Confronto", 14, true));
        var method = Combo(Enum.GetValues<CompareMethod>(), Profile.Options.Method, m => m.Title(), "Come decidere se due file sono uguali: dimensione e data è il più veloce");
        panel.Children.Add(method);
        var hour = Check("Ignora differenze di un'ora esatta (ora legale, fuso del NAS)", Profile.Options.IgnoreHourShift, "Considera uguali due file che differiscono di un'ora esatta");
        var cases = Check("Abbina i nomi ignorando maiuscole e minuscole", Profile.Options.CaseInsensitive, "«Foto» e «foto» sono lo stesso elemento (normale su Windows)");
        var hidden = Check("Includi i file nascosti e di sistema", Profile.Options.IncludeHidden, "Confronta anche i file nascosti, di sistema e quelli il cui nome inizia con un punto");
        panel.Children.Add(hour);
        panel.Children.Add(cases);
        panel.Children.Add(hidden);
        panel.Children.Add(Label("Escludi", 12, true, UI.Secondary));
        var excl = new TextBox { Text = Profile.Options.Excludes, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, MinHeight = 50, ToolTip = "Nomi o modelli da ignorare, separati da virgola (es. *.tmp, node_modules). Con «\\» il modello vale sul percorso" };
        panel.Children.Add(excl);

        var cancel = Btn("Annulla", "Chiudi senza salvare (Esc)", () => DialogResult = false);
        cancel.IsCancel = true;
        var save = Btn("Salva", "Salva il profilo e aprilo (Invio)", () =>
        {
            if (name.Text.Trim().Length == 0 || leftBox.Text.Trim().Length == 0 || rightBox.Text.Trim().Length == 0)
            {
                UI.Info("Profilo incompleto", "Servono un nome e le due cartelle.");
                return;
            }
            Profile.Name = name.Text.Trim();
            Profile.Left = leftBox.Text.Trim();
            Profile.Right = rightBox.Text.Trim();
            Profile.LeftServer = left.Server.Text.Trim();
            Profile.RightServer = right.Server.Text.Trim();
            Profile.Mode = Selected<SyncMode>(mode);
            Profile.DeleteMode = Selected<DeleteMode>(del);
            Profile.Options.Method = Selected<CompareMethod>(method);
            Profile.Options.IgnoreHourShift = hour.IsChecked == true;
            Profile.Options.CaseInsensitive = cases.IsChecked == true;
            Profile.Options.IncludeHidden = hidden.IsChecked == true;
            Profile.Options.Excludes = excl.Text;
            DialogResult = true;
        }, true);
        panel.Children.Add(Buttons(cancel, save));
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    readonly TextBox leftBox, rightBox;

    void AutoName(TextBox name, StackPanel _)
    {
        if (leftBox == null || rightBox == null) return;
        var n = name.Text;
        if (n != "Nuovo profilo" && n.Length > 0 && !n.Contains('→') && !n.Contains('↔')) return;
        var l = Path.GetFileName(leftBox.Text.TrimEnd('\\'));
        var r = Path.GetFileName(rightBox.Text.TrimEnd('\\'));
        name.Text = l.Length == 0 || r.Length == 0 ? (l.Length > 0 ? l : r) : $"{l} → {r}";
    }
}

// ===================== Connessione al server =====================

public sealed class ConnectWindow : DialogBase
{
    public string? ConnectedRoot { get; private set; }

    public ConnectWindow() : base("Connetti al server", 540, 420)
    {
        var app = AppState.Instance;
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(Label("Connetti al server", 18, true));
        panel.Children.Add(Label("Indirizzo della condivisione, ad esempio \\\\DS920\\Foto oppure smb://DS920/Foto. Se servono credenziali le chiede Windows, che può memorizzarle.", 13, brush: UI.Secondary));
        var address = new TextBox { Text = app.Settings.RecentServers.FirstOrDefault() ?? @"\\", Margin = new Thickness(0, 8, 0, 8), ToolTip = "Indirizzo \\\\server\\condivisione" };
        panel.Children.Add(address);
        var remember = Check("Ricollega all'accesso a Windows", false, "Salva il collegamento nel profilo utente di Windows");
        panel.Children.Add(remember);
        if (app.Settings.RecentServers.Count > 0)
        {
            panel.Children.Add(Label("Recenti", 12, true, UI.Secondary));
            foreach (var s in app.Settings.RecentServers)
            {
                var link = new Button { Content = s, Background = Brushes.Transparent, BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left, Foreground = UI.Accent, ToolTip = "Usa questo indirizzo", Cursor = Cursors.Hand, Padding = new Thickness(0, 2, 0, 2) };
                link.Click += (_, _) => address.Text = s;
                panel.Children.Add(link);
            }
        }
        var message = Label("", 13);
        panel.Children.Add(message);
        var close = Btn("Chiudi", "Chiudi questa finestra (Esc)", () => DialogResult = ConnectedRoot != null);
        close.IsCancel = true;
        var connect = Btn("Connetti", "Collega la condivisione; se servono, Windows chiede le credenziali (Invio)", async () =>
        {
            message.Text = "Connessione…";
            message.Foreground = UI.Secondary;
            var addr = address.Text.Trim();
            var owner = UI.Handle(this);
            try
            {
                await Task.Run(() => NasConnect.Connect(addr, owner, remember.IsChecked == true));
                ConnectedRoot = NasConnect.ShareRoot(NasConnect.ToUnc(addr)) ?? NasConnect.ToUnc(addr);
                app.AddRecentServer(addr);
                message.Text = "Collegato: " + ConnectedRoot;
                message.Foreground = UI.SameBrush;
            }
            catch (OperationCanceledException) { message.Text = "Connessione annullata"; }
            catch (Exception ex) { message.Text = ex.Message; message.Foreground = UI.ChangedBrush; }
        }, true);
        panel.Children.Add(Buttons(close, connect));
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}

// ===================== Opzioni =====================

public sealed class OptionsWindow : DialogBase
{
    public OptionsWindow(FolderSession s) : base("Opzioni", 560, 640)
    {
        var o = s.Options.Clone();
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(Label("Aspetto", 15, true));
        var themes = new[] { ("Dark", "Scuro"), ("Light", "Chiaro"), ("System", "Come Windows") };
        var theme = Combo(themes, themes.FirstOrDefault(t => t.Item1 == AppState.Instance.Settings.Theme, themes[0]), t => t.Item2,
                          "Tema dell'app: scuro, chiaro o uguale all'impostazione di Windows. Si applica subito");
        theme.SelectionChanged += (_, _) =>
        {
            var t = Selected<(string, string)>(theme).Item1;
            AppState.Instance.Settings.Theme = t;
            AppState.Instance.SaveSettings();
            App.ApplyTheme(t);
        };
        panel.Children.Add(theme);
        panel.Children.Add(Label("Confronto", 15, true));
        var method = Combo(Enum.GetValues<CompareMethod>(), o.Method, m => m.Title(), "Come decidere se due file sono uguali: dimensione e data è il più veloce");
        panel.Children.Add(method);
        panel.Children.Add(Label("Tolleranza sulle date (secondi)", 12, brush: UI.Secondary));
        var tol = new Slider { Minimum = 0, Maximum = 10, Value = o.TimeTolerance, TickFrequency = 1, IsSnapToTickEnabled = true, Width = 260, HorizontalAlignment = HorizontalAlignment.Left,
                               ToolTip = "Differenza massima di orario per considerare uguali due date (FAT ed exFAT arrotondano a 2 s)", AutoToolTipPlacement = AutoToolTipPlacement.TopLeft };
        panel.Children.Add(tol);
        var hour = Check("Ignora differenze di un'ora esatta (ora legale, fuso del NAS)", o.IgnoreHourShift, "Considera uguali due file che differiscono di un'ora esatta");
        var cases = Check("Abbina i nomi ignorando maiuscole e minuscole", o.CaseInsensitive, "«Foto» e «foto» sono lo stesso elemento: normale su Windows");
        var hidden = Check("Includi i file nascosti e di sistema", o.IncludeHidden, "Confronta anche i file nascosti, di sistema e quelli il cui nome inizia con un punto");
        panel.Children.Add(hour);
        panel.Children.Add(cases);
        panel.Children.Add(hidden);
        panel.Children.Add(Label("Esclusioni", 15, true));
        var excl = new TextBox { Text = o.Excludes, TextWrapping = TextWrapping.Wrap, MinHeight = 60, ToolTip = "Nomi o modelli da ignorare, separati da virgola. Con «\\» il modello vale sul percorso" };
        panel.Children.Add(excl);
        var reset = new Button { Content = "Predefinite", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 10), Padding = new Thickness(12, 3, 12, 3),
                                 ToolTip = "Ripristina le esclusioni predefinite (file di sistema di Windows, del Mac e del Synology)" };
        reset.Click += (_, _) => excl.Text = DirOptions.DefaultExcludes;
        panel.Children.Add(reset);
        panel.Children.Add(Label("Sincronizzazione", 15, true));
        var del = Combo(Enum.GetValues<DeleteMode>(), s.DeleteMode, d => d.Title(), "Dove finiscono i file eliminati o sostituiti dalla sincronizzazione");
        var delDetail = Label(s.DeleteMode.Detail(), 12, brush: UI.Secondary);
        del.SelectionChanged += (_, _) => delDetail.Text = Selected<DeleteMode>(del).Detail();
        panel.Children.Add(del);
        panel.Children.Add(delDetail);
        var parLabel = Label($"Copie in parallelo: {o.ParallelCopies}", 12, brush: UI.Secondary);
        var par = new Slider { Minimum = 1, Maximum = 12, Value = o.ParallelCopies, TickFrequency = 1, IsSnapToTickEnabled = true, Width = 260, HorizontalAlignment = HorizontalAlignment.Left,
                               ToolTip = "Quanti file copiare contemporaneamente: valori più alti aiutano con molti file piccoli sul NAS" };
        par.ValueChanged += (_, _) => parLabel.Text = $"Copie in parallelo: {(int)par.Value}";
        panel.Children.Add(parLabel);
        panel.Children.Add(par);

        var cancel = Btn("Annulla", "Chiudi senza applicare (Esc)", () => DialogResult = false);
        cancel.IsCancel = true;
        var apply = Btn("Applica", "Applica le opzioni; se cambiano il confronto, le cartelle vengono rianalizzate (Invio)", () =>
        {
            o.Method = Selected<CompareMethod>(method);
            o.TimeTolerance = tol.Value;
            o.IgnoreHourShift = hour.IsChecked == true;
            o.CaseInsensitive = cases.IsChecked == true;
            o.IncludeHidden = hidden.IsChecked == true;
            o.Excludes = excl.Text;
            o.ParallelCopies = (int)par.Value;
            s.DeleteMode = Selected<DeleteMode>(del);
            s.SetOptions(o);
            DialogResult = true;
        }, true);
        panel.Children.Add(Buttons(cancel, apply));
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}

// ===================== Sincronizza tutti =====================

public sealed class SyncAllWindow : DialogBase
{
    sealed class Item
    {
        public required SyncProfile Profile;
        public CheckBox Box = null!;
        public TextBlock State = null!;
        public SyncPlan? Plan;
    }

    readonly List<Item> items = [];
    readonly Button runButton;
    bool started;

    public SyncAllWindow() : base("Sincronizza tutti", 720, 520)
    {
        var root = new DockPanel { Margin = new Thickness(20) };
        var top = new StackPanel();
        DockPanel.SetDock(top, Dock.Top);
        top.Children.Add(Label("Sincronizza tutti", 18, true));
        top.Children.Add(Label("Ogni profilo viene analizzato con la sua modalità. Scegli quali eseguire: girano in parallelo.", 13, brush: UI.Secondary));
        root.Children.Add(top);

        var close = Btn("Chiudi", "Chiudi: le sincronizzazioni avviate continuano (Esc)", () => Close());
        close.IsCancel = true;
        runButton = Btn("Esegui selezionati", "Esegue in parallelo i profili selezionati, dopo una conferma", RunChosen, true);
        runButton.IsEnabled = false;
        var btns = Buttons(close, runButton);
        DockPanel.SetDock(btns, Dock.Bottom);
        root.Children.Add(btns);

        var list = new StackPanel();
        foreach (var p in AppState.Instance.Profiles.Where(p => p.IsComplete))
        {
            var it = new Item { Profile = p };
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            it.Box = new CheckBox { IsEnabled = false, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Includi questo profilo nell'esecuzione" };
            it.Box.Checked += (_, _) => UpdateButton();
            it.Box.Unchecked += (_, _) => UpdateButton();
            DockPanel.SetDock(it.Box, Dock.Left);
            row.Children.Add(it.Box);
            it.State = new TextBlock { Text = "In attesa", FontSize = 12, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap, MaxWidth = 300, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(it.State, Dock.Right);
            row.Children.Add(it.State);
            var sp = new StackPanel { Margin = new Thickness(8, 0, 8, 0) };
            sp.Children.Add(new TextBlock { Text = p.Name, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = p.Mode.Title(), FontSize = 12, Foreground = UI.Secondary });
            row.Children.Add(sp);
            list.Children.Add(new Border { Style = (Style)Application.Current.FindResource("Card"), Margin = new Thickness(0, 0, 0, 6), Padding = new Thickness(10), Child = row });
            items.Add(it);
        }
        root.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
        Loaded += async (_, _) => await AnalyzeAll();
    }

    void UpdateButton()
    {
        int n = items.Count(i => i.Box.IsChecked == true);
        runButton.Content = $"Esegui {n} sincronizzazioni";
        runButton.IsEnabled = n > 0 && !started;
    }

    async Task AnalyzeAll()
    {
        await Task.WhenAll(items.Select(async it =>
        {
            it.State.Text = "Analisi…";
            var s = AppState.Instance.OpenProfile(it.Profile.Id);
            if (s == null) return;
            var (plan, error) = await s.AnalyzeForBatchAsync();
            if (plan == null)
            {
                it.State.Text = error ?? "Errore";
                it.State.Foreground = UI.ChangedBrush;
                return;
            }
            it.Plan = plan;
            it.State.Text = plan.Summary;
            it.State.Foreground = plan.IsEmpty ? UI.SameBrush : UI.MirrorBrush;
            it.Box.IsEnabled = !plan.IsEmpty;
            it.Box.IsChecked = !plan.IsEmpty;
        }));
        UpdateButton();
    }

    void RunChosen()
    {
        var chosen = items.Where(i => i.Box.IsChecked == true && i.Plan != null).ToList();
        var lines = string.Join("\n", chosen.Select(i => $"• {i.Profile.Name} — {i.Profile.Mode.Title()}: {i.Plan!.Summary}"));
        if (!UI.Confirm($"Eseguire {chosen.Count} sincronizzazioni in parallelo?", lines, "Esegui")) return;
        started = true;
        foreach (var it in chosen)
        {
            AppState.Instance.Existing(it.Profile.Id)?.Run(it.Plan!);
            it.State.Text = "Avviata";
            it.State.Foreground = UI.Accent;
            it.Box.IsEnabled = false;
        }
        UpdateButton();
    }
}
