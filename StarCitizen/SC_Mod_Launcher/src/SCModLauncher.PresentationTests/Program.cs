using System.Reflection;
using SCModLauncher;

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
