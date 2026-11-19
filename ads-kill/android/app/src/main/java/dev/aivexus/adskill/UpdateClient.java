package dev.aivexus.adskill;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Opt-in GitHub beta updater. No background checks, telemetry, or silent installs.
 * Only same-package signed APKs are considered. Android is responsible for
 * verifying the update certificate, protecting existing installations.
 *
 * First-run debug APKs cannot update one another: GitHub-hosted debug builds
 * use ephemeral signing keys. Set up a dedicated stable ADS_KILL signing key
 * in repository secrets before relying on in-place updates.
 */
final class UpdateClient {
    interface Result { void ready(Release release); void error(String message); }
    interface DownloadResult { void ready(); void error(String message); }

    static final class Release {
        private final String version;
        private final String url;
        private final String sha256;
        private final long size;
        Release(String version, String url, String sha256, long size) {
            this.version = version;
            this.url = url;
            this.sha256 = sha256;
            this.size = size;
        }
        String version() { return version; }
        String url() { return url; }
        String sha256() { return sha256; }
        long size() { return size; }
    }

    private static final String BASE = "https://api.github.com/repos/pilialvu75-hue/Ai-orchestrator-riserva";
    private static final String TAG_PREFIX = "ads-kill-v";
    private static final Pattern VERSION = Pattern.compile("(\\d+)\\.(\\d+)\\.(\\d+)-beta(\\d+)");
    private static final int MAX_DOWNLOAD = 120 * 1024 * 1024;

    private UpdateClient() {}

    static void check(Activity activity, Result listener) {
        new Thread(() -> {
            try {
                String current = activity.getPackageManager().getPackageInfo(
                    activity.getPackageName(), 0).versionName;
                long installed = versionNumber(current);
                JSONArray tags = new JSONArray(fetchText(
                    BASE + "/git/matching-refs/tags/" + TAG_PREFIX, 512 * 1024));
                String selectedTag = null;
                long selectedVersion = installed;
                for (int i = 0; i < tags.length(); i++) {
                    String ref = tags.getJSONObject(i).optString("ref");
                    String prefix = "refs/tags/" + TAG_PREFIX;
                    if (!ref.startsWith(prefix)) continue;
                    String version = ref.substring(prefix.length());
                    long n = versionNumber(version);
                    if (n > selectedVersion) {
                        selectedVersion = n;
                        selectedTag = TAG_PREFIX + version;
                    }
                }
                // Debug APKs published by CI may use a different certificate on
                // every run. Never offer a false "in-place update" to a debug install.
                if ((activity.getApplicationInfo().flags
                    & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                    final String notice = selectedTag == null
                        ? UiPrefs.text(activity, "debug_no_inplace")
                        : UiPrefs.format(activity, "debug_newer",
                            selectedTag.substring(TAG_PREFIX.length()));
                    activity.runOnUiThread(() -> listener.error(notice));
                    return;
                }
                if (selectedTag == null) {
                    activity.runOnUiThread(() -> listener.ready(null));
                    return;
                }

                JSONObject release = new JSONObject(fetchText(
                    BASE + "/releases/tags/" + selectedTag, 256 * 1024));
                JSONArray assets = release.getJSONArray("assets");
                Release found = null;
                String version = selectedTag.substring(TAG_PREFIX.length());
                String exactName = "ads-kill-v" + version + "-signed.apk";
                for (int i = 0; i < assets.length(); i++) {
                    JSONObject asset = assets.getJSONObject(i);
                    if (!exactName.equals(asset.optString("name"))) continue;
                    String url = asset.optString("browser_download_url");
                    String digest = asset.optString("digest");
                    long size = asset.optLong("size", 0);
                    String expectedPrefix = "https://github.com/pilialvu75-hue/"
                        + "Ai-orchestrator-riserva/releases/download/" + selectedTag + "/";
                    if (!url.equals(expectedPrefix + exactName)
                        || !digest.matches("sha256:[0-9a-fA-F]{64}")
                        || size < 1024 || size > MAX_DOWNLOAD) continue;
                    found = new Release(version, url,
                        digest.substring(7).toLowerCase(Locale.ROOT), size);
                    break;
                }
                // Never offer an ephemeral debug APK as an in-place update.
                final Release result = found;
                activity.runOnUiThread(() -> {
                    if (result != null) listener.ready(result);
                    else listener.error(UiPrefs.text(activity, "update_unavailable"));
                });
            } catch (Exception e) {
                Log.w("AdsKill", "Update check failed", e);
                activity.runOnUiThread(() -> listener.error(
                    UiPrefs.text(activity, "update_network_error")));
            }
        }, "ads-kill-check-update").start();
    }

    static void download(Activity activity, Release release, DownloadResult callback) {
        new Thread(() -> {
            File tmp = new File(activity.getCacheDir(), "adskill_update.part");
            File done = new File(activity.getCacheDir(), "adskill_update.apk");
            try {
                // Never allow a stale cached APK to be installed after failed verification.
                if (done.exists() && !done.delete()) throw new SecurityException("Old APK cannot be deleted");
                if (tmp.exists() && !tmp.delete()) throw new SecurityException("Old partial APK cannot be deleted");
                MessageDigest sha = MessageDigest.getInstance("SHA-256");
                HttpURLConnection conn = open(release.url());
                int count = 0;
                try (InputStream in = conn.getInputStream();
                     FileOutputStream output = new FileOutputStream(tmp)) {
                    byte[] bytes = new byte[8192];
                    int n;
                    while ((n = in.read(bytes)) != -1) {
                        count += n;
                        if (count > MAX_DOWNLOAD) throw new SecurityException("APK too large");
                        sha.update(bytes, 0, n);
                        output.write(bytes, 0, n);
                    }
                    output.getFD().sync();
                } finally {
                    conn.disconnect();
                }
                if (count != release.size()) throw new SecurityException("APK size mismatch");
                StringBuilder hash = new StringBuilder();
                for (byte b : sha.digest()) hash.append(String.format(Locale.ROOT, "%02x", b & 0xff));
                if (!hash.toString().equals(release.sha256())) {
                    throw new SecurityException("APK checksum mismatch");
                }
                if (!tmp.renameTo(done)) throw new SecurityException("Could not stage verified APK");
                activity.runOnUiThread(callback::ready);
            } catch (Exception e) {
                Log.w("AdsKill", "Verified APK download failed", e);
                activity.runOnUiThread(() -> callback.error(
                    "Download o verifica SHA-256 non riusciti. Nessuna installazione avviata."));
            } finally {
                if (tmp.exists()) tmp.delete();
            }
        }, "ads-kill-download-update").start();
    }

    static void requestInstall(Activity activity) {
        if (Build.VERSION.SDK_INT >= 26
            && !activity.getPackageManager().canRequestPackageInstalls()) {
            new AlertDialog.Builder(activity)
                .setTitle("Autorizzazione installazione")
                .setMessage("Android richiede una tua autorizzazione per installare "
                    + "aggiornamenti da Ads Kill. Dopo averla concessa, premi di nuovo Installa.")
                .setPositiveButton("Apri impostazioni", (dialog, which) -> {
                    Intent settings = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + activity.getPackageName()));
                    activity.startActivity(settings);
                })
                .setNegativeButton("Annulla", null).show();
            return;
        }
        Intent install = new Intent(Intent.ACTION_VIEW);
        install.setDataAndType(UpdateApkProvider.APK_URI, UpdateApkProvider.MIME);
        install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        install.setClipData(android.content.ClipData.newUri(
            activity.getContentResolver(), "Ads Kill update", UpdateApkProvider.APK_URI));
        try {
            activity.startActivity(install);
        } catch (ActivityNotFoundException e) {
            new AlertDialog.Builder(activity)
                .setMessage("Installatore Android non disponibile.")
                .setPositiveButton("OK", null).show();
        }
    }

    private static long versionNumber(String version) {
        Matcher m = VERSION.matcher(version == null ? "" : version);
        if (!m.matches()) return -1L;
        long major = Long.parseLong(m.group(1)), minor = Long.parseLong(m.group(2));
        long patch = Long.parseLong(m.group(3)), beta = Long.parseLong(m.group(4));
        if (major > 999 || minor > 999 || patch > 999 || beta > 999) return -1L;
        return major * 1_000_000_000L + minor * 1_000_000L + patch * 1000L + beta;
    }

    private static HttpURLConnection open(String address) throws Exception {
        if (!address.startsWith("https://")) throw new SecurityException("HTTPS required");
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setConnectTimeout(8000);
        connection.setReadTimeout(15000);
        connection.setRequestProperty("User-Agent", "AdsKillAndroidUpdater/0.1");
        connection.setRequestProperty("Accept", "application/vnd.github+json");
        if (connection.getResponseCode() != 200) {
            connection.disconnect();
            throw new java.io.IOException("HTTP " + connection.getResponseCode());
        }
        return connection;
    }

    private static String fetchText(String address, int maximum) throws Exception {
        HttpURLConnection conn = open(address);
        try (InputStream input = conn.getInputStream();
             java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int length;
            while ((length = input.read(buffer)) != -1) {
                if (output.size() + length > maximum) throw new SecurityException("Response too large");
                output.write(buffer, 0, length);
            }
            return output.toString("UTF-8");
        } finally {
            conn.disconnect();
        }
    }
}
