using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace SCModLauncher;

public partial class MainWindow : Window
{
    private readonly Dictionary<string, string> _strings = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<ModuleManifest> _modules = new();
    private readonly Dictionary<string, CheckBox> _optionChecks = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _rootPath;
    private const string CurrentLauncherVersion = "1.0.0";
    private const string GitHubReleasesApiUrl = "https://api.github.com/repos/johnniewalker89/my-game-modding/releases?per_page=30";
    private const string LauncherAssetPrefix = "SC_Mod_Launcher_";
    private const string LauncherAssetSuffix = ".zip";
    private static readonly TimeSpan PreflightProcessTimeout = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan WarmCacheProcessTimeout = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan LiveApplyProcessTimeout = TimeSpan.FromMinutes(8);
    private static readonly TimeSpan DefaultBackendProcessTimeout = TimeSpan.FromMinutes(3);
    private static readonly HttpClient UpdateHttpClient = CreateUpdateHttpClient();
    private LauncherRelease? _latestLauncherRelease;
    private string? _verifiedUpdatePackagePath;
    private string? _verifiedUpdateSha256;
    private DispatcherTimer? _backendProgressTimer;
    private DispatcherTimer? _warmCacheAttentionTimer;
    private Run? _backendProgressRun;
    private string _backendProgressLabel = "";
    private int _backendProgressPercent;
    private int _backendProgressSoftCap;
    private bool _warmCacheAttentionBright;

    public MainWindow()
    {
        InitializeComponent();
        _rootPath = FindLauncherRoot();
        LoadStrings();
        LoadModules();
        ApplyStrings();
        LoadVisualAssets();
        BuildModuleCards();
        LivePathBox.Text = FindDefaultLivePath();
        AddLog(T("ready"));
        AddMetricLog(string.Format(T("modulesFound"), _modules.Count) + ".");
        AddMetricLog("Активные модули: " + string.Join("; ", _modules.Select(module => module.Name)) + ".");
        ShowOverview(this, new RoutedEventArgs());
    }

    private string T(string key)
    {
        return _strings.TryGetValue(key, out var value) ? value : key;
    }

    private static HttpClient CreateUpdateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(12)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("SC-Mod-Launcher/1.0");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    private static string FindLauncherRoot()
    {
        var dir = AppContext.BaseDirectory;
        while (!string.IsNullOrWhiteSpace(dir))
        {
            if (File.Exists(Path.Combine(dir, "SC_Mod_Launcher.ps1")) &&
                Directory.Exists(Path.Combine(dir, "modules")))
            {
                return dir;
            }

            var parent = Directory.GetParent(dir);
            if (parent is null)
            {
                break;
            }

            dir = parent.FullName;
        }

        return AppContext.BaseDirectory;
    }

    private void LoadStrings()
    {
        var path = Path.Combine(_rootPath, "ui", "strings.ru.json");
        if (!File.Exists(path))
        {
            return;
        }

        var json = File.ReadAllText(path, Encoding.UTF8);
        var values = JsonSerializer.Deserialize<Dictionary<string, string>>(json);
        if (values is null)
        {
            return;
        }

        foreach (var pair in values)
        {
            _strings[pair.Key] = pair.Value;
        }
    }

    private void LoadModules()
    {
        var modulesRoot = Path.Combine(_rootPath, "modules");
        if (!Directory.Exists(modulesRoot))
        {
            return;
        }

        foreach (var manifestPath in Directory.GetFiles(modulesRoot, "manifest.json", SearchOption.AllDirectories).OrderBy(p => p))
        {
            var json = File.ReadAllText(manifestPath, Encoding.UTF8);
            var manifest = JsonSerializer.Deserialize<ModuleManifest>(json);
            if (manifest is not null)
            {
                _modules.Add(manifest);
            }
        }
    }

    private void ApplyStrings()
    {
        Title = T("windowTitle");
        BrandRelayText.Text = T("brandRelay");
        TitleText.Text = T("title");
        HeaderVersionText.Text = CurrentLauncherVersion;
        SafeBoundaryText.Text = T("safeBoundary");

        OverviewNavButton.Content = T("navOverview");
        ModulesNavButton.Content = T("navModules");
        LivePathLabel.Text = T("livePath");
        BrowseButton.Content = T("chooseFolder");
        CheckPathButton.Content = T("checkPath");
        DryRunButton.Content = T("dryRun");
        WarmCacheButton.Content = T("warmCache");
        ApplyLiveButton.Content = T("applyLive");
        RestoreBackupButton.Content = T("restoreBackup");
        CheckUpdatesButton.Content = T("checkUpdates");
        InstallUpdateButton.Content = T("installUpdate");
        UpdatesScaffoldText.Text = T("updatesScaffold");
        BackupInfoText.Text = T("backupInfoEmpty");
        RefreshBackupsButton.Content = T("refreshBackups");
        RestoreLatestBackupButton.Content = T("restoreLatestBackup");
        RestoreSelectedBackupButton.Content = T("restoreSelectedBackup");
        DeleteSelectedBackupButton.Content = T("deleteSelectedBackup");
        LiveStatusText.Text = T("ready");
        ModulesStatusText.Text = string.Join("; ", _modules.Select(module => module.Name));
        UpdateStatusText.Text = "Канал обновлений готов.";
    }

    private void LoadVisualAssets()
    {
        var viewportPath = Path.Combine(_rootPath, "ui", "assets", "pirate-bridge-viewport.png");
        if (File.Exists(viewportPath))
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(viewportPath, UriKind.Absolute);
            image.EndInit();
            image.Freeze();

            BackdropImage.Source = image;
            MainDisplayImage.Source = image;
        }

        var hologramPath = Path.Combine(_rootPath, "ui", "assets", "cosmo-pirate-hologram-cutout.png");
        if (File.Exists(hologramPath))
        {
            var hologram = new BitmapImage();
            hologram.BeginInit();
            hologram.CacheOption = BitmapCacheOption.OnLoad;
            hologram.UriSource = new Uri(hologramPath, UriKind.Absolute);
            hologram.EndInit();
            hologram.Freeze();

            HologramImage.Source = hologram;
            HologramGhostLeft.Source = hologram;
            HologramGhostRight.Source = hologram;
        }
    }

    private void BuildModuleCards()
    {
        ModuleCardsPanel.Children.Clear();
        _optionChecks.Clear();

        foreach (var module in _modules)
        {
            var card = new Border
            {
                MinHeight = 245,
                Margin = new Thickness(0, 0, 12, 14),
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Background = Brushes.Transparent,
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x8A, 0x3A, 0x59, 0x66)),
                BorderThickness = new Thickness(1)
            };

            var shell = new Grid();
            shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
            shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            card.Child = shell;

            var accent = new Border
            {
                Background = module.Id.Equals("mining", StringComparison.OrdinalIgnoreCase)
                    ? (Brush)FindResource("SignalCyan")
                    : (Brush)FindResource("SignalAmber")
            };
            shell.Children.Add(accent);

            var stack = new StackPanel { Margin = new Thickness(18) };
            Grid.SetColumn(stack, 1);
            shell.Children.Add(stack);

            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            stack.Children.Add(header);

            var title = new TextBlock
            {
                Text = module.Name,
                FontSize = 18,
                FontWeight = FontWeights.Bold,
                Foreground = (Brush)FindResource("SignalCyan")
            };
            header.Children.Add(title);

            var badge = new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(65, 96, 110)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(8, 3, 8, 3),
                Margin = new Thickness(12, 0, 0, 0)
            };
            Grid.SetColumn(badge, 1);
            badge.Child = new TextBlock
            {
                Text = module.Id.ToUpperInvariant(),
                Foreground = (Brush)FindResource("TextSecondary"),
                FontSize = 11,
                FontWeight = FontWeights.Bold
            };
            header.Children.Add(badge);

            stack.Children.Add(new TextBlock
            {
                Text = module.Description,
                Margin = new Thickness(0, 7, 0, 10),
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)FindResource("TextSecondary")
            });
            stack.Children.Add(new Border
            {
                Height = 1,
                Background = new SolidColorBrush(Color.FromRgb(37, 57, 68)),
                Margin = new Thickness(0, 0, 0, 8)
            });

            var optionGroups = module.Options
                .Select((option, index) => new { Option = option, Index = index })
                .GroupBy(item => string.IsNullOrWhiteSpace(item.Option.Group) ? string.Empty : item.Option.Group)
                .OrderBy(group => group.Min(item => item.Index));

            foreach (var group in optionGroups)
            {
                if (!string.IsNullOrWhiteSpace(group.Key))
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = group.Key.ToUpperInvariant(),
                        Margin = new Thickness(0, 8, 0, 5),
                        Foreground = (Brush)FindResource("SignalAmber"),
                        FontSize = 11,
                        FontWeight = FontWeights.Bold
                    });
                }

                var groupGrid = new UniformGrid
                {
                    Columns = !string.IsNullOrWhiteSpace(group.Key) && group.Count() >= 4 ? 2 : 1,
                    Margin = new Thickness(0, 0, 0, 2)
                };
                stack.Children.Add(groupGrid);

                foreach (var item in group.OrderBy(item => item.Index))
                {
                    var option = item.Option;
                    var check = new CheckBox
                    {
                        Content = option.Name,
                        IsChecked = option.Default,
                        ToolTip = option.Description,
                        Tag = $"{module.Id}|{option.Id}",
                        Margin = new Thickness(0, 0, 8, 2)
                    };
                    check.Checked += ModuleOptionChanged;
                    check.Unchecked += ModuleOptionChanged;
                    groupGrid.Children.Add(check);
                    _optionChecks[(string)check.Tag] = check;
                }
            }

            ModuleCardsPanel.Children.Add(card);
        }

        UpdateMiningRecipeFilterState();
    }

    private void ModuleOptionChanged(object sender, RoutedEventArgs e)
    {
        UpdateMiningRecipeFilterState();
    }

    private void UpdateMiningRecipeFilterState()
    {
        var hasMiningMethod =
            IsOptionChecked("mining", "shipMining") ||
            IsOptionChecked("mining", "groundVehicleMining") ||
            IsOptionChecked("mining", "multitoolMining");

        foreach (var pair in _optionChecks)
        {
            if (!pair.Key.StartsWith("mining|", StringComparison.OrdinalIgnoreCase)) {
                continue;
            }

            var optionId = pair.Key.Split('|')[1];
            if (optionId is "itemCraftHints" or "shipMining" or "groundVehicleMining" or "multitoolMining") {
                continue;
            }

            pair.Value.IsEnabled = hasMiningMethod;
            pair.Value.Opacity = hasMiningMethod ? 1.0 : 0.42;
        }
    }

    private bool IsOptionChecked(string moduleId, string optionId)
    {
        return _optionChecks.TryGetValue($"{moduleId}|{optionId}", out var check) && check.IsChecked == true;
    }

    private static string FindDefaultLivePath()
    {
        var defaultPath = @"C:\Games\StarCitizen\LIVE";
        return Directory.Exists(defaultPath) ? defaultPath : string.Empty;
    }

    private bool HasGlobalIni()
    {
        return File.Exists(GetGlobalIniPath());
    }

    private string GetGlobalIniPath()
    {
        return Path.Combine(LivePathBox.Text.Trim(), "data", "Localization", "korean_(south_korea)", "global.ini");
    }

    private void AddLog(string text) => AddJournalLine(text, JournalLineKind.Normal);

    private void AddHeadingLog(string text) => AddJournalLine(text, JournalLineKind.Heading);

    private void AddMetricLog(string text) => AddJournalLine(text, JournalLineKind.Metric);

    private void AddErrorLog(string text) => AddJournalLine(text, JournalLineKind.Error);

    private void AddPathLog(string label, string path)
    {
        var paragraph = CreateJournalParagraph(JournalLineKind.Metric);
        paragraph.Inlines.Add(new Run(label + ": ")
        {
            Foreground = (Brush)FindResource("TextSecondary")
        });

        var link = new Hyperlink(new Run(Path.GetFileName(path)))
        {
            NavigateUri = new Uri("file:///" + path.Replace("\\", "/")),
            Foreground = (Brush)FindResource("SignalCyan"),
            TextDecorations = null,
            ToolTip = path
        };
        link.RequestNavigate += OpenLocalLogLink;
        paragraph.Inlines.Add(link);

        LogBox.Document.Blocks.Add(paragraph);
        LogBox.ScrollToEnd();
    }

    private void AddUriLog(string label, string uri, string? displayText = null)
    {
        var paragraph = CreateJournalParagraph(JournalLineKind.Metric);
        paragraph.Inlines.Add(new Run(label + ": ")
        {
            Foreground = (Brush)FindResource("TextSecondary")
        });

        var link = new Hyperlink(new Run(string.IsNullOrWhiteSpace(displayText) ? uri : displayText))
        {
            NavigateUri = new Uri(uri),
            Foreground = (Brush)FindResource("SignalCyan"),
            TextDecorations = null,
            ToolTip = uri
        };
        link.RequestNavigate += OpenLocalLogLink;
        paragraph.Inlines.Add(link);

        LogBox.Document.Blocks.Add(paragraph);
        LogBox.ScrollToEnd();
    }

    private void AddCacheLog(string cacheLine)
    {
        var path = ExtractTaggedValue(cacheLine, "path:");
        var display = cacheLine.StartsWith("Cache ", StringComparison.OrdinalIgnoreCase)
            ? cacheLine["Cache ".Length..]
            : cacheLine;
        display = RemoveTaggedTail(display, "file:");
        display = display.Replace("age:", "возраст:", StringComparison.OrdinalIgnoreCase);
        display = LocalizeAgeTokens(display).Trim().TrimEnd(';');

        var paragraph = CreateJournalParagraph(JournalLineKind.Metric);
        AddMetricRuns(paragraph, "Кэш " + display);

        if (!string.IsNullOrWhiteSpace(path))
        {
            paragraph.Inlines.Add(new Run("; ")
            {
                Foreground = (Brush)FindResource("TextSecondary")
            });
            AddInlinePathLink(paragraph, Path.GetFileName(path), path);
        }

        paragraph.Inlines.Add(new Run(".")
        {
            Foreground = (Brush)FindResource("TextSecondary")
        });
        LogBox.Document.Blocks.Add(paragraph);
        LogBox.ScrollToEnd();
    }

    private void AddInlinePathLink(Paragraph paragraph, string label, string path)
    {
        var link = new Hyperlink(new Run(label))
        {
            NavigateUri = new Uri("file:///" + path.Replace("\\", "/")),
            Foreground = (Brush)FindResource("SignalCyan"),
            TextDecorations = null,
            ToolTip = path
        };
        link.RequestNavigate += OpenLocalLogLink;
        paragraph.Inlines.Add(link);
    }

    private void AddJournalLine(string text, JournalLineKind kind)
    {
        var paragraph = CreateJournalParagraph(kind);
        if (kind == JournalLineKind.Metric)
        {
            AddMetricRuns(paragraph, text);
        }
        else
        {
            paragraph.Inlines.Add(new Run(text)
            {
                Foreground = GetJournalBrush(kind),
                FontWeight = kind is JournalLineKind.Heading or JournalLineKind.Error ? FontWeights.Bold : FontWeights.Normal
            });
        }

        LogBox.Document.Blocks.Add(paragraph);
        LogBox.ScrollToEnd();
    }

    private void StartBackendProgress(string label, int softCap = 82)
    {
        StopBackendProgress(success: false, keepFailureText: false);

        _backendProgressLabel = label;
        _backendProgressPercent = 4;
        _backendProgressSoftCap = softCap;
        var paragraph = CreateJournalParagraph(JournalLineKind.Metric);
        _backendProgressRun = new Run(BuildBackendProgressText(_backendProgressLabel, _backendProgressPercent))
        {
            Foreground = (Brush)FindResource("SignalCyan"),
            FontWeight = FontWeights.SemiBold
        };
        paragraph.Inlines.Add(_backendProgressRun);
        LogBox.Document.Blocks.Add(paragraph);
        LogBox.ScrollToEnd();

        _backendProgressTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(900)
        };
        _backendProgressTimer.Tick += (_, _) =>
        {
            if (_backendProgressRun is null)
            {
                return;
            }

            SetBackendProgress(Math.Min(_backendProgressSoftCap, _backendProgressPercent + 1));
        };
        _backendProgressTimer.Start();
    }

    private void StopBackendProgress(bool success, bool keepFailureText = true)
    {
        if (_backendProgressTimer is not null)
        {
            _backendProgressTimer.Stop();
            _backendProgressTimer = null;
        }

        if (_backendProgressRun is not null)
        {
            _backendProgressRun.Text = success
                ? BuildBackendProgressText(_backendProgressLabel, 100)
                : keepFailureText
                    ? $"{_backendProgressLabel} [----------] ошибка"
                    : _backendProgressRun.Text;
            _backendProgressRun.Foreground = success
                ? (Brush)FindResource("SignalCyan")
                : keepFailureText
                    ? (Brush)FindResource("SignalRed")
                    : _backendProgressRun.Foreground;
        }
    }

    private void SetBackendProgress(int percent)
    {
        if (_backendProgressRun is null)
        {
            return;
        }

        _backendProgressPercent = Math.Max(_backendProgressPercent, Math.Clamp(percent, 0, 100));
        _backendProgressRun.Text = BuildBackendProgressText(_backendProgressLabel, _backendProgressPercent);
    }

    private void HandleBackendProgressLine(BackendRunMode mode, string line)
    {
        if (_backendProgressRun is null)
        {
            return;
        }

        if (mode == BackendRunMode.WarmCache)
        {
            if (line.StartsWith("Source SCMDB index:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(15);
            else if (line.StartsWith("Source SCMDB data:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(25);
            else if (line.StartsWith("Wiki blueprints:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(55);
            else if (line.StartsWith("Cache mining blueprints:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(68);
            else if (line.StartsWith("Quest cache warmup:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(86);
            else if (line.StartsWith("Cache quest items:", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(96);
        }
        else if (mode == BackendRunMode.LiveApply)
        {
            if (line.Equals("Progress: apply sources", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(18);
            else if (line.Equals("Progress: apply plan", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(42);
            else if (line.Equals("Progress: apply write", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(78);
            else if (line.StartsWith("SC Mod Launcher LIVE apply", StringComparison.OrdinalIgnoreCase)) SetBackendProgress(92);
        }
    }

    private static string BuildBackendProgressText(string label, int percent)
    {
        var safePercent = Math.Clamp(percent, 0, 100);
        var filled = Math.Clamp(safePercent / 10, 0, 10);
        return $"{label} [{new string('#', filled)}{new string('-', 10 - filled)}] {safePercent}%";
    }

    private Paragraph CreateJournalParagraph(JournalLineKind kind)
    {
        return new Paragraph
        {
            Margin = new Thickness(0, kind == JournalLineKind.Heading ? 5 : 0, 0, 5),
            LineHeight = 16,
            Foreground = GetJournalBrush(kind),
            FontWeight = kind == JournalLineKind.Heading ? FontWeights.SemiBold : FontWeights.Normal
        };
    }

    private void AddMetricRuns(Paragraph paragraph, string text)
    {
        var pattern = @"\b(?:OK|FAIL|HIT|STALE|MISSING|REFRESHED)\b|\d+(?:/\d+)?|\d+\s*(?:правок|конфликтов|оставлено|скрыто|changed|safe)";
        var cursor = 0;
        foreach (Match match in Regex.Matches(text, pattern, RegexOptions.IgnoreCase))
        {
            if (match.Index > cursor)
            {
                paragraph.Inlines.Add(new Run(text[cursor..match.Index])
                {
                    Foreground = (Brush)FindResource("TextSecondary")
                });
            }

            paragraph.Inlines.Add(new Run(match.Value)
            {
                Foreground = GetMetricBrush(match.Value),
                FontWeight = FontWeights.SemiBold
            });
            cursor = match.Index + match.Length;
        }

        if (cursor < text.Length)
        {
            paragraph.Inlines.Add(new Run(text[cursor..])
            {
                Foreground = (Brush)FindResource("TextSecondary")
            });
        }
    }

    private Brush GetJournalBrush(JournalLineKind kind)
    {
        return kind switch
        {
            JournalLineKind.Heading => (Brush)FindResource("SignalAmber"),
            JournalLineKind.Error => (Brush)FindResource("SignalRed"),
            JournalLineKind.Metric => (Brush)FindResource("TextSecondary"),
            _ => (Brush)FindResource("TextPrimary")
        };
    }

    private Brush GetMetricBrush(string value)
    {
        if (value.Equals("FAIL", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("MISSING", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("STALE", StringComparison.OrdinalIgnoreCase))
        {
            return (Brush)FindResource("SignalAmber");
        }

        return (Brush)FindResource("SignalCyan");
    }

    private void SetWarmCacheAttention(bool enabled)
    {
        StopWarmCacheAttentionPulse();
        if (!enabled)
        {
            WarmCacheButton.ClearValue(Control.BackgroundProperty);
            WarmCacheButton.BorderBrush = new SolidColorBrush(Color.FromRgb(0x58, 0x76, 0x87));
            WarmCacheButton.Foreground = (Brush)FindResource("TextPrimary");
            return;
        }

        _warmCacheAttentionBright = false;
        ApplyWarmCacheAttentionColors();
        _warmCacheAttentionTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1150) };
        _warmCacheAttentionTimer.Tick += (_, _) =>
        {
            _warmCacheAttentionBright = !_warmCacheAttentionBright;
            ApplyWarmCacheAttentionColors();
        };
        _warmCacheAttentionTimer.Start();
    }

    private void ApplyWarmCacheAttentionColors()
    {
        WarmCacheButton.Background = new SolidColorBrush(_warmCacheAttentionBright
            ? Color.FromRgb(0x69, 0x48, 0x10)
            : Color.FromRgb(0x2D, 0x21, 0x0E));
        WarmCacheButton.BorderBrush = new SolidColorBrush(_warmCacheAttentionBright
            ? Color.FromRgb(0xFF, 0xE0, 0x86)
            : Color.FromRgb(0xFF, 0xB8, 0x4A));
        WarmCacheButton.Foreground = new SolidColorBrush(_warmCacheAttentionBright
            ? Color.FromRgb(0xFF, 0xF0, 0xB8)
            : Color.FromRgb(0xFF, 0xD2, 0x76));
    }

    private void StopWarmCacheAttentionPulse()
    {
        if (_warmCacheAttentionTimer is null)
        {
            return;
        }

        _warmCacheAttentionTimer.Stop();
        _warmCacheAttentionTimer = null;
    }

    private static string ShortPath(string path)
    {
        return string.IsNullOrWhiteSpace(path) ? "" : Path.GetFileName(path);
    }

    private void OpenLocalLogLink(object sender, RequestNavigateEventArgs e)
    {
        try
        {
            var path = e.Uri.LocalPath;
            if (File.Exists(path))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "/select," + Quote(path),
                    UseShellExecute = true
                });
            }
            else if (Directory.Exists(path))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = path,
                    UseShellExecute = true
                });
            }
        }
        catch (Exception ex)
        {
            AddErrorLog("Не удалось открыть ссылку: " + ex.Message);
        }

        e.Handled = true;
    }

    private void AddError(string text)
    {
        SetJournalState("КРАСНЫЙ КОНТУР: " + text, isError: true);
        AddErrorLog("КРАСНЫЙ КОНТУР: " + text);
    }

    private void SetJournalState(string text, bool isError = false)
    {
        SafeBoundaryText.Text = text;
        SafeBoundaryText.Foreground = isError ? (Brush)FindResource("SignalRed") : (Brush)FindResource("TextSecondary");
        LogBox.BorderBrush = isError ? (Brush)FindResource("SignalRed") : (Brush)FindResource("SignalCyan");
    }

    private void SetScreen(string titleKey, string subtitleKey, ScrollViewer visiblePanel)
    {
        ScreenTitleText.Text = T(titleKey);
        ScreenSubtitleText.Text = T(subtitleKey);

        foreach (var panel in new[] { OverviewPanel, ModulesPanel, BackupPanel })
        {
            panel.Visibility = panel == visiblePanel ? Visibility.Visible : Visibility.Collapsed;
        }

        UpdateNavState(visiblePanel);
    }

    private void UpdateNavState(ScrollViewer visiblePanel)
    {
        var buttons = new[] { OverviewNavButton, ModulesNavButton, RestoreBackupButton };
        foreach (var button in buttons)
        {
            button.Background = new SolidColorBrush(Color.FromArgb(0xA0, 0x15, 0x25, 0x2D));
            button.BorderBrush = new SolidColorBrush(Color.FromRgb(0x40, 0x5F, 0x6D));
            button.Foreground = (Brush)FindResource("TextPrimary");
        }

        var active = OverviewNavButton;
        if (visiblePanel == ModulesPanel) active = ModulesNavButton;
        else if (visiblePanel == BackupPanel) active = RestoreBackupButton;

        active.Background = new SolidColorBrush(Color.FromArgb(0xE5, 0x1D, 0x3A, 0x45));
        active.BorderBrush = (Brush)FindResource("SignalCyan");
        active.Foreground = (Brush)FindResource("SignalCyan");
    }

    private void ShowOverview(object sender, RoutedEventArgs e) => SetScreen("overviewTitle", "overviewSubtitle", OverviewPanel);

    private void ShowModules(object sender, RoutedEventArgs e) => SetScreen("modulesTitle", "modulesSubtitle", ModulesPanel);

    private void ShowBackup(object sender, RoutedEventArgs e)
    {
        RefreshBackupList();
        SetScreen("backupTitle", "backupSubtitle", BackupPanel);
    }

    private void BrowseLivePath(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "Select StarCitizen LIVE folder",
            ShowNewFolderButton = false,
            SelectedPath = Directory.Exists(LivePathBox.Text) ? LivePathBox.Text : FindDefaultLivePath()
        };

        if (dialog.ShowDialog() == Forms.DialogResult.OK)
        {
            LivePathBox.Text = dialog.SelectedPath;
            CheckPath(sender, e);
        }
    }

    private void CheckPath(object sender, RoutedEventArgs e)
    {
        if (HasGlobalIni())
        {
            LiveStatusText.Text = T("liveFound");
            SetJournalState("LIVE найден. Контур готов к проверке.");
            AddLog(T("liveFound"));
        }
        else
        {
            LiveStatusText.Text = T("liveMissing");
            AddError(T("liveMissing"));
        }
    }

    private Dictionary<string, string[]> GetSelectedOptions()
    {
        var selected = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var module in _modules)
        {
            selected[module.Id] = new List<string>();
        }

        foreach (var pair in _optionChecks)
        {
            if (pair.Value.IsChecked != true)
            {
                continue;
            }

            var parts = pair.Key.Split('|', 2);
            if (parts.Length == 2 && selected.TryGetValue(parts[0], out var options))
            {
                options.Add(parts[1]);
            }
        }

        return selected.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray(), StringComparer.OrdinalIgnoreCase);
    }

    private string WriteSelectedOptionsFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"sc-mod-options-{Guid.NewGuid():N}.json");
        var json = JsonSerializer.Serialize(GetSelectedOptions(), new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json, new UTF8Encoding(false));
        return path;
    }

    private async void RunDryRun(object sender, RoutedEventArgs e)
    {
        if (!HasGlobalIni())
        {
            AddError(T("liveMissing"));
            return;
        }

        await RunBackendAsync(BackendRunMode.Preflight);
    }

    private async void WarmCache(object sender, RoutedEventArgs e)
    {
        if (!HasGlobalIni())
        {
            AddError(T("liveMissing"));
            return;
        }

        await RunBackendAsync(BackendRunMode.WarmCache);
    }

    private async void RunLiveApply(object sender, RoutedEventArgs e)
    {
        if (!HasGlobalIni())
        {
            AddError(T("liveMissing"));
            return;
        }

        if (!await EnsureLiveApplyReadyAsync())
        {
            return;
        }

        await RunBackendAsync(BackendRunMode.LiveApply);
    }

    private void RefreshBackups(object sender, RoutedEventArgs e)
    {
        RefreshBackupList();
        AddMetricLog("Backup: список обновлён.");
    }

    private void RestoreLatestBackup(object sender, RoutedEventArgs e)
    {
        if (!HasGlobalIni())
        {
            AddError(T("liveMissing"));
            return;
        }

        var backupPath = FindLatestGlobalIniBackup();
        if (backupPath is null)
        {
            AddError(T("restoreBackupMissing"));
            return;
        }

        RestoreBackup(backupPath);
    }

    private void RestoreSelectedBackup(object sender, RoutedEventArgs e)
    {
        if (!HasGlobalIni())
        {
            AddError(T("liveMissing"));
            return;
        }

        if (BackupListBox.SelectedItem is not BackupEntry selected)
        {
            AddError(T("restoreBackupNotSelected"));
            return;
        }

        RestoreBackup(selected.FilePath);
    }

    private void RestoreBackup(string backupPath)
    {
        try
        {
            var globalIniPath = GetGlobalIniPath();
            var backupDir = Path.Combine(_rootPath, "backups");
            Directory.CreateDirectory(backupDir);

            var safetyBackupPath = Path.Combine(backupDir, $"global.ini.{DateTime.Now:yyyyMMdd-HHmmss}.before-restore.bak");
            File.Copy(globalIniPath, safetyBackupPath, overwrite: false);
            WriteBackupMetadata(safetyBackupPath);
            File.Copy(backupPath, globalIniPath, overwrite: true);

            SetJournalState(T("restoreBackupComplete"));
            AddHeadingLog(T("restoreBackupComplete"));
            AddPathLog("Восстановлено из", backupPath);
            AddPathLog("Страховка перед восстановлением", safetyBackupPath);
            RefreshBackupList();
        }
        catch (Exception ex)
        {
            AddError("Не удалось восстановить backup: " + ex.Message);
        }
    }

    private void DeleteSelectedBackup(object sender, RoutedEventArgs e)
    {
        if (BackupListBox.SelectedItem is not BackupEntry selected)
        {
            AddError(T("restoreBackupNotSelected"));
            return;
        }

        try
        {
            var fileName = selected.FileName;
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(
                selected.FilePath,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            DeleteBackupMetadata(selected.FilePath);

            SetJournalState(string.Format(T("deleteBackupComplete"), fileName));
            AddHeadingLog(string.Format(T("deleteBackupComplete"), fileName));
            RefreshBackupList();
        }
        catch (Exception ex)
        {
            AddError("Не удалось удалить backup: " + ex.Message);
        }
    }

    private string? FindLatestGlobalIniBackup()
    {
        var backupDir = Path.Combine(_rootPath, "backups");
        if (!Directory.Exists(backupDir))
        {
            return null;
        }

        return GetGlobalIniBackups().FirstOrDefault(entry => !entry.IsBeforeRestore)?.FilePath;
    }

    private void RefreshBackupList()
    {
        var entries = GetGlobalIniBackups().ToList();
        BackupListBox.ItemsSource = entries;

        if (entries.Count == 0)
        {
            BackupInfoText.Text = T("backupInfoEmpty");
            return;
        }

        BackupListBox.SelectedIndex = 0;
        var latest = entries[0];
        BackupInfoText.Text =
            $"Последний backup: {latest.KindLabel} / {latest.PurposeLabel}\n" +
            $"Дата: {latest.BackupTime:yyyy-MM-dd HH:mm:ss}\n" +
            $"Размер: {Math.Ceiling(latest.Length / 1024.0):0} KB\n\n" +
            "Выбери backup из списка или восстанови последний.";
    }

    private IEnumerable<BackupEntry> GetGlobalIniBackups()
    {
        var backupDir = Path.Combine(_rootPath, "backups");
        if (!Directory.Exists(backupDir))
        {
            return Enumerable.Empty<BackupEntry>();
        }

        return Directory.GetFiles(backupDir, "global.ini.*.bak", SearchOption.TopDirectoryOnly)
            .Where(path => IsGlobalIniBackupFile(Path.GetFileName(path)))
            .Select(path =>
            {
                var info = new FileInfo(path);
                var backupTime = GetBackupTime(info);
                var kind = GetBackupKind(path);
                var purpose = GetBackupPurpose(info.Name);
                return new BackupEntry(
                    FilePath: path,
                    FileName: info.Name,
                    BackupTime: backupTime,
                    Length: info.Length,
                    Kind: kind,
                    KindLabel: GetBackupKindLabel(kind),
                    PurposeLabel: purpose,
                    IsBeforeRestore: info.Name.Contains(".before-restore.", StringComparison.OrdinalIgnoreCase),
                    DisplayName: $"{backupTime:yyyy-MM-dd HH:mm:ss}  |  {GetBackupKindLabel(kind)}  |  {purpose}  |  {Math.Ceiling(info.Length / 1024.0):0} KB  |  {info.Name}");
            })
            .OrderByDescending(entry => entry.BackupTime);
    }

    private static bool IsGlobalIniBackupFile(string fileName)
    {
        return Regex.IsMatch(
            fileName,
            @"^global\.ini\.\d{8}-\d{6}\.(sc-mod-launcher|before-restore)\.bak$",
            RegexOptions.IgnoreCase);
    }

    private static DateTime GetBackupTime(FileInfo info)
    {
        var match = Regex.Match(info.Name, @"^global\.ini\.(\d{8}-\d{6})\.(?:sc-mod-launcher|before-restore)\.bak$", RegexOptions.IgnoreCase);
        if (match.Success &&
            DateTime.TryParseExact(
                match.Groups[1].Value,
                "yyyyMMdd-HHmmss",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out var backupTime))
        {
            return backupTime;
        }

        return info.CreationTime;
    }

    private static string GetBackupPurpose(string fileName)
    {
        return fileName.Contains(".before-restore.", StringComparison.OrdinalIgnoreCase)
            ? "страховка перед восстановлением"
            : "backup перед патчем";
    }

    private static string GetBackupKindLabel(string kind)
    {
        return kind.ToLowerInvariant() switch
        {
            "clean" => "чистый",
            "patched" => "патченый",
            _ => "неизвестно"
        };
    }

    private static string GetBackupKind(string backupPath)
    {
        var metadataPath = GetBackupMetadataPath(backupPath);
        try
        {
            if (File.Exists(metadataPath))
            {
                var metadata = JsonSerializer.Deserialize<BackupMetadata>(
                    File.ReadAllText(metadataPath, Encoding.UTF8));
                if (metadata is not null && metadata.Kind is "clean" or "patched")
                {
                    return metadata.Kind;
                }
            }
        }
        catch
        {
        }

        return DetectBackupKind(backupPath);
    }

    private static string DetectBackupKind(string backupPath)
    {
        try
        {
            var text = File.ReadAllText(backupPath, Encoding.UTF8);
            if (text.Contains("Крафт-подсказка (SCMDB)", StringComparison.Ordinal) ||
                text.Contains("<EM4>Доступные чертежи</EM4>", StringComparison.Ordinal))
            {
                return "patched";
            }

            return "clean";
        }
        catch
        {
            return "unknown";
        }
    }

    private static void WriteBackupMetadata(string backupPath)
    {
        try
        {
            var info = new FileInfo(backupPath);
            var metadata = new BackupMetadata
            {
                Kind = DetectBackupKind(backupPath),
                CreatedAt = DateTimeOffset.Now.ToString("O", CultureInfo.InvariantCulture),
                FileName = info.Name,
                Size = info.Length,
                Sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(backupPath)))
            };
            var json = JsonSerializer.Serialize(metadata, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(GetBackupMetadataPath(backupPath), json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        }
        catch
        {
            // The backup file is the important safety artifact; metadata is helpful but non-critical.
        }
    }

    private static void DeleteBackupMetadata(string backupPath)
    {
        var metadataPath = GetBackupMetadataPath(backupPath);
        if (File.Exists(metadataPath))
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(
                metadataPath,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
    }

    private static string GetBackupMetadataPath(string backupPath) => backupPath + ".meta.json";

    private async Task RunBackendAsync(BackendRunMode mode)
    {
        DryRunButton.IsEnabled = false;
        WarmCacheButton.IsEnabled = false;
        ApplyLiveButton.IsEnabled = false;
        RestoreBackupButton.IsEnabled = false;
        RestoreLatestBackupButton.IsEnabled = false;
        RestoreSelectedBackupButton.IsEnabled = false;
        DeleteSelectedBackupButton.IsEnabled = false;

        var optionsPath = WriteSelectedOptionsFile();
        try
        {
            SetJournalState(mode == BackendRunMode.LiveApply
                ? "Канал связи проверяется. Ждём ответ SCMDB."
                : "Проверяю источники и cache.");
            AddHeadingLog(mode switch
            {
                BackendRunMode.Preflight => T("runningPreflight"),
                BackendRunMode.WarmCache => T("runningWarmCache"),
                BackendRunMode.LiveApply => T("runningLiveApply"),
                _ => T("runningDryRun")
            });
            if (mode == BackendRunMode.WarmCache)
            {
                StartBackendProgress("Прогрев кэша", softCap: 82);
            }
            else if (mode == BackendRunMode.LiveApply)
            {
                StartBackendProgress("Применение в LIVE", softCap: 88);
            }

            var args = BuildBackendArguments(mode, mode is BackendRunMode.DryRun or BackendRunMode.LiveApply ? optionsPath : null);
            var result = await RunProcessAsync("powershell.exe", args.ToString(), line => HandleBackendProgressLine(mode, line), GetBackendTimeout(mode));
            if (mode is BackendRunMode.WarmCache or BackendRunMode.LiveApply)
            {
                StopBackendProgress(result.ExitCode == 0 && string.IsNullOrWhiteSpace(result.Error));
            }

            if (result.ExitCode == 0 && !string.IsNullOrWhiteSpace(result.Output))
            {
                switch (mode)
                {
                    case BackendRunMode.Preflight:
                        AddPreflightSummary(result.Output);
                        break;
                    case BackendRunMode.WarmCache:
                        AddWarmCacheSummary(result.Output);
                        break;
                    default:
                        AddBackendSummary(result.Output, mode);
                        break;
                }
            }

            if (result.ExitCode != 0)
            {
                var message = !string.IsNullOrWhiteSpace(result.Error) ? result.Error.Trim() : result.Output.Trim();
                AddError(string.IsNullOrWhiteSpace(message) ? $"Процесс завершился с кодом {result.ExitCode}." : message);
            }
            else if (!string.IsNullOrWhiteSpace(result.Error))
            {
                AddError(result.Error.Trim());
            }
        }
        catch (Exception ex)
        {
            if (mode is BackendRunMode.WarmCache or BackendRunMode.LiveApply)
            {
                StopBackendProgress(success: false);
            }

            AddError(ex.Message);
        }
        finally
        {
            if ((mode is BackendRunMode.WarmCache or BackendRunMode.LiveApply) && _backendProgressTimer is not null)
            {
                StopBackendProgress(success: false);
            }

            TryDelete(optionsPath);
            DryRunButton.IsEnabled = true;
            WarmCacheButton.IsEnabled = true;
            ApplyLiveButton.IsEnabled = true;
            RestoreBackupButton.IsEnabled = true;
            RestoreLatestBackupButton.IsEnabled = true;
            RestoreSelectedBackupButton.IsEnabled = true;
            DeleteSelectedBackupButton.IsEnabled = true;
        }
    }

    private StringBuilder BuildBackendArguments(BackendRunMode mode, string? optionsPath)
    {
        var args = new StringBuilder();
        args.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        args.Append(Quote(Path.Combine(_rootPath, "SC_Mod_Launcher.ps1")));
        args.Append(" -LivePath ");
        args.Append(Quote(LivePathBox.Text.Trim()));
        if (!string.IsNullOrWhiteSpace(optionsPath))
        {
            args.Append(" -SelectedOptionsJson ");
            args.Append(Quote(optionsPath));
        }

        args.Append(mode switch
        {
            BackendRunMode.Preflight => " -Preflight",
            BackendRunMode.WarmCache => " -WarmCache",
            BackendRunMode.DryRun => " -DryRun",
            _ => " -ApplyLive"
        });

        return args;
    }

    private async Task<bool> EnsureLiveApplyReadyAsync()
    {
        DryRunButton.IsEnabled = false;
        WarmCacheButton.IsEnabled = false;
        ApplyLiveButton.IsEnabled = false;
        RestoreBackupButton.IsEnabled = false;
        RestoreLatestBackupButton.IsEnabled = false;
        RestoreSelectedBackupButton.IsEnabled = false;
        DeleteSelectedBackupButton.IsEnabled = false;

        try
        {
            SetJournalState("Проверяю источники и cache перед LIVE apply.");
            AddHeadingLog("Предстартовая проверка LIVE...");
            var result = await RunProcessAsync("powershell.exe", BuildBackendArguments(BackendRunMode.Preflight, null).ToString(), timeout: PreflightProcessTimeout);
            if (result.ExitCode != 0)
            {
                var message = !string.IsNullOrWhiteSpace(result.Error) ? result.Error.Trim() : result.Output.Trim();
                AddError(string.IsNullOrWhiteSpace(message) ? $"Предстартовая проверка завершилась с кодом {result.ExitCode}." : message);
                return false;
            }

            var status = GetPreflightStatus(result.Output);
            if (status.HasBlockingFailure)
            {
                AddPreflightSummary(result.Output);
                AddErrorLog("LIVE apply остановлен: источник или global.ini недоступен.");
                return false;
            }

            if (status.HasCacheIssue)
            {
                AddPreflightSummary(result.Output);
                SetWarmCacheAttention(true);
                SetJournalState("LIVE apply остановлен: cache требует прогрева.");
                AddHeadingLog("Кэш не найден или устарел. Сначала прогрей кэш.");
                return false;
            }

            AddMetricLog("Предстартовая проверка: OK. Cache свежий.");
            return true;
        }
        catch (Exception ex)
        {
            AddError(ex.Message);
            return false;
        }
        finally
        {
            DryRunButton.IsEnabled = true;
            WarmCacheButton.IsEnabled = true;
            ApplyLiveButton.IsEnabled = true;
            RestoreBackupButton.IsEnabled = true;
            RestoreLatestBackupButton.IsEnabled = true;
            RestoreSelectedBackupButton.IsEnabled = true;
            DeleteSelectedBackupButton.IsEnabled = true;
        }
    }

    private static string Quote(string value) => '"' + value.Replace("\"", "\\\"") + '"';

    private void AddPreflightSummary(string output)
    {
        var lines = GetBackendLines(output);
        string FindValue(string prefix) => lines.FirstOrDefault(line => line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))?.Substring(prefix.Length).Trim() ?? "";

        AddMetricLog($"LIVE: global.ini {TextOrUnknown(FindValue("global.ini:"))}.");
        AddMetricLog($"Модули: {TextOrUnknown(FindValue("Modules:"))}; {TextOrUnknown(FindValue("Module names:"))}.");

        foreach (var sourceLine in lines.Where(line => line.StartsWith("Source ", StringComparison.OrdinalIgnoreCase)))
        {
            AddMetricLog("Источник " + sourceLine["Source ".Length..] + ".");
        }

        var staleOrMissing = false;
        foreach (var cacheLine in lines.Where(line => line.StartsWith("Cache ", StringComparison.OrdinalIgnoreCase)))
        {
            AddCacheLog(cacheLine);

            staleOrMissing = staleOrMissing ||
                cacheLine.Contains("STALE", StringComparison.OrdinalIgnoreCase) ||
                cacheLine.Contains("MISSING", StringComparison.OrdinalIgnoreCase) ||
                cacheLine.Contains("FAIL", StringComparison.OrdinalIgnoreCase);
        }

        var status = GetPreflightStatus(output);
        var wikiFallback = IsWikiBlueprintFailureCoveredByCache(lines);
        var state = status.HasBlockingFailure
            ? "КРАСНЫЙ КОНТУР: источник или global.ini недоступен."
            : staleOrMissing
                ? "Источники доступны. Cache устарел: прогрей кэш перед применением."
                : wikiFallback
                    ? "Wiki временно недоступна. Используем свежий cache."
                    : "Источники доступны. Cache свежий.";
        SetJournalState(state, status.HasBlockingFailure);
        SetWarmCacheAttention(staleOrMissing && !status.HasBlockingFailure);
        if (wikiFallback && !staleOrMissing && !status.HasBlockingFailure)
        {
            AddMetricLog("Wiki временно недоступна, используем свежий cache.");
        }
        if (staleOrMissing && !status.HasBlockingFailure)
        {
            AddHeadingLog("Пора прогреть кэш.");
        }
    }

    private static PreflightStatus GetPreflightStatus(string output)
    {
        var lines = GetBackendLines(output);
        var sourceFailure = lines.Any(line =>
            line.StartsWith("Source ", StringComparison.OrdinalIgnoreCase) &&
            line.Contains(": FAIL", StringComparison.OrdinalIgnoreCase) &&
            !IsWikiBlueprintFailureCoveredByCache(line, lines));
        var globalMissing = lines.Any(line =>
            line.StartsWith("global.ini:", StringComparison.OrdinalIgnoreCase) &&
            line.Contains("MISSING", StringComparison.OrdinalIgnoreCase));
        var cacheFail = lines.Any(line =>
            line.StartsWith("Cache ", StringComparison.OrdinalIgnoreCase) &&
            line.Contains("FAIL", StringComparison.OrdinalIgnoreCase));
        var cacheIssue = lines.Any(line =>
            line.StartsWith("Cache ", StringComparison.OrdinalIgnoreCase) &&
            (line.Contains("MISSING", StringComparison.OrdinalIgnoreCase) ||
             line.Contains("STALE", StringComparison.OrdinalIgnoreCase) ||
             line.Contains("FAIL", StringComparison.OrdinalIgnoreCase)));

        return new PreflightStatus(sourceFailure || globalMissing || cacheFail, cacheIssue);
    }

    private static bool IsWikiBlueprintFailureCoveredByCache(IEnumerable<string> lines)
    {
        var lineList = lines as IReadOnlyCollection<string> ?? lines.ToArray();
        return lineList.Any(line => IsWikiBlueprintFailureCoveredByCache(line, lineList));
    }

    private static bool IsWikiBlueprintFailureCoveredByCache(string sourceLine, IEnumerable<string> lines)
    {
        if (!sourceLine.StartsWith("Source Wiki blueprints:", StringComparison.OrdinalIgnoreCase) ||
            !sourceLine.Contains(": FAIL", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return lines.Any(line =>
            line.StartsWith("Cache mining blueprints:", StringComparison.OrdinalIgnoreCase) &&
            line.Contains("HIT", StringComparison.OrdinalIgnoreCase));
    }

    private void AddWarmCacheSummary(string output)
    {
        var lines = GetBackendLines(output);
        foreach (var sourceLine in lines.Where(line => line.StartsWith("Source ", StringComparison.OrdinalIgnoreCase)))
        {
            AddMetricLog("Источник " + sourceLine["Source ".Length..] + ".");
        }

        var version = lines.FirstOrDefault(line => line.StartsWith("SCMDB version:", StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(version))
        {
            AddMetricLog(version);
        }

        var blueprints = lines.FirstOrDefault(line => line.StartsWith("Wiki blueprints:", StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(blueprints))
        {
            AddMetricLog("Wiki recipes: " + AfterColon(blueprints) + ".");
        }

        foreach (var cacheLine in lines.Where(line => line.StartsWith("Cache ", StringComparison.OrdinalIgnoreCase)))
        {
            AddCacheLog(cacheLine);
        }

        var hasFailure = lines.Any(line => line.Contains(": FAIL", StringComparison.OrdinalIgnoreCase));
        SetJournalState(hasFailure ? "КРАСНЫЙ КОНТУР: cache не прогрет." : "Cache прогрет. Можно применять в LIVE.", hasFailure);
        if (!hasFailure)
        {
            SetWarmCacheAttention(false);
        }
    }

    private void AddBackendSummary(string output, BackendRunMode mode)
    {
        var lines = GetBackendLines(output);

        string FindValue(string prefix) => lines.FirstOrDefault(line => line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))?.Substring(prefix.Length).Trim() ?? "";

        var operations = FindValue("Operations:");
        var conflicts = FindValue("Conflicts:");
        var backup = FindValue("Backup:");
        var writeSucceeded = FindValue("Write succeeded:");
        var miningModule = lines.FirstOrDefault(line => line.StartsWith("Module Майнинг", StringComparison.OrdinalIgnoreCase)) ?? "";
        var miningMethods = FindValue("Mining methods:");
        var planetDescriptions = FindValue("Planet descriptions:");
        var itemCraftHints = FindValue("Item craft hints:");
        var questModule = lines.FirstOrDefault(line => line.StartsWith("Module Квесты и рецепты:", StringComparison.OrdinalIgnoreCase)) ?? "";
        var questDescriptions = FindValue("Quest descriptions:");
        var questTitles = FindValue("Quest titles:");

        var modeLabel = mode switch
        {
            BackendRunMode.DryRun => "СКАН",
            _ => "LIVE APPLY"
        };
        AddMetricLog($"{modeLabel}: {TextOrUnknown(operations)} правок, конфликтов {TextOrUnknown(conflicts)}.");

        if (!string.IsNullOrWhiteSpace(writeSucceeded))
        {
            var writeLabel = mode == BackendRunMode.LiveApply ? "LIVE" : "проверки";
            AddMetricLog($"Запись {writeLabel}: {(writeSucceeded.Equals("True", StringComparison.OrdinalIgnoreCase) ? "OK" : writeSucceeded)}.");
        }

        if (!string.IsNullOrWhiteSpace(miningModule))
        {
            AddMetricLog($"Майнинг: {AfterColon(miningModule)}; {TextOrUnknown(miningMethods)}; планеты {ShortPlanetLine(planetDescriptions)}.");
            if (!string.IsNullOrWhiteSpace(itemCraftHints))
            {
                AddMetricLog($"Предметы: {itemCraftHints}.");
            }
        }

        if (!string.IsNullOrWhiteSpace(questModule))
        {
            AddMetricLog($"Квесты: {AfterColon(questModule)}.");
            if (!string.IsNullOrWhiteSpace(questDescriptions) || !string.IsNullOrWhiteSpace(questTitles))
            {
                AddMetricLog($"Чертежи: {ShortQuestLine(questDescriptions)}; названия {TextOrUnknown(questTitles)}.");
            }
        }

        if (!string.IsNullOrWhiteSpace(backup))
        {
            AddPathLog("Backup", backup);
        }

        var hasConflicts = int.TryParse(conflicts, out var conflictCount) && conflictCount > 0;
        var cleanMessage = mode == BackendRunMode.LiveApply
            ? "LIVE apply завершён. Backup сохранён."
            : "Контур чист. Можно применять в LIVE.";
        SetJournalState(hasConflicts ? "КРАСНЫЙ КОНТУР: есть конфликт модулей." : cleanMessage, hasConflicts);
    }

    private static string TextOrUnknown(string value) => string.IsNullOrWhiteSpace(value) ? "?" : value;

    private static string[] GetBackendLines(string output)
    {
        return output
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
            .Select(line => line.Trim())
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .ToArray();
    }

    private static string ExtractTaggedValue(string line, string tag)
    {
        var index = line.IndexOf(tag, StringComparison.OrdinalIgnoreCase);
        return index >= 0 ? line[(index + tag.Length)..].Trim() : "";
    }

    private static string RemoveTaggedTail(string line, string tag)
    {
        var index = line.IndexOf(tag, StringComparison.OrdinalIgnoreCase);
        return index >= 0 ? line[..index].Trim().TrimEnd(';') : line.Trim();
    }

    private static string LocalizeAgeTokens(string value)
    {
        var localized = Regex.Replace(value, @"(?<d>\d+)d\s+(?<h>\d+)h", "${d} д ${h} ч");
        localized = Regex.Replace(localized, @"(?<h>\d+)h\s+(?<m>\d+)m", "${h} ч ${m} мин");
        localized = Regex.Replace(localized, @"(?<m>\d+)m\b", "${m} мин");
        return localized;
    }

    private static string AfterColon(string value)
    {
        var index = value.IndexOf(':');
        return index >= 0 && index + 1 < value.Length ? value[(index + 1)..].Trim() : value.Trim();
    }

    private static string ShortPlanetLine(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "?";
        }

        var match = Regex.Match(value, @"(?<changed>\d+)\s+changed\s+of\s+(?<total>\d+)", RegexOptions.IgnoreCase);
        return match.Success ? $"{match.Groups["changed"].Value}/{match.Groups["total"].Value}" : value;
    }

    private static string ShortQuestLine(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "?";
        }

        var match = Regex.Match(value, @"(?<changed>\d+)\s+changed;\s+kept blocks:\s+(?<kept>\d+),\s+filtered blocks:\s+(?<filtered>\d+)", RegexOptions.IgnoreCase);
        return match.Success
            ? $"{match.Groups["kept"].Value} оставлено, {match.Groups["filtered"].Value} скрыто"
            : value;
    }

    private static TimeSpan GetBackendTimeout(BackendRunMode mode) => mode switch
    {
        BackendRunMode.Preflight => PreflightProcessTimeout,
        BackendRunMode.WarmCache => WarmCacheProcessTimeout,
        BackendRunMode.LiveApply => LiveApplyProcessTimeout,
        _ => DefaultBackendProcessTimeout
    };

    private async Task<ProcessResult> RunProcessAsync(
        string fileName,
        string arguments,
        Action<string>? outputLineHandler = null,
        TimeSpan? timeout = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Failed to start process.");
        var outputBuilder = new StringBuilder();
        var outputTask = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                outputBuilder.AppendLine(line);
                if (outputLineHandler is not null)
                {
                    await Dispatcher.InvokeAsync(() => outputLineHandler(line));
                }
            }
        });
        var errorTask = process.StandardError.ReadToEndAsync();
        var effectiveTimeout = timeout ?? DefaultBackendProcessTimeout;
        using var timeoutCts = new CancellationTokenSource(effectiveTimeout);
        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // The timeout result below is more useful than a secondary kill failure.
            }

            try
            {
                await process.WaitForExitAsync();
            }
            catch
            {
                // Ignore: the user-facing timeout is the actionable signal.
            }

            await Task.WhenAny(outputTask, Task.Delay(TimeSpan.FromSeconds(2)));
            var timeoutOutput = outputBuilder.ToString();
            var timeoutError = $"Команда не ответила за {FormatDuration(effectiveTimeout)}. Процесс остановлен, повтори проверку или прогрей кэш.";
            return new ProcessResult(timeoutOutput, timeoutError, -1);
        }

        await outputTask;
        var output = outputBuilder.ToString();
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            error = string.IsNullOrWhiteSpace(error) ? $"Process exited with code {process.ExitCode}." : error;
        }

        return new ProcessResult(output, error, process.ExitCode);
    }

    private static string FormatDuration(TimeSpan value)
    {
        if (value.TotalMinutes >= 1)
        {
            return $"{Math.Round(value.TotalMinutes)} мин";
        }

        return $"{Math.Round(value.TotalSeconds)} сек";
    }

    private async void CheckUpdates(object sender, RoutedEventArgs e)
    {
        CheckUpdatesButton.IsEnabled = false;
        InstallUpdateButton.IsEnabled = false;
        _latestLauncherRelease = null;
        _verifiedUpdatePackagePath = null;
        _verifiedUpdateSha256 = null;
        UpdatesScaffoldText.Foreground = (Brush)FindResource("TextSecondary");
        UpdatesScaffoldText.Text = "Запрос GitHub...";
        UpdateStatusText.Text = "Проверяю GitHub Releases...";
        SetJournalState("Канал обновлений проверяется.");
        AddHeadingLog("Канал обновлений: проверка GitHub.");

        try
        {
            var release = await GetLatestLauncherReleaseAsync();
            if (release is null)
            {
                var noLauncherRelease = "Канал обновлений доступен, но релиз лаунчера пока не найден.\n\n" +
                    "Ищу asset формата SC_Mod_Launcher_*.zip, чтобы не спутать лаунчер с релизами других модов.";
                UpdatesScaffoldText.Text = noLauncherRelease;
                UpdateStatusText.Text = "Релиз лаунчера не найден.";
                SetJournalState("GitHub доступен. Релиз лаунчера пока не опубликован.");
                AddLog("Обновления: релиз SC_Mod_Launcher_*.zip пока не найден.");
                return;
            }

            var comparison = CompareVersions(release.Version, CurrentLauncherVersion);
            _latestLauncherRelease = release;
            var status = comparison > 0
                ? "Доступна новая версия."
                : comparison == 0
                    ? "Установлена актуальная версия."
                    : "Локальная версия новее опубликованной.";

            UpdatesScaffoldText.Text = BuildReleaseSummary(release, status);
            UpdateStatusText.Text = comparison > 0
                ? $"Доступно: {release.Version}"
                : $"Актуально: {CurrentLauncherVersion}";
            SetJournalState(comparison > 0
                ? $"Найдено обновление лаунчера: {release.Version}."
                : "Канал обновлений чист.");
            AddMetricLog(comparison > 0
                ? $"Канал обновлений: доступна версия {release.Version}."
                : $"Канал обновлений: актуально, версия {CurrentLauncherVersion}.");
            AddUriLog("Релиз", release.HtmlUrl, release.TagName);
            InstallUpdateButton.IsEnabled = comparison > 0 && !string.IsNullOrWhiteSpace(release.ExpectedSha256);
            if (string.IsNullOrWhiteSpace(release.ExpectedSha256))
            {
                AddErrorLog("Канал обновлений: SHA-256 не найден, установка заблокирована.");
            }
        }
        catch (Exception ex)
        {
            var message = "GitHub Releases недоступны: " + ShortError(ex.Message);
            UpdatesScaffoldText.Foreground = (Brush)FindResource("SignalRed");
            UpdatesScaffoldText.Text = message;
            UpdateStatusText.Text = "Ошибка канала обновлений.";
            AddError(message);
        }
        finally
        {
            CheckUpdatesButton.IsEnabled = true;
        }
    }

    private static async Task<LauncherRelease?> GetLatestLauncherReleaseAsync()
    {
        using var response = await UpdateHttpClient.GetAsync(GitHubReleasesApiUrl);
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync();
        var releases = await JsonSerializer.DeserializeAsync<List<GitHubRelease>>(stream);
        if (releases is null)
        {
            return null;
        }

        foreach (var release in releases.OrderByDescending(item => item.PublishedAt ?? item.CreatedAt ?? DateTimeOffset.MinValue))
        {
            var asset = release.Assets.FirstOrDefault(IsLauncherAsset);
            if (asset is null)
            {
                continue;
            }

            return new LauncherRelease(
                Version: ExtractVersionFromAsset(asset.Name) ?? release.TagName,
                TagName: release.TagName,
                Name: string.IsNullOrWhiteSpace(release.Name) ? release.TagName : release.Name,
                Body: release.Body ?? "",
                HtmlUrl: release.HtmlUrl,
                PublishedAt: release.PublishedAt,
                AssetName: asset.Name,
                AssetSize: asset.Size,
                AssetDownloadUrl: asset.BrowserDownloadUrl,
                ExpectedSha256: ExtractExpectedSha256(asset, release.Body ?? "")
            );
        }

        return null;
    }

    private static bool IsLauncherAsset(GitHubAsset asset)
    {
        return asset.Name.StartsWith(LauncherAssetPrefix, StringComparison.OrdinalIgnoreCase)
            && asset.Name.EndsWith(LauncherAssetSuffix, StringComparison.OrdinalIgnoreCase);
    }

    private static string? ExtractVersionFromAsset(string assetName)
    {
        if (!assetName.StartsWith(LauncherAssetPrefix, StringComparison.OrdinalIgnoreCase) ||
            !assetName.EndsWith(LauncherAssetSuffix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return assetName[LauncherAssetPrefix.Length..^LauncherAssetSuffix.Length];
    }

    private static string? ExtractExpectedSha256(GitHubAsset asset, string releaseBody)
    {
        if (!string.IsNullOrWhiteSpace(asset.Digest))
        {
            var digest = asset.Digest.Trim();
            if (digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
            {
                return digest["sha256:".Length..].Trim().ToUpperInvariant();
            }
        }

        var assetNamePattern = Regex.Escape(asset.Name);
        var nearAsset = Regex.Match(
            releaseBody,
            assetNamePattern + @"[\s\S]{0,240}?(?<hash>[A-Fa-f0-9]{64})",
            RegexOptions.IgnoreCase);
        if (nearAsset.Success)
        {
            return nearAsset.Groups["hash"].Value.ToUpperInvariant();
        }

        var anySha = Regex.Match(releaseBody, @"(?<hash>[A-Fa-f0-9]{64})");
        return anySha.Success ? anySha.Groups["hash"].Value.ToUpperInvariant() : null;
    }

    private static string BuildReleaseSummary(LauncherRelease release, string status)
    {
        var published = release.PublishedAt.HasValue
            ? release.PublishedAt.Value.LocalDateTime.ToString("yyyy-MM-dd HH:mm")
            : "дата неизвестна";
        var size = release.AssetSize > 0 ? $"{Math.Ceiling(release.AssetSize / 1024.0):0} KB" : "размер неизвестен";
        var shaStatus = string.IsNullOrWhiteSpace(release.ExpectedSha256)
            ? "SHA-256: не найден"
            : "SHA-256: найден";

        return $"{status}\n" +
            $"{CurrentLauncherVersion} -> {release.Version}\n" +
            $"{release.AssetName} ({size})\n" +
            $"{shaStatus}; {published}";
    }

    private static string ShortReleaseNotes(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return "Описание релиза пустое.";
        }

        var lines = body
            .Replace("\r", "")
            .Split('\n')
            .Select(line => line.Trim())
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .Take(6)
            .ToArray();
        var text = string.Join(Environment.NewLine, lines);
        return text.Length <= 520 ? text : text[..520] + "...";
    }

    private static int CompareVersions(string left, string right)
    {
        var leftMatch = Regex.Match(left, @"v?(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<suffix>.*)", RegexOptions.IgnoreCase);
        var rightMatch = Regex.Match(right, @"v?(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<suffix>.*)", RegexOptions.IgnoreCase);
        if (!leftMatch.Success || !rightMatch.Success)
        {
            return string.Compare(left, right, StringComparison.OrdinalIgnoreCase);
        }

        foreach (var group in new[] { "major", "minor", "patch" })
        {
            var diff = int.Parse(leftMatch.Groups[group].Value) - int.Parse(rightMatch.Groups[group].Value);
            if (diff != 0)
            {
                return diff;
            }
        }

        var leftSuffix = leftMatch.Groups["suffix"].Value.Trim();
        var rightSuffix = rightMatch.Groups["suffix"].Value.Trim();
        if (leftSuffix.Length == 0 && rightSuffix.Length > 0)
        {
            return 1;
        }

        if (leftSuffix.Length > 0 && rightSuffix.Length == 0)
        {
            return -1;
        }

        return string.Compare(leftSuffix, rightSuffix, StringComparison.OrdinalIgnoreCase);
    }

    private static string ShortError(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return "неизвестная ошибка";
        }

        return message.Length <= 180 ? message : message[..180] + "...";
    }

    private async void UpdateLauncher(object sender, RoutedEventArgs e)
    {
        if (await DownloadUpdatePackageAsync())
        {
            InstallUpdate(sender, e);
        }
    }

    private async Task<bool> DownloadUpdatePackageAsync()
    {
        if (_latestLauncherRelease is null)
        {
            AddError("Сначала проверь обновления.");
            return false;
        }

        CheckUpdatesButton.IsEnabled = false;
        InstallUpdateButton.IsEnabled = false;
        _verifiedUpdatePackagePath = null;
        _verifiedUpdateSha256 = null;

        try
        {
            var downloadDir = Path.Combine(_rootPath, "updates", "downloads");
            Directory.CreateDirectory(downloadDir);
            var packagePath = Path.Combine(downloadDir, _latestLauncherRelease.AssetName);

            UpdatesScaffoldText.Foreground = (Brush)FindResource("TextSecondary");
            UpdatesScaffoldText.Text = "Скачиваю " + _latestLauncherRelease.AssetName + "...";
            SetJournalState("Скачиваю обновление лаунчера.");
            AddLog("Обновления: скачивание " + _latestLauncherRelease.AssetName);

            using var response = await UpdateHttpClient.GetAsync(_latestLauncherRelease.AssetDownloadUrl);
            response.EnsureSuccessStatusCode();

            await using (var source = await response.Content.ReadAsStreamAsync())
            await using (var destination = File.Create(packagePath))
            {
                await source.CopyToAsync(destination);
            }

            var actualSha = ComputeSha256(packagePath);
            if (string.IsNullOrWhiteSpace(_latestLauncherRelease.ExpectedSha256))
            {
                UpdatesScaffoldText.Foreground = (Brush)FindResource("SignalAmber");
                UpdatesScaffoldText.Text =
                    $"Файл скачан, но SHA-256 не опубликован в релизе.\n\nПуть: {packagePath}\nSHA-256 файла: {actualSha}\n\nУстановка заблокирована до проверяемого хэша.";
                UpdateStatusText.Text = "Скачано без проверяемого хэша.";
                SetJournalState("Обновление скачано, но хэш не опубликован.");
                AddLog("Обновления: скачано, но ожидаемый SHA-256 не найден.");
                return false;
            }

            if (!actualSha.Equals(_latestLauncherRelease.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                UpdatesScaffoldText.Foreground = (Brush)FindResource("SignalRed");
                UpdatesScaffoldText.Text =
                    $"SHA-256 не совпал.\n\nОжидалось: {_latestLauncherRelease.ExpectedSha256}\nПолучено: {actualSha}\n\nУстановка заблокирована.";
                UpdateStatusText.Text = "Ошибка проверки SHA-256.";
                AddError("SHA-256 скачанного обновления не совпал.");
                return false;
            }

            _verifiedUpdatePackagePath = packagePath;
            _verifiedUpdateSha256 = actualSha;
            InstallUpdateButton.IsEnabled = true;
            UpdatesScaffoldText.Text =
                $"Обновление скачано и проверено.\n\nПуть: {packagePath}\nSHA-256: {actualSha}\n\nМожно установить обновление.";
            UpdateStatusText.Text = "Обновление проверено.";
            SetJournalState("Обновление скачано и проверено.");
            AddLog("Обновления: SHA-256 совпал, установка доступна.");
            return true;
        }
        catch (Exception ex)
        {
            UpdatesScaffoldText.Foreground = (Brush)FindResource("SignalRed");
            UpdatesScaffoldText.Text = "Не удалось скачать обновление: " + ShortError(ex.Message);
            UpdateStatusText.Text = "Ошибка скачивания.";
            AddError("Не удалось скачать обновление: " + ShortError(ex.Message));
            return false;
        }
        finally
        {
            CheckUpdatesButton.IsEnabled = true;
            InstallUpdateButton.IsEnabled = _latestLauncherRelease is not null &&
                !string.IsNullOrWhiteSpace(_latestLauncherRelease.ExpectedSha256);
        }
    }

    private void InstallUpdate(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_verifiedUpdatePackagePath) ||
            string.IsNullOrWhiteSpace(_verifiedUpdateSha256) ||
            !File.Exists(_verifiedUpdatePackagePath))
        {
            AddError("Нет проверенного ZIP обновления.");
            return;
        }

        var helper = Path.Combine(_rootPath, "tools", "Install-ScModLauncherUpdate.ps1");
        if (!File.Exists(helper))
        {
            AddError("Helper обновления не найден: " + helper);
            return;
        }

        var restartExe = Path.Combine(_rootPath, "app", "SCModLauncher.exe");
        var args = new StringBuilder();
        args.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        args.Append(Quote(helper));
        args.Append(" -PackagePath ");
        args.Append(Quote(_verifiedUpdatePackagePath));
        args.Append(" -TargetRoot ");
        args.Append(Quote(_rootPath));
        args.Append(" -ExpectedSha256 ");
        args.Append(Quote(_verifiedUpdateSha256));
        args.Append(" -RestartExe ");
        args.Append(Quote(restartExe));
        args.Append(" -LauncherProcessId ");
        args.Append(Process.GetCurrentProcess().Id);

        Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = args.ToString(),
            UseShellExecute = false,
            CreateNoWindow = true
        });
        Close();
    }

    private static string ComputeSha256(string path)
    {
        using var stream = File.OpenRead(path);
        var bytes = SHA256.HashData(stream);
        return Convert.ToHexString(bytes);
    }

    private void HeaderMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            return;
        }

        try
        {
            DragMove();
        }
        catch
        {
        }
    }

    private void MinimizeWindow(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void CloseWindow(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void OpenSignatureLink(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = e.Uri.AbsoluteUri,
            UseShellExecute = true
        });
        e.Handled = true;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    private sealed record ProcessResult(string Output, string Error, int ExitCode);

    private sealed record PreflightStatus(bool HasBlockingFailure, bool HasCacheIssue);
}

public enum BackendRunMode
{
    Preflight,
    WarmCache,
    DryRun,
    LiveApply
}

public enum JournalLineKind
{
    Normal,
    Heading,
    Metric,
    Error
}

public sealed class ModuleManifest
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("description")]
    public string Description { get; set; } = "";

    [JsonPropertyName("options")]
    public List<ModuleOption> Options { get; set; } = new();
}

public sealed class ModuleOption
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("description")]
    public string Description { get; set; } = "";

    [JsonPropertyName("group")]
    public string Group { get; set; } = "";

    [JsonPropertyName("default")]
    public bool Default { get; set; }
}

public sealed class GitHubRelease
{
    [JsonPropertyName("tag_name")]
    public string TagName { get; set; } = "";

    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("body")]
    public string? Body { get; set; }

    [JsonPropertyName("html_url")]
    public string HtmlUrl { get; set; } = "";

    [JsonPropertyName("created_at")]
    public DateTimeOffset? CreatedAt { get; set; }

    [JsonPropertyName("published_at")]
    public DateTimeOffset? PublishedAt { get; set; }

    [JsonPropertyName("assets")]
    public List<GitHubAsset> Assets { get; set; } = new();
}

public sealed class GitHubAsset
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("browser_download_url")]
    public string BrowserDownloadUrl { get; set; } = "";

    [JsonPropertyName("digest")]
    public string? Digest { get; set; }
}

public sealed record LauncherRelease(
    string Version,
    string TagName,
    string Name,
    string Body,
    string HtmlUrl,
    DateTimeOffset? PublishedAt,
    string AssetName,
    long AssetSize,
    string AssetDownloadUrl,
    string? ExpectedSha256);

public sealed record BackupEntry(
    string FilePath,
    string FileName,
    DateTime BackupTime,
    long Length,
    string Kind,
    string KindLabel,
    string PurposeLabel,
    bool IsBeforeRestore,
    string DisplayName);

public sealed class BackupMetadata
{
    [JsonPropertyName("kind")]
    public string Kind { get; set; } = "unknown";

    [JsonPropertyName("createdAt")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("fileName")]
    public string FileName { get; set; } = "";

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("sha256")]
    public string Sha256 { get; set; } = "";
}
