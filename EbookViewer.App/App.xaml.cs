using Microsoft.UI.Xaml;

namespace EbookViewer.App;

public partial class App : Application
{
    private MainWindow? _window;

    public static string DataDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EbookViewer");

    public App()
    {
        Directory.CreateDirectory(DataDirectory);
        // WebView2 のユーザーデータは exe の隣ではなく LocalAppData に置く (Program Files 配下でも動くように)
        Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", Path.Combine(DataDirectory, "WebView2"));
        // 本文配信用の仮想ホストを DNS に問い合わせず即座に解決させる (応答自体は WebResourceRequested で差し替える)
        Environment.SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
            "--host-resolver-rules=" + '"' + "MAP book.ebookviewer.invalid 127.0.0.1" + '"');
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();

        string? file = Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(File.Exists);
        if (file != null)
        {
            _window.RequestOpen(file);
        }
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        try
        {
            File.AppendAllText(Path.Combine(DataDirectory, "error.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {e.Exception}\n\n");
        }
        catch
        {
            // ログ書き込み失敗は無視
        }
    }
}
