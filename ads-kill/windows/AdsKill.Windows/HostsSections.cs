using System.Text;
using System.Text.RegularExpressions;

namespace AdsKill.Windows;

/// <summary>
/// Side-effect-free HOSTS block editor. Windows HOSTS entries match exact
/// domains, not suffix patterns. Preserve original bytes through Latin1.
/// </summary>
public static class HostsSections
{
    public const string StartMarker = "# ADS-KILL BEGIN v1";
    public const string EndMarker = "# ADS-KILL END v1";

    private static readonly Regex StartLine = new(
        @"(?m)^# ADS-KILL BEGIN v1\r?$", RegexOptions.Compiled);
    private static readonly Regex EndLine = new(
        @"(?m)^# ADS-KILL END v1\r?$", RegexOptions.Compiled);

    public static readonly string[] Domains =
    {
        "ad.doubleclick.net",
        "googleads.g.doubleclick.net",
        "stats.g.doubleclick.net",
        "securepubads.g.doubleclick.net",
        "pubads.g.doubleclick.net",
        "pagead2.googlesyndication.com",
        "tpc.googlesyndication.com",
        "partner.googleadservices.com",
        "www.googleadservices.com",
        "ads.mopub.com",
        "ads.unity3d.com",
        "unityads.unity3d.com",
        "ads.applovin.com",
        "rt.applovin.com",
        "d.applvn.com",
        "ads.vungle.com",
        "api.vungle.com",
        "ads.inmobi.com",
        "sdk.inmobi.com",
        "ads.chartboost.com",
        "live.chartboost.com",
        "ads.adcolony.com",
        "ads.smaato.net",
        "ads.tapjoy.com",
        "ads.startappservice.com",
        "track.adform.net",
        "ads.pubmatic.com",
        "ads.rubiconproject.com",
        "ib.adnxs.com",
        "aax.amazon-adsystem.com"
    };

    public static string Decode(byte[] data)
    {
        if (data.Length >= 2 &&
            ((data[0] == 0xff && data[1] == 0xfe) ||
             (data[0] == 0xfe && data[1] == 0xff)))
            throw new InvalidOperationException("Il file HOSTS è UTF-16: formato non modificato per sicurezza.");

        if (Array.IndexOf(data, (byte) 0) >= 0)
            throw new InvalidOperationException("Il file HOSTS contiene byte NUL: nessuna modifica effettuata.");

        return Encoding.Latin1.GetString(data);
    }

    public static byte[] Encode(string text) => Encoding.Latin1.GetBytes(text);

    public static bool IsEnabled(string contents)
    {
        GetMarkerBounds(contents, out var start, out var end);
        return start >= 0 && end >= 0;
    }

    public static string Enable(string contents)
    {
        if (IsEnabled(contents)) return contents;
        var eol = contents.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var text = contents;
        if (text.Length > 0 && !text.EndsWith("\n", StringComparison.Ordinal)) text += eol;
        text += StartMarker + eol;
        foreach (var domain in Domains)
        {
            text += "0.0.0.0 " + domain + eol;
            text += ":: " + domain + eol;
        }
        text += EndMarker + eol;
        return text;
    }

    public static string Disable(string contents)
    {
        GetMarkerBounds(contents, out var start, out var end);
        if (start < 0) return contents;

        var final = end;
        if (final < contents.Length && contents[final] == '\n') final++;
        return contents.Remove(start, final - start);
    }

    private static void GetMarkerBounds(string contents, out int start, out int end)
    {
        var starts = StartLine.Matches(contents);
        var ends = EndLine.Matches(contents);
        if (starts.Count == 0 && ends.Count == 0)
        {
            start = -1;
            end = -1;
            return;
        }
        if (starts.Count != 1 || ends.Count != 1 ||
            starts[0].Index >= ends[0].Index)
            throw new InvalidOperationException(
                "Marcatori Ads Kill incompleti o duplicati nel file HOSTS. Nessuna modifica: controllare manualmente.");

        start = starts[0].Index;
        end = ends[0].Index + ends[0].Length;
    }
}
