// AIVEXUS Windows pre-update snapshot and recovery prototype.
// .NET Framework 4.5.1 compatible (Windows 8.1); no external dependencies.
// IMPORTANT: This tool is NOT an installer or a production release yet.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

internal static class AivexusRecovery
{
    const string Header = "AIVEXUS_ROLLBACK_V1";
    const string Pointer = "latest.txt";
    static readonly StringComparison Cmp = StringComparison.OrdinalIgnoreCase;

    static int Main(string[] args)
    {
        try
        {
            var settings = Parse(args);
            string mode = Get(settings, "mode");
            string store = Path.GetFullPath(Get(settings, "store")).TrimEnd('\\');
            string app = Path.GetFullPath(Get(settings, "app")).TrimEnd('\\');
            string data = settings.ContainsKey("data") && settings["data"].Length > 0
                ? Path.GetFullPath(settings["data"]).TrimEnd('\\') : null;
            if (string.Equals(mode, "backup", Cmp))
                Backup(app, data, store, true);
            else if (string.Equals(mode, "verify", Cmp))
                VerifyCurrent(store, app, data);
            else if (string.Equals(mode, "restore", Cmp))
                Restore(app, data, store);
            else if (string.Equals(mode, "accept", Cmp))
            {
                AssertNotRunning();
                VerifyCurrent(store, app, data);
                File.Delete(Path.Combine(store, Pointer));
                Console.WriteLine("Recovery checkpoint accepted. Historic snapshot retained.");
            }
            else throw new InvalidOperationException("Unknown recovery operation.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("AIVEXUS recovery: " + ex.Message);
            return 1;
        }
    }

    static Dictionary<string, string> Parse(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if ((args.Length & 1) != 0) throw new ArgumentException("Named --key value pairs required.");
        for (int i = 0; i < args.Length; i += 2)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException("Unknown option: " + args[i]);
            string key = args[i].Substring(2);
            if (!new[] { "mode", "store", "app", "data" }.Contains(key))
                throw new ArgumentException("Unsupported option: " + key);
            if (result.ContainsKey(key)) throw new ArgumentException("Duplicate option: " + key);
            result.Add(key, args[i + 1]);
        }
        return result;
    }

    static string Get(Dictionary<string, string> values, string key)
    {
        string value;
        if (!values.TryGetValue(key, out value) || string.IsNullOrWhiteSpace(value))
            throw new ArgumentException("Missing --" + key);
        return value;
    }

    static void AssertNotRunning()
    {
        Process[] running = Process.GetProcessesByName("ai_orchestrator");
        try
        {
            if (running.Length > 0)
                throw new InvalidOperationException(
                    "Close AI Orchestrator normally before backing up or restoring it.");
        }
        finally { foreach (Process p in running) p.Dispose(); }
    }

    static bool IsWithin(string parent, string path)
    {
        string prefix = parent.TrimEnd('\\') + "\\";
        return path.StartsWith(prefix, Cmp);
    }

    static void ValidatePaths(string app, string data, string store)
    {
        if (app == store || IsWithin(app, store) || IsWithin(store, app))
            throw new InvalidOperationException("Recovery folder must be separate from app installation.");
        if (data != null &&
            (data == store || IsWithin(data, store) || IsWithin(store, data)))
            throw new InvalidOperationException("Recovery folder must be separate from user data.");
        if (data != null &&
            (data == app || IsWithin(data, app) || IsWithin(app, data)))
            throw new InvalidOperationException("Application and data roots must not overlap.");
    }

    static void SecureStore(string store)
    {
        Directory.CreateDirectory(store);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        var sid = WindowsIdentity.GetCurrent().User;
        var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (SecurityIdentifier principal in new[] {
            sid,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
        {
            security.AddAccessRule(new FileSystemAccessRule(
                principal, FileSystemRights.FullControl, inheritance,
                PropagationFlags.None, AccessControlType.Allow));
        }
        Directory.SetAccessControl(store, security);
    }

    static void RequireSafeTree(string root)
    {
        if (!Directory.Exists(root)) return;
        var dirs = new Stack<DirectoryInfo>();
        dirs.Push(new DirectoryInfo(root));
        while (dirs.Count > 0)
        {
            DirectoryInfo dir = dirs.Pop();
            if ((dir.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Reparse-point directory in snapshot input: " + dir.Name);
            foreach (FileSystemInfo child in dir.GetFileSystemInfos())
            {
                if ((child.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Reparse-point file in snapshot input: " + child.Name);
                var next = child as DirectoryInfo;
                if (next != null) dirs.Push(next);
            }
        }
    }

    static IEnumerable<FileInfo> Files(string root)
    {
        if (!Directory.Exists(root)) return Enumerable.Empty<FileInfo>();
        return new DirectoryInfo(root).EnumerateFiles("*", SearchOption.AllDirectories);
    }

    static string Digest(string file)
    {
        using (FileStream stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    static string Encode(string text) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(text)); }
    static string Decode(string text) { return Encoding.UTF8.GetString(Convert.FromBase64String(text)); }
    static string SnapshotId()
    {
        return "snapshot-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss") + "-" +
            Guid.NewGuid().ToString("N").Substring(0, 12);
    }

    static string Backup(string app, string data, string store, bool updateLatest)
    {
        AssertNotRunning();
        ValidatePaths(app, data, store);
        if (!File.Exists(Path.Combine(app, "ai_orchestrator.exe")))
            throw new InvalidOperationException("No installed AI Orchestrator executable: backup refused.");
        if (updateLatest && File.Exists(Path.Combine(store, Pointer)))
            throw new InvalidOperationException(
                "A previous recovery checkpoint is still pending; confirm it works or restore first.");

        RequireSafeTree(app);
        if (data != null) RequireSafeTree(data);
        SecureStore(store);
        string id = SnapshotId();
        string partial = Path.Combine(store, "." + id + ".partial");
        string final = Path.Combine(store, id);
        Directory.CreateDirectory(partial);
        try
        {
            long totalBytes = Files(app).Sum(x => x.Length) +
                (data == null ? 0 : Files(data).Sum(x => x.Length));
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(store));
            if (drive.AvailableFreeSpace < totalBytes + 100 * 1024 * 1024)
                throw new IOException("Insufficient free disk space for verified snapshot.");
            var records = new List<string>();
            records.Add(Header);
            records.Add("APP\t" + Encode(app));
            records.Add("DATA\t" + Encode(data ?? ""));
            records.Add("TIME\t" + DateTime.UtcNow.ToString("o"));
            CopyArea("app", app, partial, records);
            if (data != null) CopyArea("data", data, partial, records);
            File.WriteAllLines(Path.Combine(partial, "manifest.tsv"), records.ToArray(), Encoding.UTF8);
            Verify(partial, app, data);
            Directory.Move(partial, final);
            if (updateLatest)
            {
                string tmp = Path.Combine(store, "." + id + ".pointer");
                File.WriteAllText(tmp, id, Encoding.ASCII);
                File.Move(tmp, Path.Combine(store, Pointer));
            }
            Console.WriteLine("Verified recovery snapshot: " + id);
            return id;
        }
        catch
        {
            if (Directory.Exists(partial)) Directory.Delete(partial, true);
            throw;
        }
    }

    static void CopyArea(string area, string root, string destination, List<string> records)
    {
        if (!Directory.Exists(root)) return;
        foreach (FileInfo source in Files(root))
        {
            string rel = source.FullName.Substring(root.Length).TrimStart('\\');
            string dest = Path.Combine(destination, area, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(dest));
            File.Copy(source.FullName, dest);
            long size = source.Length;
            string hash = Digest(source.FullName);
            if (new FileInfo(dest).Length != size || Digest(dest) != hash)
                throw new IOException("Source changed while copying: " + rel);
            records.Add("FILE\t" + area + "\t" + Encode(rel) + "\t" + size + "\t" + hash);
        }
    }

    static string CurrentSnapshot(string store)
    {
        string pointer = Path.Combine(store, Pointer);
        if (!File.Exists(pointer)) throw new InvalidOperationException("No pending recovery checkpoint.");
        string id = File.ReadAllText(pointer).Trim();
        if (!System.Text.RegularExpressions.Regex.IsMatch(id,
                @"^snapshot-[0-9]{14}-[0-9a-f]{12}$"))
            throw new InvalidDataException("Invalid snapshot identifier.");
        return Path.Combine(store, id);
    }

    static void VerifyCurrent(string store, string app, string data)
    {
        Verify(CurrentSnapshot(store), app, data);
        Console.WriteLine("Recovery checkpoint verification: PASS.");
    }

    static void Verify(string snapshot, string app, string data)
    {
        string[] rows = File.ReadAllLines(Path.Combine(snapshot, "manifest.tsv"), Encoding.UTF8);
        if (rows.Length < 4 || rows[0].Trim('\uFEFF') != Header)
            throw new InvalidDataException("Recovery manifest missing or invalid.");
        string expectedApp = Decode(rows[1].Split('\t')[1]);
        string expectedData = Decode(rows[2].Split('\t')[1]);
        if (!string.Equals(expectedApp, app, Cmp) ||
            !string.Equals(expectedData, data ?? "", Cmp))
            throw new InvalidDataException("Recovery snapshot targets another installation.");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string row in rows.Skip(4))
        {
            string[] fields = row.Split('\t');
            if (fields.Length != 5 || fields[0] != "FILE" ||
                (fields[1] != "app" && fields[1] != "data"))
                throw new InvalidDataException("Malformed snapshot record.");
            string rel = Decode(fields[2]);
            if (Path.IsPathRooted(rel) || rel == "" || rel == "." ||
                rel.Split('\\').Any(part => part == ".." || part == "."))
                throw new InvalidDataException("Unsafe relative path in recovery manifest.");
            string root = Path.Combine(snapshot, fields[1]);
            string file = Path.GetFullPath(Path.Combine(root, rel));
            if (!IsWithin(root, file) || !File.Exists(file) ||
                !seen.Add(fields[1] + "\\" + rel))
                throw new InvalidDataException("Recovery file missing, duplicated or escaped: " + rel);
            long size;
            if (!long.TryParse(fields[3], out size) || size < 0 ||
                new FileInfo(file).Length != size ||
                !string.Equals(Digest(file), fields[4], StringComparison.Ordinal))
                throw new InvalidDataException("Corrupted recovery file: " + rel);
        }
        if (!seen.Contains("app\\ai_orchestrator.exe"))
            throw new InvalidDataException("Recovery does not contain installed executable.");
    }

    static void Restore(string app, string data, string store)
    {
        AssertNotRunning();
        ValidatePaths(app, data, store);
        string snapshot = CurrentSnapshot(store);
        Verify(snapshot, app, data);
        // Before replacing a working installation, create a verified independent
        // safety snapshot of the current binaries and user data. Never overwrite
        // the last-known-working pointer.
        Backup(app, data, store, false);
        string suffix = ".aivexus-restore-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        string stageApp = app + suffix + "-staging";
        string quarantineApp = app + suffix + "-newer";
        string stageData = data == null ? null : data + suffix + "-staging";
        string quarantineData = data == null ? null : data + suffix + "-newer";
        bool movedOldApp = false, movedNewApp = false;
        bool movedOldData = false, movedNewData = false;
        try
        {
            CopyDirectory(Path.Combine(snapshot, "app"), stageApp);
            if (data != null && Directory.Exists(Path.Combine(snapshot, "data")))
                CopyDirectory(Path.Combine(snapshot, "data"), stageData);
            if (Directory.Exists(app)) { Directory.Move(app, quarantineApp); movedOldApp = true; }
            Directory.Move(stageApp, app); movedNewApp = true;
            if (stageData != null && Directory.Exists(stageData))
            {
                if (Directory.Exists(data)) { Directory.Move(data, quarantineData); movedOldData = true; }
                Directory.Move(stageData, data); movedNewData = true;
            }
            // A second hash validation after swap catches any incomplete copy.
            VerifyRestoredFiles(snapshot, app, data);
            Console.WriteLine("Previous AIVEXUS binaries and captured data restored.");
            Console.WriteLine("Newer state preserved in " + quarantineApp);
            File.Delete(Path.Combine(store, Pointer));
        }
        catch
        {
            if (movedNewData && Directory.Exists(data)) Directory.Delete(data, true);
            if (movedOldData && Directory.Exists(quarantineData)) Directory.Move(quarantineData, data);
            if (movedNewApp && Directory.Exists(app)) Directory.Delete(app, true);
            if (movedOldApp && Directory.Exists(quarantineApp)) Directory.Move(quarantineApp, app);
            throw;
        }
        finally
        {
            if (Directory.Exists(stageApp)) Directory.Delete(stageApp, true);
            if (stageData != null && Directory.Exists(stageData)) Directory.Delete(stageData, true);
        }
    }

    static void CopyDirectory(string source, string destination)
    {
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException(source);
        RequireSafeTree(source);
        Directory.CreateDirectory(destination);
        foreach (FileInfo file in Files(source))
        {
            string relative = file.FullName.Substring(source.Length).TrimStart('\\');
            string target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            File.Copy(file.FullName, target);
        }
    }

    static void VerifyRestoredFiles(string snapshot, string app, string data)
    {
        string[] rows = File.ReadAllLines(Path.Combine(snapshot, "manifest.tsv"), Encoding.UTF8);
        foreach (string row in rows.Skip(4))
        {
            string[] fields = row.Split('\t');
            string root = fields[1] == "app" ? app : data;
            if (root == null) throw new InvalidDataException("No data root for record.");
            string path = Path.Combine(root, Decode(fields[2]));
            if (!File.Exists(path) || Digest(path) != fields[4])
                throw new InvalidDataException("Restored file mismatch: " + path);
        }
    }
}
