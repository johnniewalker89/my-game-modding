using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace SCModLauncherRoot;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var rootPath = AppContext.BaseDirectory;
        var launcherPath = Path.Combine(rootPath, "app", "SCModLauncher.exe");

        if (!File.Exists(launcherPath))
        {
            MessageBox.Show(
                "app\\SCModLauncher.exe не найден. Распакуй архив лаунчера целиком.",
                "SC Mod Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = launcherPath,
            WorkingDirectory = Path.GetDirectoryName(launcherPath) ?? rootPath,
            UseShellExecute = true,
        };

        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        Process.Start(startInfo);
        return 0;
    }
}
