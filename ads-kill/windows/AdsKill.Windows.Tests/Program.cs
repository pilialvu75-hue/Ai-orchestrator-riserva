using AdsKill.Windows;
using System.Text;

static void Verify(bool ok, string reason)
{
    if (!ok) throw new Exception("FAILED: " + reason);
    Console.WriteLine("PASS: " + reason);
}

string original = "# original entry\r\n127.0.0.1 localhost\r\n";
string protectedHosts = HostsSections.Enable(original);
Verify(HostsSections.IsEnabled(protectedHosts), "enable protection");
Verify(protectedHosts.Contains("0.0.0.0 ad.doubleclick.net"), "IPv4 mapping");
Verify(protectedHosts.Contains(":: ad.doubleclick.net"), "IPv6 mapping");
Verify(HostsSections.Enable(protectedHosts) == protectedHosts, "idempotent enable");
Verify(HostsSections.Disable(protectedHosts) == original, "preserve original and disable");
Verify(HostsSections.Disable(original) == original, "idempotent disable");

string userChange = protectedHosts.Replace(
    "# original entry", "# modified by another app");
Verify(HostsSections.Disable(userChange).StartsWith("# modified by another app"),
    "preserve external changes");

bool malformedRejected = false;
try { HostsSections.Disable(original + HostsSections.StartMarker + "\n"); }
catch (InvalidOperationException) { malformedRejected = true; }
Verify(malformedRejected, "reject corrupt marker section");

bool duplicateRejected = false;
try { HostsSections.Enable(protectedHosts + HostsSections.StartMarker + "\n" + HostsSections.EndMarker + "\n"); }
catch (InvalidOperationException) { duplicateRejected = true; }
Verify(duplicateRejected, "reject duplicate marker sections");

byte[] utf8 = Encoding.UTF8.GetBytes("# Café by another app\r\n");
Verify(HostsSections.Encode(HostsSections.Disable(HostsSections.Enable(
    HostsSections.Decode(utf8)))).SequenceEqual(utf8), "round-trip original UTF-8 bytes");

bool utf16Rejected = false;
try { HostsSections.Decode(new byte[] { 0xff, 0xfe, 0x41, 0x00 }); }
catch (InvalidOperationException) { utf16Rejected = true; }
Verify(utf16Rejected, "reject UTF-16 to prevent corruption");

Console.WriteLine("Ads Kill Windows HOSTS section tests OK.");
