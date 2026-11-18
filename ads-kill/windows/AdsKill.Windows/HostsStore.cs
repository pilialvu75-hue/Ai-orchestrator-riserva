using System.Diagnostics;

namespace AdsKill.Windows;

public readonly record struct ChangeResult(bool Changed, string BackupPath, string? DnsWarning);

/// <summary>
/// Edits only Ads Kill's marked HOSTS block, with a byte-for-byte backup and
/// atomic replacement. UAC elevation is required, never silently bypassed.
/// </summary>
public static class HostsStore
{
    public static string HostsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.System),
        "drivers", "etc", "hosts");

    public static string BackupDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "AdsKill", "backups");

    public static bool IsProtected() =>
        HostsSections.IsEnabled(HostsSections.Decode(File.ReadAllBytes(HostsPath)));

    public static ChangeResult SetProtected(bool enable)
    {
        var path = HostsPath;
        var previous = HostsSections.Decode(File.ReadAllBytes(path));
        var next = enable ? HostsSections.Enable(previous) : HostsSections.Disable(previous);
        if (next == previous) return new ChangeResult(false, "", null);

        Directory.CreateDirectory(BackupDirectory);
        var backup = Path.Combine(BackupDirectory,
            $"hosts-{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}.bak");
        File.Copy(path, backup, overwrite: false);

        var staging = path + ".adskill-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(staging, HostsSections.Encode(next));
            File.Replace(staging, path, null, ignoreMetadataErrors: true);
        }
        finally
        {
            try { if (File.Exists(staging)) File.Delete(staging); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        return new ChangeResult(true, backup, FlushDnsWarning());
    }

    private static string? FlushDnsWarning()
    {
        try
        {
            using var proc = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "ipconfig.exe"),
                Arguments = "/flushdns",
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (proc == null || !proc.WaitForExit(6000) || proc.ExitCode != 0)
                return "Cache DNS non aggiornata. Riavvia il browser se necessario.";
            return null;
        }
        catch (Exception ex)
        {
            return "Cache DNS non aggiornata: " + ex.Message;
        }
    }
}
