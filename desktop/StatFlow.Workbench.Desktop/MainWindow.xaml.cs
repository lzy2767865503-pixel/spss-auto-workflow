using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace StatFlow.Workbench.Desktop;

public partial class MainWindow : Window
{
    private readonly BackendHost _backend = new();
    private readonly CancellationTokenSource _shutdown = new();
    private readonly TaskCompletionSource _uiReadyMessage = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Uri? _localOrigin;
    private EventWaitHandle? _uiReady;
    private bool _closed;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += MainWindow_Loaded;
        Closing += MainWindow_Closing;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            var dataRoot = ResolveDataRoot();
            var ready = await _backend.StartAsync(dataRoot, _shutdown.Token);
            _shutdown.Token.ThrowIfCancellationRequested();
            _localOrigin = new Uri(ready.Url.GetLeftPart(UriPartial.Authority));

            var webViewData = Path.Combine(dataRoot, "WebView2");
            Directory.CreateDirectory(webViewData);
            var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: webViewData);
            await Browser.EnsureCoreWebView2Async(environment);
            _shutdown.Token.ThrowIfCancellationRequested();
            ConfigureWebView();

            var destination = new UriBuilder(ready.Url)
            {
                Fragment = $"token={Uri.EscapeDataString(ready.ApiToken)}",
            }.Uri;
            Browser.Source = destination;
            Browser.Visibility = Visibility.Visible;
            StartupPanel.Visibility = Visibility.Collapsed;

        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
            // Normal shutdown during startup.
        }
        catch (WebView2RuntimeNotFoundException)
        {
            ShowStartupError("缺少 Microsoft Edge WebView2 Runtime。请从 Microsoft 官方渠道安装 Evergreen Runtime 后重试。");
        }
        catch (Exception error)
        {
            ShowStartupError($"应用无法启动：{error.Message}");
        }
    }

    private static string ResolveDataRoot()
    {
        try
        {
            return Windows.Storage.ApplicationData.Current.LocalFolder.Path;
        }
        catch
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "LAI Systems", "Survey Data Workbench");
        }
    }

    private void ConfigureWebView()
    {
        var core = Browser.CoreWebView2;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = Debugger.IsAttached;
        core.Settings.IsBuiltInErrorPageEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsSwipeNavigationEnabled = false;
        core.NavigationStarting += (_, args) =>
        {
            if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var target) ||
                _localOrigin is null ||
                !string.Equals(target.GetLeftPart(UriPartial.Authority), _localOrigin.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase))
            {
                args.Cancel = true;
            }
        };
        core.NavigationCompleted += Browser_NavigationCompleted;
        core.WebMessageReceived += Browser_WebMessageReceived;
        core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var target) && target.Scheme == Uri.UriSchemeHttps)
            {
                Process.Start(new ProcessStartInfo(target.AbsoluteUri) { UseShellExecute = true });
            }
        };
        core.ProcessFailed += (_, _) => Dispatcher.Invoke(() => ShowStartupError("界面进程异常退出，请重新启动应用。"));
    }

    private async void Browser_NavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            Browser.CoreWebView2.NavigationCompleted -= Browser_NavigationCompleted;
            Browser.CoreWebView2.WebMessageReceived -= Browser_WebMessageReceived;
            ShowStartupError($"界面导航失败：{args.WebErrorStatus}");
            return;
        }

        try
        {
            await _uiReadyMessage.Task.WaitAsync(TimeSpan.FromSeconds(30), _shutdown.Token);
            Browser.CoreWebView2.NavigationCompleted -= Browser_NavigationCompleted;
            Browser.CoreWebView2.WebMessageReceived -= Browser_WebMessageReceived;
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
            // Normal shutdown during UI readiness verification.
        }
        catch (Exception error)
        {
            Browser.CoreWebView2.NavigationCompleted -= Browser_NavigationCompleted;
            Browser.CoreWebView2.WebMessageReceived -= Browser_WebMessageReceived;
            ShowStartupError($"界面未完成初始化：{error.Message}");
        }
    }

    private void Browser_WebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (_uiReadyMessage.Task.IsCompleted)
        {
            return;
        }

        try
        {
            if (_localOrigin is null || !Uri.TryCreate(args.Source, UriKind.Absolute, out var source) ||
                !string.Equals(source.GetLeftPart(UriPartial.Authority), _localOrigin.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("UI readiness message came from an unexpected origin.");
            }
            using var document = JsonDocument.Parse(args.WebMessageAsJson);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 2 ||
                !root.TryGetProperty("type", out var type) || type.GetString() != "statflow-ui-ready" ||
                !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number ||
                version.GetInt32() != 1)
            {
                throw new InvalidOperationException("UI readiness message has an unexpected schema.");
            }
            var eventName = $@"Local\LAISystems.StatFlowWorkbench.Ready.{Environment.ProcessId}";
            _uiReady = new EventWaitHandle(false, EventResetMode.ManualReset, eventName, out var createdNew);
            if (!createdNew)
            {
                throw new InvalidOperationException("UI readiness event already existed.");
            }
            _uiReady.Set();
            _uiReadyMessage.TrySetResult();
        }
        catch (Exception error)
        {
            _uiReadyMessage.TrySetException(error);
        }
    }

    private void ShowStartupError(string message)
    {
        Browser.Visibility = Visibility.Collapsed;
        StartupPanel.Visibility = Visibility.Visible;
        StartupProgress.Visibility = Visibility.Collapsed;
        StartupStatus.Text = message;
        CloseButton.Visibility = Visibility.Visible;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private async void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_closed)
        {
            e.Cancel = true;
            return;
        }

        e.Cancel = true;
        _closed = true;
        _shutdown.Cancel();
        _uiReady?.Dispose();
        _uiReady = null;
        Browser.Dispose();
        await _backend.DisposeAsync();
        _shutdown.Dispose();
        Closing -= MainWindow_Closing;
        Close();
    }
}
