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
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
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
    private readonly List<MiningCraftFamilySection> _miningCraftFamilySections = new();
    private readonly List<Button> _miningCraftFamilyActionButtons = new();
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
    private Run? _backendProgressRun;
    private string _backendProgressLabel = "";
    private int _backendProgressPercent;
    private int _backendProgressSoftCap;
    private bool _launchButtonGlitchesStarted;
    private bool _journalIsError;
    private bool _miningCraftFamilyIndexRepairQueued;
    private bool _miningCraftFamilyIndexRepairFailed;
    private readonly List<DispatcherTimer> _launchButtonGlitchTimers = new();

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
        Loaded += async (_, _) =>
        {
            StartLaunchButtonGlitches();
            await CheckUpdatesAsync();
        };
        Closed += (_, _) => StopLaunchButtonGlitches();
    }

    private void StartLaunchButtonGlitches()
    {
        if (_launchButtonGlitchesStarted)
        {
            return;
        }

        _launchButtonGlitchesStarted = true;
        StartLaunchButtonGlitch(DryRunButton, TimeSpan.FromMilliseconds(320), TimeSpan.FromMilliseconds(5600), -1.0, 1.006);
        StartLaunchButtonGlitch(WarmCacheButton, TimeSpan.FromMilliseconds(1780), TimeSpan.FromMilliseconds(6900), 1.0, 1.008);
        StartLaunchButtonGlitch(ApplyLiveButton, TimeSpan.FromMilliseconds(3150), TimeSpan.FromMilliseconds(6200), -0.6, 1.007);
        StartLaunchButtonGlitch(BrowseButton, TimeSpan.FromMilliseconds(2240), TimeSpan.FromMilliseconds(7300), 0.5, 1.004);
        StartLaunchButtonGlitch(CheckPathButton, TimeSpan.FromMilliseconds(3820), TimeSpan.FromMilliseconds(7900), -0.5, 1.004);
        StartLaunchButtonGlitch(InstallUpdateButton, TimeSpan.FromMilliseconds(5100), TimeSpan.FromMilliseconds(8800), 0.7, 1.004);
        StartLaunchButtonGlitch(RefreshBackupsButton, TimeSpan.FromMilliseconds(1460), TimeSpan.FromMilliseconds(7600), -0.4, 1.004);
        StartLaunchButtonGlitch(RestoreLatestBackupButton, TimeSpan.FromMilliseconds(2680), TimeSpan.FromMilliseconds(8200), 0.4, 1.004);
        StartLaunchButtonGlitch(RestoreSelectedBackupButton, TimeSpan.FromMilliseconds(4020), TimeSpan.FromMilliseconds(8700), -0.5, 1.004);
        StartLaunchButtonGlitch(DeleteSelectedBackupButton, TimeSpan.FromMilliseconds(5480), TimeSpan.FromMilliseconds(9300), 0.5, 1.004);
        StartLaunchButtonGlitch(OverviewNavButton, TimeSpan.FromMilliseconds(960), TimeSpan.FromMilliseconds(7600), 0.8, 1.004);
        StartLaunchButtonGlitch(ModulesNavButton, TimeSpan.FromMilliseconds(2860), TimeSpan.FromMilliseconds(8400), -0.7, 1.005);
        StartLaunchButtonGlitch(RestoreBackupButton, TimeSpan.FromMilliseconds(4380), TimeSpan.FromMilliseconds(7100), 0.6, 1.004);
        for (var i = 0; i < _miningCraftFamilyActionButtons.Count; i++)
        {
            StartLaunchButtonGlitch(
                _miningCraftFamilyActionButtons[i],
                TimeSpan.FromMilliseconds(620 + ((i * 470) % 5200)),
                TimeSpan.FromMilliseconds(6500 + ((i * 390) % 2400)),
                i % 2 == 0 ? 0.45 : -0.45,
                1.003);
        }
    }

    private void StartLaunchButtonGlitch(Button button, TimeSpan firstDelay, TimeSpan interval, double direction, double peakScale)
    {
        PrepareLaunchButtonGlitch(button);

        var starter = new DispatcherTimer { Interval = firstDelay };
        starter.Tick += (_, _) =>
        {
            starter.Stop();
            _launchButtonGlitchTimers.Remove(starter);
            PulseLaunchButtonGlitch(button, direction, peakScale);

            var timer = new DispatcherTimer { Interval = interval };
            timer.Tick += (_, _) => PulseLaunchButtonGlitch(button, direction, peakScale);
            _launchButtonGlitchTimers.Add(timer);
            timer.Start();
        };

        _launchButtonGlitchTimers.Add(starter);
        starter.Start();
    }

    private static void PrepareLaunchButtonGlitch(Button button)
    {
        if (button.RenderTransform is not TransformGroup group ||
            group.Children.OfType<ScaleTransform>().FirstOrDefault() is null ||
            group.Children.OfType<TranslateTransform>().FirstOrDefault() is null)
        {
            group = new TransformGroup();
            group.Children.Add(new ScaleTransform(1, 1));
            group.Children.Add(new TranslateTransform(0, 0));
            button.RenderTransform = group;
        }

        button.RenderTransformOrigin = new Point(0.5, 0.5);
        if (button.Effect is not BlurEffect)
        {
            button.Effect = new BlurEffect { Radius = 0 };
        }
    }

    private static void PulseLaunchButtonGlitch(Button button, double direction, double peakScale)
    {
        if (!button.IsLoaded || !button.IsEnabled)
        {
            return;
        }

        PrepareLaunchButtonGlitch(button);
        var group = (TransformGroup)button.RenderTransform;
        var scale = group.Children.OfType<ScaleTransform>().First();
        var shift = group.Children.OfType<TranslateTransform>().First();
        var blur = (BlurEffect)button.Effect;
        var isActiveNav = string.Equals(button.Tag as string, "Active", StringComparison.Ordinal);
        var intensity = button.IsMouseOver || isActiveNav ? 1.0 : 0.58;

        AnimatePulse(scale, ScaleTransform.ScaleXProperty, 1 + ((peakScale - 1) * intensity), 132, 0);
        AnimatePulse(scale, ScaleTransform.ScaleYProperty, 1 + (0.002 * intensity), 156, 70);
        AnimatePulse(shift, TranslateTransform.XProperty, direction * 1.1 * intensity, 112, 48);
        AnimatePulse(button, OpacityProperty, 1 - (0.026 * intensity), 136, 56);
        AnimatePulse(blur, BlurEffect.RadiusProperty, 0.50 * intensity, 170, 76);
    }

    private static void AnimatePulse(DependencyObject target, DependencyProperty property, double to, int durationMs, int beginMs)
    {
        var animation = new DoubleAnimation
        {
            To = to,
            Duration = TimeSpan.FromMilliseconds(durationMs),
            BeginTime = TimeSpan.FromMilliseconds(beginMs),
            AutoReverse = true,
            FillBehavior = FillBehavior.Stop
        };

        switch (target)
        {
            case UIElement element:
                element.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
                break;
            case Animatable animatable:
                animatable.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
                break;
        }
    }

    private void StopLaunchButtonGlitches()
    {
        foreach (var timer in _launchButtonGlitchTimers.ToArray())
        {
            timer.Stop();
        }

        _launchButtonGlitchTimers.Clear();
        _launchButtonGlitchesStarted = false;
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
        InstallUpdateButton.Content = T("installUpdate");
        UpdatesScaffoldText.Text = T("updatesScaffold");
        BackupInfoText.Text = T("backupInfoEmpty");
        RefreshBackupsButton.Content = T("refreshBackups");
        RestoreLatestBackupButton.Content = T("restoreLatestBackup");
        RestoreSelectedBackupButton.Content = T("restoreSelectedBackup");
        DeleteSelectedBackupButton.Content = T("deleteSelectedBackup");
        LiveStatusText.Text = T("ready");
        ModulesStatusText.Text = string.Join("; ", _modules.Select(module => module.Name));
        UpdateStatusText.Text = "Канал обновлений проверяется.";
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
        _miningCraftFamilySections.Clear();
        _miningCraftFamilyActionButtons.Clear();

        foreach (var module in _modules)
        {
            var card = new Border
            {
                MinHeight = 245,
                Margin = new Thickness(0, 0, 12, 4),
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

            if (module.Id.Equals("mining", StringComparison.OrdinalIgnoreCase))
            {
                BuildMiningCraftFamilyFilters(stack);
            }

            ModuleCardsPanel.Children.Add(card);
        }

        UpdateMiningRecipeFilterState();
    }

    private void BuildMiningCraftFamilyFilters(StackPanel stack)
    {
        stack.Children.Add(new TextBlock
        {
            Text = "ФИЛЬТР СЕМЕЙСТВ РЕЦЕПТОВ",
            Margin = new Thickness(0, 12, 0, 5),
            Foreground = (Brush)FindResource("SignalAmber"),
            FontSize = 11,
            FontWeight = FontWeights.Bold
        });

        var index = LoadMiningCraftFamilyIndex();
        if (index?.Families is null || index.Families.Count == 0)
        {
            QueueMiningCraftFamilyIndexRepair();
            stack.Children.Add(new TextBlock
            {
                Text = _miningCraftFamilyIndexRepairFailed
                    ? "Прогрей кэш, чтобы выбрать конкретные семейства рецептов."
                    : "Восстанавливаю фильтры семейств из локального cache.",
                Margin = new Thickness(0, 0, 0, 6),
                Foreground = (Brush)FindResource("TextSecondary"),
                TextWrapping = TextWrapping.Wrap
            });
            return;
        }

        var order = new[] { "Корабельные компоненты", "Корабельные орудия", "Добывающие лазеры", "Броня/одежда", "Оружие" };
        var groups = index.Families
            .Where(entry => !string.IsNullOrWhiteSpace(entry.OptionId))
            .GroupBy(entry => entry.Category)
            .OrderBy(group =>
            {
                var indexOf = Array.IndexOf(order, group.Key);
                return indexOf < 0 ? 999 : indexOf;
            })
            .ThenBy(group => group.Key);

        foreach (var group in groups)
        {
            var section = BuildMiningCraftFamilySection(GetMiningCraftFamilyCategoryDisplayName(group.Key), group.OrderBy(entry => entry.Subcategory).ThenBy(entry => entry.Label).ToList());
            section.Expander.IsExpanded = false;
            _miningCraftFamilySections.Add(section);
            stack.Children.Add(section.Root);
            UpdateMiningCraftFamilyCounter(section);
        }
    }

    private MiningCraftFamilySection BuildMiningCraftFamilySection(string category, List<MiningCraftFamilyEntry> entries)
    {
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = category,
            Foreground = (Brush)FindResource("SignalCyan"),
            FontSize = 12,
            FontWeight = FontWeights.Bold,
            VerticalAlignment = VerticalAlignment.Center
        });
        var counter = new TextBlock
        {
            Foreground = (Brush)FindResource("SignalAmber"),
            FontSize = 11,
            Margin = new Thickness(12, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(counter, 1);
        header.Children.Add(counter);

        var expander = new Expander
        {
            Header = header,
            Style = (Style)FindResource("CraftFamilyExpander"),
            Foreground = (Brush)FindResource("TextPrimary")
        };

        var body = new StackPanel();
        expander.Content = body;

        var search = new TextBox
        {
            Style = (Style)FindResource("LaunchPathTextBox"),
            MinHeight = 30,
            Height = 30,
            Padding = new Thickness(8, 0, 8, 0),
            VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 7),
            ToolTip = "Поиск по семейству, предметам и ресурсам"
        };
        body.Children.Add(search);

        var resetButton = new Button
        {
            Content = "сброс",
            Style = (Style)FindResource("LaunchCommandButton"),
            MinHeight = 30,
            Width = 84,
            Padding = new Thickness(8, 2, 8, 2),
            Margin = new Thickness(0, 0, 0, 7),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        body.Children.Add(resetButton);
        _miningCraftFamilyActionButtons.Add(resetButton);

        var listPanel = new StackPanel();
        var listScroll = new ScrollViewer
        {
            MaxHeight = 150,
            Padding = new Thickness(8, 6, 8, 6),
            Background = new SolidColorBrush(Color.FromArgb(0x58, 0x05, 0x0D, 0x12)),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = listPanel
        };
        body.Children.Add(listScroll);

        var section = new MiningCraftFamilySection
        {
            Root = expander,
            Expander = expander,
            Counter = counter,
            SearchBox = search,
            Entries = entries
        };

        foreach (var entry in entries)
        {
            var check = new CheckBox
            {
                Content = entry.Label,
                IsChecked = false,
                Tag = $"mining|{entry.OptionId}",
                Margin = new Thickness(0, 0, 8, 4),
                Foreground = (Brush)FindResource("TextPrimary"),
                ToolTip = BuildMiningCraftFamilyTooltip(entry)
            };
            check.Checked += (_, _) => UpdateMiningCraftFamilyCounter(section);
            check.Unchecked += (_, _) => UpdateMiningCraftFamilyCounter(section);
            listPanel.Children.Add(check);
            section.Checks.Add(check);
            _optionChecks[(string)check.Tag] = check;
        }

        search.TextChanged += (_, _) => UpdateMiningCraftFamilyVisibility(section);
        resetButton.Click += (_, _) =>
        {
            foreach (var check in section.Checks)
            {
                check.IsChecked = false;
            }
            UpdateMiningCraftFamilyCounter(section);
        };

        return section;
    }

    private static string GetMiningCraftFamilyCategoryDisplayName(string category)
    {
        return category.Equals("Оружие", StringComparison.OrdinalIgnoreCase) ? "FPS-оружие" : category;
    }

    private void UpdateMiningCraftFamilyVisibility(MiningCraftFamilySection section)
    {
        var query = section.SearchBox.Text.Trim();
        foreach (var check in section.Checks)
        {
            var optionId = ((string)check.Tag).Split('|', 2)[1];
            var entry = section.Entries.FirstOrDefault(candidate => candidate.OptionId.Equals(optionId, StringComparison.OrdinalIgnoreCase));
            if (entry is null || string.IsNullOrWhiteSpace(query))
            {
                check.Visibility = Visibility.Visible;
                continue;
            }

            var haystack = string.Join(" ", new[] { entry.Label, entry.Category, entry.Subcategory }
                .Concat(entry.Names)
                .Concat(entry.Resources));
            check.Visibility = haystack.Contains(query, StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void UpdateMiningCraftFamilyCounter(MiningCraftFamilySection section)
    {
        var selected = section.Checks.Count(check => check.IsChecked == true);
        section.Counter.Text = $"{selected}/{section.Checks.Count}";
    }

    private static string BuildMiningCraftFamilyTooltip(MiningCraftFamilyEntry entry)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(entry.Subcategory))
        {
            parts.Add(entry.Subcategory);
        }
        if (entry.Names.Count > 0)
        {
            parts.Add(string.Join(", ", entry.Names.Take(8)) + (entry.Names.Count > 8 ? "..." : ""));
        }
        if (entry.Resources.Count > 0)
        {
            parts.Add("Ресурсы: " + string.Join(", ", entry.Resources));
        }

        return string.Join(Environment.NewLine, parts);
    }

    private void QueueMiningCraftFamilyIndexRepair()
    {
        if (_miningCraftFamilyIndexRepairQueued || _miningCraftFamilyIndexRepairFailed)
        {
            return;
        }

        _miningCraftFamilyIndexRepairQueued = true;
        Dispatcher.BeginInvoke(new Action(async () => await RepairMiningCraftFamilyIndexAsync()), DispatcherPriority.Background);
    }

    private async Task RepairMiningCraftFamilyIndexAsync()
    {
        await Task.Delay(250);
        if (LoadMiningCraftFamilyIndex()?.Families.Count > 0)
        {
            return;
        }

        AddMetricLog("Фильтры рецептов: восстанавливаю индекс из локального cache.");
        var repaired = await TryRepairMiningCraftFamilyIndexFromWikiCacheAsync();
        if (!repaired || (LoadMiningCraftFamilyIndex()?.Families.Count ?? 0) <= 0)
        {
            _miningCraftFamilyIndexRepairFailed = true;
            AddMetricLog("Фильтры рецептов: локальный wiki cache не найден. Прогрей кэш.");
            SetWarmCacheAttention(true);
            BuildModuleCards();
            return;
        }

        _miningCraftFamilyIndexRepairFailed = false;
        AddMetricLog("Фильтры рецептов: индекс cache восстановлен.");
        RebuildModuleCardsPreservingSelection();
    }

    private async Task<bool> TryRepairMiningCraftFamilyIndexFromWikiCacheAsync()
    {
        var scriptPath = Path.Combine(Path.GetTempPath(), $"sc-mod-family-index-{Guid.NewGuid():N}.ps1");
        var script = """
param([string]$RootPath)
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $RootPath 'modules\mining\module.ps1'
. $modulePath
$cacheDir = Join-Path $RootPath 'modules\mining\cache'
$cacheFile = Get-ChildItem -LiteralPath $cacheDir -Filter 'wiki-blueprints-*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($null -eq $cacheFile) {
    Write-Host 'NO_WIKI_CACHE'
    exit 2
}
$cache = Get-Content -LiteralPath $cacheFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $cache.PSObject.Properties['data']) {
    throw 'wiki blueprint cache has no data'
}
$cacheKey = [string]$cache.cacheKey
if ([string]::IsNullOrWhiteSpace($cacheKey)) {
    $cacheKey = $cacheFile.BaseName -replace '^wiki-blueprints-', ''
}
$indexPath = Write-SCMiningCraftFamilyIndexCache -CacheKey $cacheKey -Blueprints @($cache.data)
Write-Host "FAMILY_INDEX:$indexPath"
""";

        try
        {
            File.WriteAllText(scriptPath, script, new UTF8Encoding(false));
            var args = new StringBuilder();
            args.Append("-NoProfile -ExecutionPolicy Bypass -File ");
            args.Append(Quote(scriptPath));
            args.Append(" -RootPath ");
            args.Append(Quote(_rootPath));

            var result = await RunProcessAsync("powershell.exe", args.ToString(), timeout: TimeSpan.FromSeconds(45));
            return result.ExitCode == 0 && result.Output.Contains("FAMILY_INDEX:", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
        finally
        {
            TryDelete(scriptPath);
        }
    }

    private void RebuildModuleCardsPreservingSelection()
    {
        var selected = GetSelectedOptions();
        BuildModuleCards();
        foreach (var pair in _optionChecks)
        {
            var parts = pair.Key.Split('|', 2);
            if (parts.Length != 2 || !selected.TryGetValue(parts[0], out var options))
            {
                continue;
            }

            pair.Value.IsChecked = options.Contains(parts[1], StringComparer.OrdinalIgnoreCase);
        }

        UpdateMiningRecipeFilterState();
        if (_launchButtonGlitchesStarted)
        {
            StopLaunchButtonGlitches();
            StartLaunchButtonGlitches();
        }
    }

    private MiningCraftFamilyIndex? LoadMiningCraftFamilyIndex()
    {
        var cacheDir = Path.Combine(_rootPath, "modules", "mining", "cache");
        if (!Directory.Exists(cacheDir))
        {
            return null;
        }

        var file = Directory
            .EnumerateFiles(cacheDir, "craft-family-index-*.json", SearchOption.TopDirectoryOnly)
            .Select(path => new FileInfo(path))
            .OrderByDescending(info => info.LastWriteTimeUtc)
            .FirstOrDefault();
        if (file is null)
        {
            return null;
        }

        try
        {
            var json = File.ReadAllText(file.FullName, Encoding.UTF8);
            return JsonSerializer.Deserialize<MiningCraftFamilyIndex>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
        }
        catch
        {
            return null;
        }
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

        foreach (var section in _miningCraftFamilySections)
        {
            section.Root.IsEnabled = hasMiningMethod;
            section.Root.Opacity = hasMiningMethod ? 1.0 : 0.42;
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
        if (!enabled)
        {
            ClearWarmCacheAttentionVisual();
            return;
        }

        ApplyWarmCacheAttentionVisual();
    }

    private void ApplyWarmCacheAttentionVisual()
    {
        WarmCacheButton.ApplyTemplate();
        var backgroundBrush = CreatePulsingBrush(
            Color.FromArgb(0xB8, 0x1B, 0x1E, 0x18),
            Color.FromArgb(0xC2, 0x2A, 0x27, 0x18),
            2600);
        var borderBrush = CreatePulsingBrush(
            Color.FromRgb(0x66, 0x55, 0x35),
            Color.FromRgb(0xA8, 0x82, 0x3E),
            3000);
        WarmCacheButton.Background = backgroundBrush;
        WarmCacheButton.BorderBrush = borderBrush;
        WarmCacheButton.ClearValue(Control.ForegroundProperty);

        if (WarmCacheButton.Template.FindName("Body", WarmCacheButton) is Border body)
        {
            var bodyBackgroundBrush = CreatePulsingBrush(
                Color.FromArgb(0xB8, 0x1B, 0x1E, 0x18),
                Color.FromArgb(0xC2, 0x2A, 0x27, 0x18),
                2600);
            var bodyBorderBrush = CreatePulsingBrush(
                Color.FromRgb(0x66, 0x55, 0x35),
                Color.FromRgb(0xA8, 0x82, 0x3E),
                3000);
            body.Background = bodyBackgroundBrush;
            body.BorderBrush = bodyBorderBrush;
        }

        SetTemplateOpacity(WarmCacheButton, "WarpFrame", true, 0.24);
        SetTemplateOpacity(WarmCacheButton, "PlateGhosts", true, 0.10);
        SetTemplateOpacity(WarmCacheButton, "Scanlines", true, 0.12);
        SetTemplateOpacity(WarmCacheButton, "TearLayer", true, 0.08);
        SetTemplateOpacity(WarmCacheButton, "AmberPlateGhost", true, 0.06);
        SetTemplateOpacity(WarmCacheButton, "FrameAmberRip", true, 0.04);
        SetTemplateOpacity(WarmCacheButton, "TearRightBorderAmber", true, 0.04);
    }

    private void ClearWarmCacheAttentionVisual()
    {
        WarmCacheButton.ApplyTemplate();
        StopBrushPulse(WarmCacheButton.Background);
        StopBrushPulse(WarmCacheButton.BorderBrush);
        WarmCacheButton.ClearValue(Control.BackgroundProperty);
        WarmCacheButton.ClearValue(Control.BorderBrushProperty);
        WarmCacheButton.ClearValue(Control.ForegroundProperty);

        if (WarmCacheButton.Template.FindName("Body", WarmCacheButton) is Border body)
        {
            StopBrushPulse(body.Background);
            StopBrushPulse(body.BorderBrush);
            body.ClearValue(Border.BackgroundProperty);
            body.ClearValue(Border.BorderBrushProperty);
        }

        SetTemplateOpacity(WarmCacheButton, "WarpFrame", false, 0);
        SetTemplateOpacity(WarmCacheButton, "PlateGhosts", false, 0);
        SetTemplateOpacity(WarmCacheButton, "Scanlines", false, 0);
        SetTemplateOpacity(WarmCacheButton, "TearLayer", false, 0);
        SetTemplateOpacity(WarmCacheButton, "AmberPlateGhost", false, 0);
        SetTemplateOpacity(WarmCacheButton, "FrameAmberRip", false, 0);
        SetTemplateOpacity(WarmCacheButton, "TearRightBorderAmber", false, 0);
    }

    private static SolidColorBrush CreatePulsingBrush(Color from, Color to, int durationMs)
    {
        var brush = new SolidColorBrush(from);
        StartColorPulse(brush, to, durationMs);
        return brush;
    }

    private static void StartColorPulse(SolidColorBrush brush, Color to, int durationMs)
    {
        if (brush.IsFrozen)
        {
            return;
        }

        var animation = new ColorAnimation
        {
            To = to,
            Duration = TimeSpan.FromMilliseconds(durationMs),
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
        };

        brush.BeginAnimation(SolidColorBrush.ColorProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }

    private static void StopBrushPulse(Brush brush)
    {
        if (brush is SolidColorBrush { IsFrozen: false } solidColorBrush)
        {
            solidColorBrush.BeginAnimation(SolidColorBrush.ColorProperty, null);
        }
    }

    private static string ShortPath(string path)
    {
        return string.IsNullOrWhiteSpace(path) ? "" : Path.GetFileName(path);
    }

    private void OpenLocalLogLink(object sender, RequestNavigateEventArgs e)
    {
        try
        {
            if (e.Uri.IsFile)
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
            else
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = e.Uri.AbsoluteUri,
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
        SetJournalState("ХЬЮСТОН, У НАС ПРОБЛЕМА: " + text, isError: true);
        AddErrorLog("ХЬЮСТОН, У НАС ПРОБЛЕМА: " + text);
    }

    private void SetJournalState(string text, bool isError = false)
    {
        _journalIsError = isError;
        SafeBoundaryText.Text = text;
        SafeBoundaryText.Foreground = isError ? (Brush)FindResource("SignalRed") : (Brush)FindResource("TextSecondary");
        LogFrameBody.BorderBrush = isError ? (Brush)FindResource("SignalRed") : (Brush)FindResource("LineDim");
    }

    private void GlitchPanelMouseEnter(object sender, MouseEventArgs e)
    {
        switch (sender)
        {
            case FrameworkElement { Name: "BackupListGlitchFrame" }:
                SetGlitchPanelHover(
                    BackupListFrameBody,
                    BackupListWarpFrame,
                    BackupListScanlines,
                    BrushFromHex("#5A66E8FF"),
                    0.50,
                    0.20);
                break;
            case FrameworkElement { Name: "LogGlitchFrame" }:
                SetGlitchPanelHover(
                    LogFrameBody,
                    LogWarpFrame,
                    LogScanlines,
                    _journalIsError ? (Brush)FindResource("SignalRed") : BrushFromHex("#5A66E8FF"),
                    0.50,
                    0.20);
                break;
        }
    }

    private void GlitchPanelMouseLeave(object sender, MouseEventArgs e)
    {
        switch (sender)
        {
            case FrameworkElement { Name: "BackupListGlitchFrame" }:
                SetGlitchPanelHover(
                    BackupListFrameBody,
                    BackupListWarpFrame,
                    BackupListScanlines,
                    (Brush)FindResource("LineDim"),
                    0,
                    0.10);
                break;
            case FrameworkElement { Name: "LogGlitchFrame" }:
                SetGlitchPanelHover(
                    LogFrameBody,
                    LogWarpFrame,
                    LogScanlines,
                    _journalIsError ? (Brush)FindResource("SignalRed") : (Brush)FindResource("LineDim"),
                    0,
                    0.10);
                break;
        }
    }

    private static void SetGlitchPanelHover(Border body, UIElement warpFrame, UIElement scanlines, Brush borderBrush, double warpOpacity, double scanlineOpacity)
    {
        body.BorderBrush = borderBrush;
        AnimateHold(warpFrame, OpacityProperty, warpOpacity, 140);
        AnimateHold(scanlines, OpacityProperty, scanlineOpacity, 140);
    }

    private static Brush BrushFromHex(string value) => (Brush)new BrushConverter().ConvertFromString(value)!;

    private static void AnimateHold(UIElement target, DependencyProperty property, double to, int durationMs)
    {
        var animation = new DoubleAnimation
        {
            To = to,
            Duration = TimeSpan.FromMilliseconds(durationMs),
            FillBehavior = FillBehavior.HoldEnd
        };

        target.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
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
            button.Tag = null;
            button.ClearValue(Control.BackgroundProperty);
            button.ClearValue(Control.BorderBrushProperty);
            button.ClearValue(Control.ForegroundProperty);
            ApplyNavActiveVisual(button, false);
        }

        var active = OverviewNavButton;
        if (visiblePanel == ModulesPanel) active = ModulesNavButton;
        else if (visiblePanel == BackupPanel) active = RestoreBackupButton;

        active.Tag = "Active";
        ApplyNavActiveVisual(active, true);
    }

    private void ApplyNavActiveVisual(Button button, bool isActive)
    {
        button.ApplyTemplate();

        if (button.Template.FindName("NavBody", button) is System.Windows.Shapes.Shape body)
        {
            if (isActive)
            {
                body.Fill = (Brush)new BrushConverter().ConvertFromString("#B8152D36")!;
                body.Stroke = (Brush)new BrushConverter().ConvertFromString("#5A66E8FF")!;
            }
            else
            {
                body.ClearValue(System.Windows.Shapes.Shape.FillProperty);
                body.ClearValue(System.Windows.Shapes.Shape.StrokeProperty);
            }
        }

        SetTemplateOpacity(button, "NavWarpFrame", isActive, 0.52);
        SetTemplateOpacity(button, "NavPlateGhosts", isActive, 0.16);
        SetTemplateOpacity(button, "NavScanlines", isActive, 0.18);
        SetTemplateOpacity(button, "NavTearLayer", isActive, 0.20);

        if (isActive)
        {
            button.Foreground = (Brush)FindResource("SignalCyan");
        }
        else
        {
            button.ClearValue(Control.ForegroundProperty);
        }
    }

    private static void SetTemplateOpacity(Button button, string name, bool isActive, double opacity)
    {
        if (button.Template.FindName(name, button) is UIElement element)
        {
            if (isActive)
            {
                element.Opacity = opacity;
            }
            else
            {
                element.ClearValue(OpacityProperty);
            }
        }
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
                        _miningCraftFamilyIndexRepairQueued = false;
                        _miningCraftFamilyIndexRepairFailed = false;
                        RebuildModuleCardsPreservingSelection();
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
            ? "ХЬЮСТОН, У НАС ПРОБЛЕМА: источник или global.ini недоступен."
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
        SetJournalState(hasFailure ? "ХЬЮСТОН, У НАС ПРОБЛЕМА: cache не прогрет." : "Cache прогрет. Можно применять в LIVE.", hasFailure);
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
        SetJournalState(hasConflicts ? "ХЬЮСТОН, У НАС ПРОБЛЕМА: есть конфликт модулей." : cleanMessage, hasConflicts);
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

    private async Task CheckUpdatesAsync()
    {
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
            var message = "GitHub временно недоступен: " + ShortError(ex.Message);
            UpdatesScaffoldText.Foreground = (Brush)FindResource("SignalAmber");
            UpdatesScaffoldText.Text = message;
            UpdateStatusText.Text = "Канал обновлений недоступен.";
            SetJournalState("Канал обновлений временно недоступен.");
            AddMetricLog(message);
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

public sealed class MiningCraftFamilySection
{
    public FrameworkElement Root { get; set; } = null!;
    public Expander Expander { get; set; } = null!;
    public TextBlock Counter { get; set; } = null!;
    public TextBox SearchBox { get; set; } = null!;
    public List<MiningCraftFamilyEntry> Entries { get; set; } = new();
    public List<CheckBox> Checks { get; } = new();
}

public sealed class MiningCraftFamilyIndex
{
    [JsonPropertyName("cacheKey")]
    public string CacheKey { get; set; } = "";

    [JsonPropertyName("families")]
    public List<MiningCraftFamilyEntry> Families { get; set; } = new();
}

public sealed class MiningCraftFamilyEntry
{
    [JsonPropertyName("optionId")]
    public string OptionId { get; set; } = "";

    [JsonPropertyName("category")]
    public string Category { get; set; } = "";

    [JsonPropertyName("subcategory")]
    public string Subcategory { get; set; } = "";

    [JsonPropertyName("familyKey")]
    public string FamilyKey { get; set; } = "";

    [JsonPropertyName("label")]
    public string Label { get; set; } = "";

    [JsonPropertyName("defaultSelected")]
    public bool DefaultSelected { get; set; }

    [JsonPropertyName("names")]
    public List<string> Names { get; set; } = new();

    [JsonPropertyName("resources")]
    public List<string> Resources { get; set; } = new();
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
