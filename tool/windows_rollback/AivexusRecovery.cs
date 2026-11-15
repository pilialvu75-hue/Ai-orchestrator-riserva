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
using System.Windows.Forms;

internal static class AivexusRecovery
{
    const string Header = "AIVEXUS_ROLLBACK_V3";
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
            string roaming = settings.ContainsKey("roaming") && settings["roaming"].Length > 0
                ? Path.GetFullPath(settings["roaming"]).TrimEnd('\\') : null;
            if (string.Equals(mode, "backup", Cmp))
                Backup(app, data, roaming, store, true);
            else if (string.Equals(mode, "verify", Cmp))
                VerifyCurrent(store, app, data, roaming);
            else if (string.Equals(mode, "restore", Cmp))
            {
                if (!settings.ContainsKey("confirm"))
                {
                    DialogResult consent = MessageBox.Show(
                        "Ripristinare la versione precedente di AIVEXUS?\n" +
                        "Il programma deve essere chiuso. Lo stato corrente sara' " +
                        "salvato come copia di sicurezza. I dati successivi " +
                        "alla versione salvata potrebbero non essere compatibili.",
                        "AIVEXUS - Ripristino della versione precedente",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
                        MessageBoxDefaultButton.Button2);
                    if (consent != DialogResult.Yes)
                        throw new InvalidOperationException("Recovery cancelled by user.");
                }
                else if (settings["confirm"] != "yes")
                    throw new InvalidOperationException("Invalid explicit confirmation.");
                Restore(app, data, roaming, store);
            }
            else if (string.Equals(mode, "accept", Cmp))
            {
                AssertNotRunning();
                VerifyCurrent(store, app, data, roaming);
                if (!File.Exists(Path.Combine(app, "ai_orchestrator.exe")))
                    throw new InvalidOperationException("Cannot accept a broken installation.");
                if (!settings.ContainsKey("confirm"))
                {
                    DialogResult consent = MessageBox.Show(
                        "Hai verificato che questa versione di AIVEXUS funziona?\n" +
                        "Confermandola, la copia della versione precedente restera' " +
                        "archiviata, ma non sara' piu' il punto di recupero automatico.\n" +
                        "Solo dopo questa conferma potrai installare un'altra versione.",
                        "AIVEXUS - Conferma aggiornamento funzionante",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2);
                    if (consent != DialogResult.Yes)
                        throw new InvalidOperationException("Upgrade acceptance cancelled.");
                }
                else if (settings["confirm"] != "yes")
                    throw new InvalidOperationException("Invalid acceptance confirmation.");
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
            if (!new[] { "mode", "store", "app", "data", "roaming", "confirm" }.Contains(key))
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

    static void ValidatePaths(string app, string data, string roaming, string store)
    {
        var roots = new List<string> { app, store };
        if (data != null) roots.Add(data);
        if (roaming != null) roots.Add(roaming);
        for (int i = 0; i < roots.Count; i++)
            for (int j = i + 1; j < roots.Count; j++)
                if (string.Equals(roots[i], roots[j], Cmp) ||
                    IsWithin(roots[i], roots[j]) || IsWithin(roots[j], roots[i]))
                    throw new InvalidOperationException(
                        "Application, profile and snapshot roots must be separate.");
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

    static string Backup(string app, string data, string roaming, string store, bool updateLatest)
    {
        AssertNotRunning();
        ValidatePaths(app, data, roaming, store);
        if (updateLatest && !File.Exists(Path.Combine(app, "ai_orchestrator.exe")))
            throw new InvalidOperationException("No installed AI Orchestrator executable: pre-update backup refused.");
        if (updateLatest && File.Exists(Path.Combine(store, Pointer)))
            throw new InvalidOperationException(
                "A previous recovery checkpoint is still pending; confirm it works or restore first.");

        RequireSafeTree(app);
        if (data != null) RequireSafeTree(data);
        if (roaming != null) RequireSafeTree(roaming);
        SecureStore(store);
        string id = SnapshotId();
        string partial = Path.Combine(store, "." + id + ".partial");
        string final = Path.Combine(store, id);
        Directory.CreateDirectory(partial);
        try
        {
            long totalBytes = Files(app).Sum(x => x.Length) +
                (data == null ? 0 : Files(data).Sum(x => x.Length)) +
                (roaming == null ? 0 : Files(roaming).Sum(x => x.Length));
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(store));
            if (drive.AvailableFreeSpace < totalBytes + 100 * 1024 * 1024)
                throw new IOException("Insufficient free disk space for verified snapshot.");
            var records = new List<string>();
            records.Add(Header);
            records.Add("APP\t" + Encode(app));
            records.Add("DATA\t" + Encode(data ?? ""));
            records.Add("ROAMING\t" + Encode(roaming ?? ""));
            records.Add("TIME\t" + DateTime.UtcNow.ToString("o"));
            bool dataPresent = data != null && Directory.Exists(data);
            bool roamingPresent = roaming != null && Directory.Exists(roaming);
            records.Add("DATA_PRESENT\t" + (dataPresent ? "1" : "0"));
            records.Add("ROAMING_PRESENT\t" + (roamingPresent ? "1" : "0"));
            if (Directory.Exists(app))
            {
                Directory.CreateDirectory(Path.Combine(partial, "app"));
                CopyArea("app", app, partial, records);
            }
            if (dataPresent)
            {
                Directory.CreateDirectory(Path.Combine(partial, "data"));
                CopyArea("data", data, partial, records);
            }
            if (roamingPresent)
            {
                Directory.CreateDirectory(Path.Combine(partial, "roaming"));
                CopyArea("roaming", roaming, partial, records);
            }
            File.WriteAllLines(Path.Combine(partial, "manifest.tsv"), records.ToArray(), Encoding.UTF8);
            Verify(partial, app, data, roaming, updateLatest);
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

    static void VerifyCurrent(string store, string app, string data, string roaming)
    {
        Verify(CurrentSnapshot(store), app, data, roaming);
        Console.WriteLine("Recovery checkpoint verification: PASS.");
    }

    static bool SnapshotRootPresent(string snapshot, string area)
    {
        string[] rows = File.ReadAllLines(Path.Combine(snapshot, "manifest.tsv"), Encoding.UTF8);
        int index = area == "data" ? 5 : area == "roaming" ? 6 : -1;
        if (index < 0 || rows.Length <= index)
            throw new InvalidDataException("Snapshot missing profile-root existence record.");
        string key = area == "data" ? "DATA_PRESENT\t" : "ROAMING_PRESENT\t";
        if (rows[index] != key + "0" && rows[index] != key + "1")
            throw new InvalidDataException("Invalid profile-root existence record.");
        return rows[index] == key + "1";
    }

    static void Verify(string snapshot, string app, string data, string roaming, bool requireAppExecutable = true)
    {
        string[] rows = File.ReadAllLines(Path.Combine(snapshot, "manifest.tsv"), Encoding.UTF8);
        if (rows.Length < 7 || rows[0].Trim('\uFEFF') != Header)
            throw new InvalidDataException("Recovery manifest missing or invalid.");
        string expectedApp = Decode(rows[1].Split('\t')[1]);
        string expectedData = Decode(rows[2].Split('\t')[1]);
        string expectedRoaming = Decode(rows[3].Split('\t')[1]);
        if (!string.Equals(expectedApp, app, Cmp) ||
            !string.Equals(expectedData, data ?? "", Cmp) ||
            !string.Equals(expectedRoaming, roaming ?? "", Cmp))
            throw new InvalidDataException("Recovery snapshot targets another installation.");
        bool dataPresent = SnapshotRootPresent(snapshot, "data");
        bool roamingPresent = SnapshotRootPresent(snapshot, "roaming");
        if ((dataPresent && data == null) ||
            dataPresent != Directory.Exists(Path.Combine(snapshot, "data")) ||
            (roamingPresent && roaming == null) ||
            roamingPresent != Directory.Exists(Path.Combine(snapshot, "roaming")))
            throw new InvalidDataException("Snapshot profile-root existence mismatch.");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string row in rows.Skip(7))
        {
            string[] fields = row.Split('\t');
            if (fields.Length != 5 || fields[0] != "FILE" ||
                (fields[1] != "app" && fields[1] != "data" && fields[1] != "roaming"))
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
        if (requireAppExecutable && !seen.Contains("app\\ai_orchestrator.exe"))
            throw new InvalidDataException("Recovery does not contain installed executable.");
        // Reject any additional payload that was not hashed in the manifest.
        // Otherwise a modified snapshot could smuggle a native DLL into the
        // restored application even though every listed file was intact.
        foreach (string area in new[] { "app", "data", "roaming" })
        {
            string areaRoot = Path.Combine(snapshot, area);
            RequireSafeTree(areaRoot);
            foreach (FileInfo file in Files(areaRoot))
            {
                string rel = file.FullName.Substring(areaRoot.Length).TrimStart('\\');
                if (!seen.Contains(area + "\\" + rel))
                    throw new InvalidDataException("Unexpected unverified recovery file: " + rel);
            }
        }
    }

    static void Restore(string app, string data, string roaming, string store)
    {
        AssertNotRunning();
        ValidatePaths(app, data, roaming, store);
        string snapshot = CurrentSnapshot(store);
        Verify(snapshot, app, data, roaming);
        // Before replacing a working installation, create a verified independent
        // safety snapshot of the current binaries and user data. Never overwrite
        // the last-known-working pointer.
        Backup(app, data, roaming, store, false);
        bool dataWasPresent = SnapshotRootPresent(snapshot, "data");
        bool roamingWasPresent = SnapshotRootPresent(snapshot, "roaming");
        string suffix = ".aivexus-restore-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        string stageApp = app + suffix + "-staging";
        string quarantineApp = app + suffix + "-newer";
        string stageData = data == null ? null : data + suffix + "-staging";
        string quarantineData = data == null ? null : data + suffix + "-newer";
        string stageRoaming = roaming == null ? null : roaming + suffix + "-staging";
        string quarantineRoaming = roaming == null ? null : roaming + suffix + "-newer";
        bool movedOldApp = false, movedNewApp = false;
        bool movedOldData = false, movedNewData = false;
        bool movedOldRoaming = false, movedNewRoaming = false;
        try
        {
            CopyDirectory(Path.Combine(snapshot, "app"), stageApp);
            if (data != null && dataWasPresent)
                CopyDirectory(Path.Combine(snapshot, "data"), stageData);
            if (roaming != null && roamingWasPresent)
                CopyDirectory(Path.Combine(snapshot, "roaming"), stageRoaming);
            if (Directory.Exists(app)) { Directory.Move(app, quarantineApp); movedOldApp = true; }
            Directory.Move(stageApp, app); movedNewApp = true;
            if (data != null)
            {
                // A missing original directory is meaningful: do not leave a
                // database created by the failed new build alongside old code.
                if (Directory.Exists(data)) { Directory.Move(data, quarantineData); movedOldData = true; }
                if (dataWasPresent) { Directory.Move(stageData, data); movedNewData = true; }
            }
            if (roaming != null)
            {
                if (Directory.Exists(roaming)) { Directory.Move(roaming, quarantineRoaming); movedOldRoaming = true; }
                if (roamingWasPresent) { Directory.Move(stageRoaming, roaming); movedNewRoaming = true; }
            }
            // A second hash validation after swap catches any incomplete copy.
            VerifyRestoredFiles(snapshot, app, data, roaming);
            Console.WriteLine("Previous AIVEXUS binaries and captured data restored.");
            Console.WriteLine("Newer state preserved in " + quarantineApp);
            File.Delete(Path.Combine(store, Pointer));
        }
        catch
        {
            if (movedNewRoaming && Directory.Exists(roaming)) Directory.Delete(roaming, true);
            if (movedOldRoaming && Directory.Exists(quarantineRoaming)) Directory.Move(quarantineRoaming, roaming);
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
            if (stageRoaming != null && Directory.Exists(stageRoaming)) Directory.Delete(stageRoaming, true);
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

    static void VerifyRestoredFiles(string snapshot, string app, string data, string roaming)
    {
        string[] rows = File.ReadAllLines(Path.Combine(snapshot, "manifest.tsv"), Encoding.UTF8);
        foreach (string row in rows.Skip(7))
        {
            string[] fields = row.Split('\t');
            string root = fields[1] == "app" ? app : fields[1] == "data" ? data : roaming;
            if (root == null) throw new InvalidDataException("No data root for record.");
            string path = Path.Combine(root, Decode(fields[2]));
            if (!File.Exists(path) || Digest(path) != fields[4])
                throw new InvalidDataException("Restored file mismatch: " + path);
        }
        if (data != null &&
            Directory.Exists(data) != SnapshotRootPresent(snapshot, "data"))
            throw new InvalidDataException("Restored data-root existence mismatch.");
        if (roaming != null &&
            Directory.Exists(roaming) != SnapshotRootPresent(snapshot, "roaming"))
            throw new InvalidDataException("Restored roaming-root existence mismatch.");
    }
}
