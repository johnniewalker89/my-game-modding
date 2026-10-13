using System.Reflection;
using SCModLauncher;
using System.Runtime.CompilerServices;
using System.Text;
using System.Windows.Controls;

var owner = typeof(MainWindow);
var statusMethod = owner.GetMethod("GetPreflightStatus", BindingFlags.NonPublic | BindingFlags.Static)!;
void Check(string log, bool blocked, bool stale, bool fallback, bool requireGlobal = true)
{
    var status = statusMethod.Invoke(null, new object[] { log, requireGlobal })!;
    bool Read(string name) => (bool)status.GetType().GetProperty(name)!.GetValue(status)!;
    if (Read("HasBlockingFailure") != blocked || Read("HasCacheStale") != stale || Read("HasDataFallback") != fallback)
        throw new Exception("Incorrect actual GUI preflight status: " + log);
}
Check("global.ini: OK\nCache mining item passports: HIT; age: 1h", false, false, false);
Check("global.ini: OK\nSource Wiki item passports: FAIL; no LIVE data\nCache mining item passports: FALLBACK; age: 31d 9h; source version: 4.10.0", false, true, true);
Check("global.ini: OK\nCache mining item passports: FALLBACK; age: 1d", false, false, true);
Check("global.ini: OK\nCache mining data: STALE; age: 8d", false, true, false);
Check("global.ini: OK\nCache mining data: MISSING", true, false, false);
Check("global.ini: OK\nSource SCMDB data: FAIL", true, false, false);
Check("global.ini: MISSING\nCache mining data: HIT; age: 1h", false, false, false, false);
var aliases = owner.GetMethod("ExpandSavedOptionAliases", BindingFlags.NonPublic | BindingFlags.Static)!;
var choices = new Dictionary<string,string>
{
    ["variant:Arrowhead\u00C2 Sniper Rifle"] = "variant:Arrowhead Sniper Rifle",
    ["variant:P8-SC\u00C2 SMG"] = "variant:P8-SC SMG",
    ["armor:Lynx\u00C2"] = "armor:Lynx",
    ["armor:Oracle\u00C2"] = "armor:Oracle",
    ["exact:Hellion\u00C2\u00A0Scattergun"] = "exact:Hellion Scattergun",
    ["exact:F55 Shadowflux LMG"] = "variant:F55 LMG",
    ["armor:Monolith-Shadowflux"] = "armor:Monolith",
    ["exact:YellowJacket GT-210 Gatling"] = "weapon:GT Gatling",
    ["exact:Scorpion GT-215 Gatling"] = "weapon:GT Gatling",
    ["exact:Mantis GT-220 Gatling"] = "weapon:GT Gatling",
    ["armor:Arden-CL"] = "armor:Arden",
    ["armor:Arden-SL"] = "armor:Arden",
    ["armor:Aztalan Galena"] = "armor:Aztalan",
    ["armor:Aztalan Tamarack"] = "armor:Aztalan",
    ["exact:Coda Pistol (Modified)"] = "variant:Coda Pistol",
    ["variant:Salvo Esteban Frag Pistol"] = "variant:Salvo Frag Pistol"
};
foreach (var prefix in new[] { "craftFamily", "questCraftFamily" })
foreach (var pair in choices)
{
    var input = new[] { prefix + "|Category|Subcategory|" + pair.Key };
    var result = (IEnumerable<string>)aliases.Invoke(null, new object[] { input })!;
    if (!result.Contains(prefix + "|Category|Subcategory|" + pair.Value)) throw new Exception("GUI dropped saved choice: " + input[0]);
}
Console.WriteLine("PASS: compiled GUI fallback ages, source failure/missing states and saved choice migration");
foreach (var prefix in new[] { "craftFamily", "questCraftFamily" })
{
    var input = new[] { prefix + "|Корабельные орудия|Баллистика|exact:Thlilye Laser Gatling" };
    var result = (IEnumerable<string>)aliases.Invoke(null, new object[] { input })!;
    if (!result.Contains(prefix + "|Корабельные орудия|Энергетика|exact:Thlilye Laser Gatling"))
        throw new Exception("GUI dropped the moved laser weapon choice.");
}
Console.WriteLine("PASS: compiled GUI preserves the moved Thlilye choice in both modules");
foreach(var prefix in new[] { "craftFamily", "questCraftFamily" })
foreach(var key in new[] { "exact:BRVS Repeater", "exact:CVSA Cannon", "exact:Havoc Scattergun", "exact:Hellion Scattergun", "exact:Predator Scattergun" })
{
    var input = new[] { prefix + "|Корабельные орудия|Энергетика|" + key };
    var result = (IEnumerable<string>)aliases.Invoke(null, new object[] { input })!;
    if(!result.Contains(prefix + "|Корабельные орудия|Баллистика|" + key)) throw new Exception("GUI dropped moved ballistic choice.");
}
Console.WriteLine("PASS: compiled GUI preserves merged armor/pistols and moved ballistic choices");

Exception? menuFailure = null;
var menuThread = new Thread(() =>
{
    try
    {
        var window = (MainWindow)RuntimeHelpers.GetUninitializedObject(owner);
        owner.GetField("_rootPath", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window, @"C:\isolated\launcher");
        owner.GetField("LivePathBox", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(window, new TextBox { Text = @"C:\isolated\LIVE" });
        var method = owner.GetMethod("BuildBackendArguments", BindingFlags.NonPublic | BindingFlags.Instance)!;
        var modeType = method.GetParameters()[0].ParameterType;
        var currentVersion = (string)owner.GetField("CurrentLauncherVersion", BindingFlags.NonPublic | BindingFlags.Static)!.GetRawConstantValue()!;
        foreach (var mode in new[] { "DryRun", "LiveApply", "Preflight", "CachePreflight", "WarmCache" })
        {
            var args = method.Invoke(window, new object?[] { Enum.Parse(modeType, mode), null })!.ToString()!;
            var shouldStamp = mode is "DryRun" or "LiveApply";
            if (args.Contains(" -LauncherVersion ") != shouldStamp || (shouldStamp && !args.Contains(" -LauncherVersion \"" + currentVersion + "\"")))
                throw new Exception("GUI passed an incorrect menu version for " + mode + ": " + args);
        }
        var patch = owner.GetMethod("PatchGameMenuVersionBytes", BindingFlags.NonPublic | BindingFlags.Static)!;
        var input = Encoding.UTF8.GetBytes("Frontend_PU_Version,P=SC Mod Launcher: 2.1.7 \\nРусификатор RuSC: 4.10.2-v128\r\n");
        var patched = (byte[])patch.Invoke(null, new object[] { input, "4.10.2-v128" })!;
        if (!Encoding.UTF8.GetString(patched).Contains("SC Mod Launcher: " + currentVersion + " \\nРусификатор RuSC: 4.10.2-v128"))
            throw new Exception("RuSC installation and apply use different menu versions.");
    }
    catch (Exception ex) { menuFailure = ex; }
});
menuThread.SetApartmentState(ApartmentState.STA);
menuThread.Start();
menuThread.Join();
if (menuFailure != null) throw new Exception("Compiled GUI menu version contract failed.", menuFailure);
Console.WriteLine("PASS: compiled GUI passes current menu version only to dry-run/apply and agrees with RuSC installation");
