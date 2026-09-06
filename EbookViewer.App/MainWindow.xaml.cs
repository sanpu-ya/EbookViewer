using System.Text;
using System.Text.Json;
using EbookViewer.App.Services;
using EbookViewer.Core;
using EbookViewer.Core.Model;
using EbookViewer.Core.Rendering;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace EbookViewer.App;

/// <summary>目次リストの 1 行。</summary>
public sealed class TocItem
{
    public TocItem(TocEntry entry, int depth)
    {
        Entry = entry;
        Title = string.IsNullOrWhiteSpace(entry.Title) ? "(無題)" : entry.Title;
        Margin = new Thickness(depth * 16, 4, 0, 4);
    }

    public TocEntry Entry { get; }
    public string Title { get; }
    public Thickness Margin { get; }
}

public sealed partial class MainWindow : Window
{
    /// <summary>
    /// 本文を配信する仮想ホスト名。".local" は mDNS 解決の待ち時間 (約 2 秒) がナビゲーションごとに発生するので使わない。
    /// </summary>
    private const string HostName = "book.ebookviewer.invalid";
    private const string BaseUrl = "https://" + HostName + "/";

    private readonly ReaderSettings _settings;
    private readonly ReadingPositionStore _positions;
    private readonly DispatcherQueueTimer _saveTimer;
    private readonly DispatcherQueueTimer _readyFallbackTimer;

    private BookDocument? _book;
    private string? _bookPath;
    private int _spineIndex = -1;
    private int _page;
    private int _pages = 1;
    private string _pendingInitial = "{\"type\":\"page\",\"page\":0}";
    private bool _webReady;
    private string? _pendingOpen;
    private bool _loading;

    public MainWindow()
    {
        InitializeComponent();
        _settings = ReaderSettings.Load();
        _positions = ReadingPositionStore.Load();

        _saveTimer = DispatcherQueue.CreateTimer();
        _saveTimer.Interval = TimeSpan.FromSeconds(1);
        _saveTimer.IsRepeating = false;
        _saveTimer.Tick += (_, _) => SavePosition();

        _readyFallbackTimer = DispatcherQueue.CreateTimer();
        _readyFallbackTimer.Interval = TimeSpan.FromSeconds(4);
        _readyFallbackTimer.IsRepeating = false;
        _readyFallbackTimer.Tick += (_, _) => HideLoading();

        if (_settings.WindowWidth >= 400 && _settings.WindowHeight >= 300)
        {
            AppWindow.Resize(new Windows.Graphics.SizeInt32((int)_settings.WindowWidth, (int)_settings.WindowHeight));
        }
        else
        {
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 820));
        }

        // JIS/US 配列の "-" "=" キー (VK_OEM_MINUS / VK_OEM_PLUS) は XAML で指定できないのでここで登録する
        FontDownButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = (Windows.System.VirtualKey)189, Modifiers = Windows.System.VirtualKeyModifiers.Control });
        FontUpButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = (Windows.System.VirtualKey)187, Modifiers = Windows.System.VirtualKeyModifiers.Control });

        // WebView 以外 (ツールバーなど) にフォーカスがあるときもページ送りキーが効くようにする
        foreach (var (key, forward) in new[] {
            (Windows.System.VirtualKey.PageDown, true), (Windows.System.VirtualKey.PageUp, false),
            (Windows.System.VirtualKey.Space, true), (Windows.System.VirtualKey.Left, true), (Windows.System.VirtualKey.Right, false),
            (Windows.System.VirtualKey.Down, true), (Windows.System.VirtualKey.Up, false) })
        {
            var accel = new KeyboardAccelerator { Key = key };
            bool fwd = forward;
            var k = key;
            accel.Invoked += (_, args) => OnPagingAccelerator(k, fwd, args);
            Root.KeyboardAccelerators.Add(accel);
        }

        Split.IsPaneOpen = _settings.TocOpen;
        TocToggle.IsChecked = _settings.TocOpen;
        ApplySettingsToMenu();
        UpdateWritingModeLabel();
        UpdateStatus();

        Closed += MainWindow_Closed;
        _ = InitializeWebViewAsync();
    }

    // ------------------------------------------------------------------
    // WebView2 初期化と仮想ホスト
    // ------------------------------------------------------------------

    private async Task InitializeWebViewAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("WebView2 の初期化に失敗しました。Microsoft Edge WebView2 ランタイムがインストールされているか確認してください。\n\n" + ex.Message);
            return;
        }

        var core = Web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.IsPinchZoomEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.AreDevToolsEnabled = true;

        core.AddWebResourceRequestedFilter(BaseUrl + "*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += Core_WebResourceRequested;
        core.WebMessageReceived += Core_WebMessageReceived;
        core.NavigationStarting += Core_NavigationStarting;
        core.NavigationCompleted += Core_NavigationCompleted;
        core.NewWindowRequested += Core_NewWindowRequested;
        if (TraceEnabled)
        {
            core.ContentLoading += (_, a) => Trace($"ContentLoading nav={a.NavigationId}");
            core.DOMContentLoaded += (_, a) => Trace($"DOMContentLoaded nav={a.NavigationId}");
            core.NavigationStarting += (_, a) => Trace($"NavigationStarting {a.Uri}");
        }

        _webReady = true;
        if (_pendingOpen != null)
        {
            string p = _pendingOpen;
            _pendingOpen = null;
            await OpenFileAsync(p);
        }
    }

    private void Core_WebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        Trace($"WebResourceRequested {e.ResourceContext} {e.Request.Uri}");
        byte[]? data = null;
        string contentType = "application/octet-stream";
        int status = 200;
        try
        {
            var uri = new Uri(e.Request.Uri);
            string path = PathUtil.Normalize(uri.AbsolutePath);
            if (path.StartsWith(ContentPreparer.AssetPrefix, StringComparison.Ordinal))
            {
                string name = path[ContentPreparer.AssetPrefix.Length..];
                data = ContentPreparer.GetAsset(name);
                contentType = ContentPreparer.AssetMediaType(name);
            }
            else if (_book != null)
            {
                var res = _book.FindResource(path);
                if (res != null)
                {
                    if (PathUtil.IsHtmlMediaType(res.MediaType))
                    {
                        (data, contentType) = ContentPreparer.Prepare(res.GetData(), res.MediaType, BuildViewerOptions());
                    }
                    else
                    {
                        data = res.GetData();
                        contentType = res.MediaType;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            data = Encoding.UTF8.GetBytes("<html><body><pre>" + System.Net.WebUtility.HtmlEncode(ex.ToString()) + "</pre></body></html>");
            contentType = "text/html; charset=utf-8";
            status = 500;
        }

        if (data == null)
        {
            e.Response = sender.Environment.CreateWebResourceResponse(null, 404, "Not Found", "Content-Type: text/plain");
            return;
        }
        var stream = new MemoryStream(data).AsRandomAccessStream();
        e.Response = sender.Environment.CreateWebResourceResponse(stream, status, status == 200 ? "OK" : "Error",
            "Content-Type: " + contentType + "\nCache-Control: no-store\nAccess-Control-Allow-Origin: *");
    }

    private void Core_NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (e.Uri.StartsWith(BaseUrl, StringComparison.OrdinalIgnoreCase) || e.Uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
            return;
        e.Cancel = true;
        if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri))
        {
            if (uri.IsFile && BookLoader.IsSupported(uri.LocalPath))
            {
                // WebView 上にファイルをドロップすると file:// へ遷移しようとするので、代わりに本として開く
                _ = OpenFileAsync(uri.LocalPath);
            }
            else if (uri.Scheme is "http" or "https" or "mailto")
            {
                _ = Windows.System.Launcher.LaunchUriAsync(uri);
            }
        }
    }

    private void Core_NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess)
        {
            // 連続ページ送りで前のナビゲーションが中断されたときは次のナビゲーションが続いているので無視する
            if (e.WebErrorStatus == CoreWebView2WebErrorStatus.ConnectionAborted) return;
            HideLoading();
            StatusRight.Text = "表示エラー: " + e.WebErrorStatus;
        }
        else
        {
            _readyFallbackTimer.Start();
        }
        Trace($"NavigationCompleted success={e.IsSuccess} status={e.WebErrorStatus} spine={_spineIndex}");
        FocusWeb();
    }

    private void Core_NewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true;
        if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
            _ = Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private void Core_WebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(e.WebMessageAsJson);
        }
        catch (JsonException)
        {
            return;
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;
            string type = root.TryGetProperty("type", out var t) ? t.GetString() ?? string.Empty : string.Empty;
            switch (type)
            {
                case "ready":
                    Trace($"ready spine={_spineIndex} {e.WebMessageAsJson}");
                    _page = root.TryGetProperty("page", out var rp) ? rp.GetInt32() : 0;
                    _pages = root.TryGetProperty("pages", out var rps) ? Math.Max(1, rps.GetInt32()) : 1;
                    _readyFallbackTimer.Stop();
                    HideLoading();
                    UpdateStatus();
                    ScheduleSave();
                    break;
                case "page":
                    _page = root.TryGetProperty("page", out var pp) ? pp.GetInt32() : 0;
                    _pages = root.TryGetProperty("pages", out var pps) ? Math.Max(1, pps.GetInt32()) : 1;
                    UpdateStatus();
                    ScheduleSave();
                    break;
                case "next-chapter":
                    Trace($"next-chapter from spine={_spineIndex}");
                    _ = GoToSpineAsync(_spineIndex + 1, "{\"type\":\"page\",\"page\":0}", wrapMessage: "最後のページです");
                    break;
                case "prev-chapter":
                    _ = GoToSpineAsync(_spineIndex - 1, "{\"type\":\"end\"}", wrapMessage: "最初のページです");
                    break;
                case "link":
                    if (root.TryGetProperty("href", out var href)) _ = FollowLinkAsync(href.GetString() ?? string.Empty);
                    break;
                case "key":
                    HandleWebKey(root.TryGetProperty("key", out var k) ? k.GetString() ?? string.Empty : string.Empty,
                        root.TryGetProperty("ctrl", out var c) && c.ValueKind == JsonValueKind.True);
                    break;
            }
        }
    }

    private void OnPagingAccelerator(Windows.System.VirtualKey key, bool forwardInVertical, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_book == null) return;
        // 目次リストやメニューにフォーカスがあるときは矢印キーをそちらに渡す
        var focused = FocusManager.GetFocusedElement(Root.XamlRoot);
        if (focused is ListViewItem or ListView or MenuFlyoutItem or TextBox) return;
        bool isArrow = key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down;
        if (isArrow && focused is AppBarButton or AppBarToggleButton) return;
        args.Handled = true;
        bool vertical = IsVerticalEffective();
        bool forward = key switch
        {
            Windows.System.VirtualKey.Left => vertical,
            Windows.System.VirtualKey.Right => !vertical,
            _ => forwardInVertical,
        };
        _ = Web.CoreWebView2?.ExecuteScriptAsync(forward ? "window.__ev && window.__ev.next()" : "window.__ev && window.__ev.prev()");
    }

    private void HandleWebKey(string key, bool ctrl)
    {
        if (ctrl)
        {
            switch (key)
            {
                case "t":
                case "T":
                    SetTocOpen(!Split.IsPaneOpen);
                    break;
                case "o":
                case "O":
                    OpenButton_Click(this, new RoutedEventArgs());
                    break;
                case "+":
                case "=":
                case ";":
                case "Add":
                    FontUpButton_Click(this, new RoutedEventArgs());
                    break;
                case "-":
                case "Subtract":
                    FontDownButton_Click(this, new RoutedEventArgs());
                    break;
            }
            return;
        }
        switch (key)
        {
            case "Escape":
                if (Split.IsPaneOpen) SetTocOpen(false);
                break;
            case "t":
            case "T":
                SetTocOpen(!Split.IsPaneOpen);
                break;
        }
    }

    // ------------------------------------------------------------------
    // ファイルを開く
    // ------------------------------------------------------------------

    /// <summary>WebView の準備ができていなければ準備後に開く。</summary>
    public void RequestOpen(string path)
    {
        if (_webReady) _ = OpenFileAsync(path);
        else _pendingOpen = path;
    }

    public async Task OpenFileAsync(string path)
    {
        if (_loading) return;
        if (!_webReady)
        {
            _pendingOpen = path;
            return;
        }
        _loading = true;
        ShowLoading("読み込み中… " + Path.GetFileName(path));
        try
        {
            SavePosition();
            var book = await BookLoader.LoadAsync(path);
            _book?.Dispose();
            _book = book;
            _bookPath = path;
            _settings.AddRecent(path);
            _settings.Save();

            Title = string.IsNullOrWhiteSpace(book.Metadata.Title) ? Path.GetFileName(path) + " - EbookViewer" : book.Metadata.Title + " - EbookViewer";
            PaneTitle.Text = string.IsNullOrWhiteSpace(book.Metadata.Title) ? Path.GetFileName(path) : book.Metadata.Title;
            PaneAuthor.Text = book.Metadata.Author;
            BuildTocList(book);
            EmptyState.Visibility = Visibility.Collapsed;
            Web.Visibility = Visibility.Visible;

            var pos = _positions.Get(path);
            int spine = pos != null && pos.SpineIndex >= 0 && pos.SpineIndex < book.Spine.Count ? pos.SpineIndex : FirstLinearSpine(book);
            string initial = pos != null ? "{\"type\":\"fraction\",\"value\":" + pos.Fraction.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}" : "{\"type\":\"page\",\"page\":0}";
            _loading = false;
            await GoToSpineAsync(spine, initial);
        }
        catch (Exception ex)
        {
            _loading = false;
            HideLoading();
            string message = ex is UnsupportedBookException ? ex.Message : "ファイルを開けませんでした。\n\n" + ex.Message;
            await ShowErrorAsync(message);
        }
    }

    private static int FirstLinearSpine(BookDocument book)
    {
        for (int i = 0; i < book.Spine.Count; i++)
        {
            if (book.Spine[i].Linear) return i;
        }
        return 0;
    }

    private async Task GoToSpineAsync(int index, string initialJson, string? wrapMessage = null)
    {
        if (_book == null) return;
        if (index < 0 || index >= _book.Spine.Count)
        {
            if (wrapMessage != null) StatusRight.Text = wrapMessage;
            return;
        }
        _spineIndex = index;
        _pendingInitial = initialJson;
        _page = 0;
        _pages = 1;
        ShowLoading("表示中…");
        UpdateStatus();
        string url = BaseUrl + string.Join('/', _book.Spine[index].Path.Split('/').Select(Uri.EscapeDataString));
        Trace($"Navigate spine={index} url={url} initial={initialJson}");
        if (Web.CoreWebView2.Source == url)
        {
            Web.CoreWebView2.Reload();
        }
        else
        {
            Web.CoreWebView2.Navigate(url);
        }
        await Task.CompletedTask;
    }

    private async Task ReloadCurrentAsync()
    {
        if (_book == null || _spineIndex < 0) return;
        double fraction = _pages > 1 ? (double)_page / (_pages - 1) : 0;
        await GoToSpineAsync(_spineIndex, "{\"type\":\"fraction\",\"value\":" + fraction.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
    }

    private async Task FollowLinkAsync(string href)
    {
        if (_book == null || string.IsNullOrEmpty(href)) return;
        if (!Uri.TryCreate(href, UriKind.Absolute, out var uri)) return;
        if (!string.Equals(uri.Host, HostName, StringComparison.OrdinalIgnoreCase))
        {
            if (uri.Scheme is "http" or "https") await Windows.System.Launcher.LaunchUriAsync(uri);
            return;
        }
        string path = PathUtil.Normalize(uri.AbsolutePath);
        string? fragment = uri.Fragment.Length > 1 ? Uri.UnescapeDataString(uri.Fragment[1..]) : null;
        await NavigateToAsync(path, fragment);
    }

    private async Task NavigateToAsync(string? path, string? fragment)
    {
        if (_book == null) return;
        int index = path == null ? _spineIndex : _book.FindSpineIndex(path);
        if (index < 0)
        {
            // spine に無いドキュメント (脚注ファイルなど) でも本文リソースなら表示する
            var res = path == null ? null : _book.FindResource(path);
            if (res == null || !PathUtil.IsHtmlMediaType(res.MediaType)) return;
            string url = BaseUrl + string.Join('/', res.Path.Split('/').Select(Uri.EscapeDataString));
            _pendingInitial = fragment == null ? "{\"type\":\"page\",\"page\":0}" : JsonSerializer.Serialize(new { type = "anchor", id = fragment });
            Web.CoreWebView2.Navigate(url);
            return;
        }
        if (index == _spineIndex && fragment != null)
        {
            await Web.CoreWebView2.ExecuteScriptAsync("window.__ev && window.__ev.gotoAnchor(" + JsonSerializer.Serialize(fragment) + ")");
            FocusWeb();
            return;
        }
        string initial = fragment == null ? "{\"type\":\"page\",\"page\":0}" : JsonSerializer.Serialize(new { type = "anchor", id = fragment });
        await GoToSpineAsync(index, initial);
    }

    private ViewerOptions BuildViewerOptions()
    {
        var (bg, fg) = _settings.ThemeColors;
        return new ViewerOptions
        {
            Vertical = IsVerticalEffective(),
            FontSizePx = _settings.FontSizePx,
            FontFamily = _settings.FontFamilyCss,
            LineHeight = _settings.LineHeight,
            PaddingPx = _settings.PaddingPx,
            Background = bg,
            Foreground = fg,
            InitialPositionJson = _pendingInitial,
        };
    }

    private bool IsVerticalEffective()
    {
        switch (_settings.WritingMode)
        {
            case "vertical": return true;
            case "horizontal": return false;
        }
        if (_book == null) return true;
        if (_book.DeclaredWritingMode == WritingMode.Vertical) return true;
        if (_book.DeclaredWritingMode == WritingMode.Horizontal) return false;
        // 宣言が無ければ日本語の本は縦書きにする
        string lang = _book.Metadata.Language;
        if (lang.StartsWith("ja", StringComparison.OrdinalIgnoreCase)) return true;
        if (lang.Length == 0) return ContainsJapanese(_book.Metadata.Title) || ContainsJapanese(_book.Metadata.Author);
        return false;
    }

    private static bool ContainsJapanese(string s)
    {
        foreach (char c in s)
        {
            if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x4E00 && c <= 0x9FFF)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // 目次
    // ------------------------------------------------------------------

    private void BuildTocList(BookDocument book)
    {
        var items = new List<TocItem>();
        void Add(IEnumerable<TocEntry> entries, int depth)
        {
            foreach (var e in entries)
            {
                items.Add(new TocItem(e, depth));
                Add(e.Children, depth + 1);
            }
        }
        Add(book.Toc, 0);
        if (items.Count == 0)
        {
            // 目次が無い本は spine の各ファイルを並べる
            for (int i = 0; i < book.Spine.Count; i++)
            {
                items.Add(new TocItem(new TocEntry($"{i + 1}. {PathUtil.GetFileName(book.Spine[i].Path)}", book.Spine[i].Path, null), 0));
            }
        }
        TocList.ItemsSource = items;
    }

    private async void TocList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not TocItem item || item.Entry.Path == null) return;
        await NavigateToAsync(item.Entry.Path, item.Entry.Fragment);
        if (Split.DisplayMode == SplitViewDisplayMode.Overlay) SetTocOpen(false);
        FocusWeb();
    }

    private void SetTocOpen(bool open)
    {
        Split.IsPaneOpen = open;
        TocToggle.IsChecked = open;
        _settings.TocOpen = open;
        _settings.Save();
        if (!open) FocusWeb();
    }

    // ------------------------------------------------------------------
    // UI イベント
    // ------------------------------------------------------------------

    private async void OpenButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        foreach (var ext in BookLoader.SupportedExtensions) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file != null) await OpenFileAsync(file.Path);
    }

    private void RecentFlyout_Opening(object sender, object e)
    {
        RecentFlyout.Items.Clear();
        var existing = _settings.RecentFiles.Where(File.Exists).ToList();
        if (existing.Count == 0)
        {
            RecentFlyout.Items.Add(new MenuFlyoutItem { Text = "(履歴はありません)", IsEnabled = false });
            return;
        }
        foreach (var path in existing)
        {
            var item = new MenuFlyoutItem { Text = Path.GetFileName(path) };
            ToolTipService.SetToolTip(item, path);
            string p = path;
            item.Click += async (_, _) => await OpenFileAsync(p);
            RecentFlyout.Items.Add(item);
        }
    }

    private void TocToggle_Click(object sender, RoutedEventArgs e)
    {
        SetTocOpen(TocToggle.IsChecked == true);
    }

    private async void PrevButton_Click(object sender, RoutedEventArgs e)
    {
        if (_book == null) return;
        await Web.CoreWebView2.ExecuteScriptAsync("window.__ev && window.__ev.prev()");
    }

    private async void NextButton_Click(object sender, RoutedEventArgs e)
    {
        if (_book == null) return;
        await Web.CoreWebView2.ExecuteScriptAsync("window.__ev && window.__ev.next()");
    }

    private async void WritingModeButton_Click(object sender, RoutedEventArgs e)
    {
        _settings.WritingMode = _settings.WritingMode switch
        {
            "auto" => "vertical",
            "vertical" => "horizontal",
            _ => "auto",
        };
        _settings.Save();
        UpdateWritingModeLabel();
        await ReloadCurrentAsync();
    }

    private async void FontDownButton_Click(object sender, RoutedEventArgs e)
    {
        _settings.FontSizePx = Math.Max(10, _settings.FontSizePx - 2);
        _settings.Save();
        await ReloadCurrentAsync();
    }

    private async void FontUpButton_Click(object sender, RoutedEventArgs e)
    {
        _settings.FontSizePx = Math.Min(48, _settings.FontSizePx + 2);
        _settings.Save();
        await ReloadCurrentAsync();
    }

    private async void ThemeItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is RadioMenuFlyoutItem item && item.Tag is string tag)
        {
            _settings.Theme = tag;
            _settings.Save();
            await ReloadCurrentAsync();
        }
    }

    private async void FontItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is RadioMenuFlyoutItem item && item.Tag is string tag)
        {
            _settings.FontKey = tag;
            _settings.Save();
            await ReloadCurrentAsync();
        }
    }

    private async void LineHeightItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is RadioMenuFlyoutItem item && item.Tag is string tag &&
            double.TryParse(tag, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double lh))
        {
            _settings.LineHeight = lh;
            _settings.Save();
            await ReloadCurrentAsync();
        }
    }

    private async void PaddingItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is RadioMenuFlyoutItem item && item.Tag is string tag && int.TryParse(tag, out int pad))
        {
            _settings.PaddingPx = pad;
            _settings.Save();
            await ReloadCurrentAsync();
        }
    }

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = e.DataView.Contains(StandardDataFormats.StorageItems) ? DataPackageOperation.Copy : DataPackageOperation.None;
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var file = items.OfType<StorageFile>().FirstOrDefault(f => BookLoader.IsSupported(f.Path));
        if (file != null) await OpenFileAsync(file.Path);
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        SavePosition();
        _positions.Save();
        try
        {
            var size = AppWindow.Size;
            _settings.WindowWidth = size.Width;
            _settings.WindowHeight = size.Height;
        }
        catch
        {
        }
        _settings.Save();
        _book?.Dispose();
    }

    // ------------------------------------------------------------------
    // 表示更新・保存
    // ------------------------------------------------------------------

    private void ApplySettingsToMenu()
    {
        ThemeLight.IsChecked = _settings.Theme == "light";
        ThemeSepia.IsChecked = _settings.Theme == "sepia";
        ThemeDark.IsChecked = _settings.Theme == "dark";
        FontMincho.IsChecked = _settings.FontKey != "gothic";
        FontGothic.IsChecked = _settings.FontKey == "gothic";
        LineHeight16.IsChecked = _settings.LineHeight < 1.75;
        LineHeight19.IsChecked = _settings.LineHeight >= 1.75 && _settings.LineHeight < 2.05;
        LineHeight22.IsChecked = _settings.LineHeight >= 2.05;
        Padding16.IsChecked = _settings.PaddingPx < 26;
        Padding36.IsChecked = _settings.PaddingPx >= 26 && _settings.PaddingPx < 50;
        Padding64.IsChecked = _settings.PaddingPx >= 50;
    }

    private void UpdateWritingModeLabel()
    {
        WritingModeButton.Label = _settings.WritingMode switch
        {
            "vertical" => "縦書き",
            "horizontal" => "横書き",
            _ => "自動",
        };
    }

    private void UpdateStatus()
    {
        if (_book == null)
        {
            StatusLeft.Text = "本を開いていません";
            StatusRight.Text = string.Empty;
            return;
        }
        string author = string.IsNullOrWhiteSpace(_book.Metadata.Author) ? string.Empty : "  ―  " + _book.Metadata.Author;
        string format = _book.Format switch
        {
            BookFormat.Epub => "EPUB",
            BookFormat.Kf8 => "KF8",
            _ => "MOBI",
        };
        StatusLeft.Text = $"{_book.Metadata.Title}{author}   [{format}]  {(IsVerticalEffective() ? "縦書き" : "横書き")}";
        string chapter = _book.Spine.Count > 1 ? $"章 {_spineIndex + 1}/{_book.Spine.Count}   " : string.Empty;
        StatusRight.Text = $"{chapter}ページ {_page + 1}/{_pages}";
    }

    private void ScheduleSave()
    {
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void SavePosition()
    {
        if (_book == null || _bookPath == null || _spineIndex < 0) return;
        double fraction = _pages > 1 ? (double)_page / (_pages - 1) : 0;
        _positions.Set(_bookPath, _spineIndex, fraction);
        _positions.Save();
    }

    private static readonly bool TraceEnabled = Environment.GetEnvironmentVariable("EBOOKVIEWER_TRACE") == "1";

    /// <summary>EBOOKVIEWER_TRACE=1 のとき LocalAppData/EbookViewer/trace.log に時刻付きで記録する (動作解析用)。</summary>
    private static void Trace(string message)
    {
        if (!TraceEnabled) return;
        try
        {
            File.AppendAllText(Path.Combine(App.DataDirectory, "trace.log"), $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
        }
        catch
        {
        }
    }

    private void FocusWeb()
    {
        bool ok = Web.Focus(FocusState.Programmatic);
        if (!ok) ok = Web.Focus(FocusState.Keyboard);
        Trace($"FocusWeb ok={ok} focused={FocusManager.GetFocusedElement(Root.XamlRoot)?.GetType().Name}");
    }

    private void ShowLoading(string text)
    {
        LoadingText.Text = text;
        LoadingOverlay.Visibility = Visibility.Visible;
    }

    private void HideLoading()
    {
        LoadingOverlay.Visibility = Visibility.Collapsed;
    }

    private async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "エラー",
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "閉じる",
            XamlRoot = Root.XamlRoot,
        };
        try
        {
            await dialog.ShowAsync();
        }
        catch
        {
            StatusRight.Text = message;
        }
    }
}
