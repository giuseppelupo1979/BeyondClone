using System.Windows;
using System.Windows.Controls;

namespace BeyondClone;

public partial class App : Application
{
    /// <summary>Applica l'aspetto: "Dark", "Light" o "System" (segue Windows).</summary>
    public static void ApplyTheme(string theme)
    {
        Current.ThemeMode = theme switch
        {
            "Light" => ThemeMode.Light,
            "System" => ThemeMode.System,
            _ => ThemeMode.Dark,
        };
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        // Descrizioni al passaggio del mouse: compaiono dopo mezzo secondo e anche sui controlli disattivati.
        ToolTipService.InitialShowDelayProperty.OverrideMetadata(typeof(FrameworkElement), new FrameworkPropertyMetadata(500));
        ToolTipService.ShowDurationProperty.OverrideMetadata(typeof(FrameworkElement), new FrameworkPropertyMetadata(20000));
        ToolTipService.ShowOnDisabledProperty.OverrideMetadata(typeof(FrameworkElement), new FrameworkPropertyMetadata(true));

        DispatcherUnhandledException += (_, ex) =>
        {
            MessageBox.Show(ex.Exception.Message, "BeyondClone: errore imprevisto", MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
        };

        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
        base.OnStartup(e);
        ApplyTheme(AppState.Instance.Settings.Theme);
        string? left = null, right = null;
        for (int i = 0; i < e.Args.Length - 1; i++)
        {
            if (e.Args[i] == "--left") left = e.Args[i + 1];
            if (e.Args[i] == "--right") right = e.Args[i + 1];
            // --files A B: apre direttamente il confronto del contenuto di due file.
            if (e.Args[i] == "--files" && i + 2 < e.Args.Length)
            {
                var fw = FileKindDetector.Open(e.Args[i + 1], e.Args[i + 2]);
                fw.WindowStartupLocation = WindowStartupLocation.CenterScreen;
                MainWindow = fw;
                fw.Show();
                return;
            }
        }
        var w = new MainWindow(left, right);
        MainWindow = w;
        w.Show();
    }
}
