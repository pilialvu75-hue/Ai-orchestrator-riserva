package dev.aivexus.adskill;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Standalone, offline-first Android UI with user-selectable language and theme. */
public final class MainActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout home, settingsPage;
    private TextView state, queries, blocked, timer, permissions, savedCount, updateStatus;
    private Button power, pause, blockNext, endAllowance, checkUpdates;
    private CheckBox smart;
    private LinearLayout savedChoicesContainer;
    private boolean preferencesVisible = false;
    private boolean receiverActive = false;
    private int vpnCommandEpoch = 0;

    private final Runnable refreshTask = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 1000L);
        }
    };

    private final BroadcastReceiver statusChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { refresh(); }
    };

    private String t(String key) { return UiPrefs.text(this, key); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private SharedPreferences preferences() { return UiPrefs.preferences(this); }

    /** Read the installed package, never infer its version from a GitHub release. */
    private String installedVersion() {
        try {
            PackageInfo packageInfo = getPackageManager().getPackageInfo(getPackageName(), 0);
            long code = packageInfo.getLongVersionCode();
            return UiPrefs.format(this, "installed_version", packageInfo.versionName, code);
        } catch (PackageManager.NameNotFoundException e) {
            return t("version_unknown");
        }
    }

    private boolean debugBuild() {
        return (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
    }

    @Override public void onCreate(Bundle stateBundle) {
        setTheme(UiPrefs.dark(this)
            ? android.R.style.Theme_Material_NoActionBar
            : android.R.style.Theme_Material_Light_NoActionBar);
        super.onCreate(stateBundle);
        getWindow().setStatusBarColor(UiPrefs.background(this));
        getWindow().setNavigationBarColor(UiPrefs.background(this));
        if (!UiPrefs.dark(this)) {
            getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }

        ScrollView scroller = new ScrollView(this);
        scroller.setFillViewport(true);
        scroller.setBackgroundColor(UiPrefs.background(this));
        LinearLayout root = column();
        root.setPadding(dp(17), dp(22), dp(17), dp(24));
        scroller.addView(root);
        setContentView(scroller);

        LinearLayout hero = card();
        LinearLayout title = new LinearLayout(this);
        title.setOrientation(LinearLayout.HORIZONTAL);
        title.setGravity(android.view.Gravity.CENTER_VERTICAL);
        TextView glyph = label("⬡", 33, true, UiPrefs.accent(this));
        glyph.setPadding(0, 0, dp(12), 0);
        title.addView(glyph);
        LinearLayout heading = column();
        heading.addView(label(t("app"), 29, true, UiPrefs.textColor(this)));
        heading.addView(label(t("subtitle"), 12, false, UiPrefs.secondary(this)));
        heading.addView(label(installedVersion(), 12, true, UiPrefs.accent(this)));
        title.addView(heading);
        hero.addView(title);
        root.addView(hero);

        LinearLayout tabs = new LinearLayout(this);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        tabs.setPadding(0, dp(10), 0, dp(9));
        Button homeTab = actionButton(t("home"), false);
        Button settingsTab = actionButton(t("settings"), false);
        tabs.addView(homeTab, new LinearLayout.LayoutParams(0, dp(46), 1));
        tabs.addView(settingsTab, new LinearLayout.LayoutParams(0, dp(46), 1));
        root.addView(tabs);

        home = column();
        settingsPage = column();
        root.addView(home);
        root.addView(settingsPage);

        homeTab.setOnClickListener(v -> setTab(false));
        settingsTab.setOnClickListener(v -> setTab(true));

        buildHome();
        buildSettings();
        setTab(false);
        renderSavedChoices();
        refresh();
    }

    private GradientDrawable rounded(int color) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(color);
        shape.setCornerRadius(dp(20));
        shape.setStroke(dp(1), UiPrefs.dark(this) ? 0xff33465a : 0xffe2e9ef);
        return shape;
    }

    private LinearLayout column() {
        LinearLayout result = new LinearLayout(this);
        result.setOrientation(LinearLayout.VERTICAL);
        return result;
    }

    private LinearLayout card() {
        LinearLayout content = column();
        content.setBackground(rounded(UiPrefs.card(this)));
        content.setPadding(dp(17), dp(14), dp(17), dp(15));
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        p.setMargins(0, dp(8), 0, dp(9));
        content.setLayoutParams(p);
        return content;
    }

    private TextView label(String text, int size, boolean bold, int color) {
        TextView result = new TextView(this);
        result.setText(text);
        result.setTextSize(size);
        result.setTextColor(color);
        result.setTypeface(null, bold ? Typeface.BOLD : Typeface.NORMAL);
        result.setPadding(0, dp(4), 0, dp(7));
        return result;
    }

    private void heading(LinearLayout group, String text) {
        group.addView(label(text, 15, true, UiPrefs.accent(this)));
    }

    private Button actionButton(String text, boolean prominent) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setTextColor(prominent ? Color.WHITE : UiPrefs.textColor(this));
        b.setBackground(rounded(prominent ? UiPrefs.accent(this) : UiPrefs.background(this)));
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(49));
        p.setMargins(0, dp(5), 0, dp(5));
        b.setLayoutParams(p);
        return b;
    }

    private void buildHome() {
        LinearLayout protection = card();
        heading(protection, t("section_protection"));
        state = label("", 21, true, UiPrefs.accent(this));
        protection.addView(state);
        power = actionButton(t("start"), true);
        power.setOnClickListener(v -> toggleVpn());
        protection.addView(power);
        // Remains available even when the cached VPN state is incorrect.
        Button emergency = actionButton(t("emergency_stop"), false);
        emergency.setOnClickListener(v -> stopVpnDirectly());
        protection.addView(emergency);
        Button androidVpn = actionButton(t("vpn_android_settings"), false);
        androidVpn.setOnClickListener(v -> {
            try { startActivity(new Intent(Settings.ACTION_VPN_SETTINGS)); }
            catch (RuntimeException e) {
                Toast.makeText(this, t("vpn_settings_failed"), Toast.LENGTH_LONG).show();
            }
        });
        protection.addView(androidVpn);
        protection.addView(label(t("emergency_info"), 11, false,
            UiPrefs.secondary(this)));
        home.addView(protection);

        LinearLayout numbers = new LinearLayout(this);
        numbers.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout left = card(), right = card();
        left.addView(label(t("dns_queries"), 12, false, UiPrefs.secondary(this)));
        right.addView(label(t("dns_blocked"), 12, false, UiPrefs.secondary(this)));
        queries = label("0", 26, true, UiPrefs.textColor(this));
        blocked = label("0", 26, true, UiPrefs.textColor(this));
        left.addView(queries);
        right.addView(blocked);
        numbers.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        numbers.addView(right, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        home.addView(numbers);

        LinearLayout rewards = card();
        heading(rewards, t("section_smart"));
        smart = new CheckBox(this);
        smart.setText(t("smart_switch"));
        smart.setTextColor(UiPrefs.textColor(this));
        smart.setTextSize(14);
        smart.setChecked(preferences().getBoolean(RewardAdvisor.PREF_KEY, false));
        smart.setOnCheckedChangeListener((button, checked) -> {
            preferences().edit().putBoolean(RewardAdvisor.PREF_KEY, checked).apply();
            if (checked && (!RewardAdvisor.hasOverlayAccess(this)
                || !RewardAdvisor.hasUsageAccess(this))) {
                Toast.makeText(this, t("permission_needed"), Toast.LENGTH_LONG).show();
            }
            refresh();
        });
        rewards.addView(smart);
        rewards.addView(label(t("smart_details"), 12, false, UiPrefs.secondary(this)));
        pause = actionButton(t("pause"), true);
        pause.setOnClickListener(v -> {
            startService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_ALLOW_60));
            refresh();
        });
        rewards.addView(pause);
        timer = label(t("pause_off"), 13, true, UiPrefs.secondary(this));
        rewards.addView(timer);
        blockNext = actionButton(t("stop_next"), false);
        blockNext.setOnClickListener(v -> {
            startService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_BLOCK_NEXT));
            Toast.makeText(this, t("next_hint"), Toast.LENGTH_LONG).show();
        });
        rewards.addView(blockNext);
        endAllowance = actionButton(t("stop_current"), false);
        endAllowance.setOnClickListener(v -> {
            startService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_BLOCK_NOW));
            refresh();
        });
        rewards.addView(endAllowance);
        home.addView(rewards);

        LinearLayout security = card();
        heading(security, t("privacy"));
        security.addView(label(t("privacy_info"), 13, false, UiPrefs.secondary(this)));
        security.addView(label(t("internet_warning"), 13, false, UiPrefs.secondary(this)));
        home.addView(security);
    }

    private void buildSettings() {
        LinearLayout appearance = card();
        heading(appearance, t("section_prefs"));
        appearance.addView(label(t("theme"), 14, true, UiPrefs.textColor(this)));
        String[] themes = {"system", "light", "dark"};
        String[] themeLabels = {t("system"), t("light"), t("dark")};
        Spinner themeSelect = selector(themeLabels, themes, preferences().getString(UiPrefs.THEME, "system"));
        appearance.addView(themeSelect);
        themeSelect.setOnItemSelectedListener(choiceListener(themes, UiPrefs.THEME));

        appearance.addView(label(t("language"), 14, true, UiPrefs.textColor(this)));
        String[] languages = {"system", "it", "fr", "en", "es"};
        String[] languageLabels = {t("system"), t("italian"), t("french"), t("english"), t("spanish")};
        Spinner languageSelect = selector(languageLabels, languages,
            preferences().getString(UiPrefs.LANG, "system"));
        appearance.addView(languageSelect);
        languageSelect.setOnItemSelectedListener(choiceListener(languages, UiPrefs.LANG));
        settingsPage.addView(appearance);

        LinearLayout futurePrivacy = card();
        heading(futurePrivacy, t("privacy"));
        CheckBox plannedBlack = new CheckBox(this);
        plannedBlack.setText(t("black_default"));
        plannedBlack.setTextColor(UiPrefs.textColor(this));
        plannedBlack.setChecked(preferences().getBoolean("planned_black", true));
        plannedBlack.setOnCheckedChangeListener((v, checked) ->
            preferences().edit().putBoolean("planned_black", checked).apply());
        futurePrivacy.addView(plannedBlack);
        CheckBox plannedMute = new CheckBox(this);
        plannedMute.setText(t("mute_default"));
        plannedMute.setTextColor(UiPrefs.textColor(this));
        plannedMute.setChecked(preferences().getBoolean("planned_mute", true));
        plannedMute.setOnCheckedChangeListener((v, checked) ->
            preferences().edit().putBoolean("planned_mute", checked).apply());
        futurePrivacy.addView(plannedMute);
        futurePrivacy.addView(label(t("privacy_future"), 12, false, UiPrefs.secondary(this)));
        settingsPage.addView(futurePrivacy);

        LinearLayout permissionsCard = card();
        heading(permissionsCard, t("section_permissions"));
        Button overlays = actionButton(t("permission_overlay"), false);
        overlays.setOnClickListener(v -> startActivity(
            new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + getPackageName()))));
        permissionsCard.addView(overlays);
        Button usage = actionButton(t("permission_usage"), false);
        usage.setOnClickListener(v -> startActivity(
            new Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)));
        permissionsCard.addView(usage);
        permissions = label("", 12, false, UiPrefs.secondary(this));
        permissionsCard.addView(permissions);
        settingsPage.addView(permissionsCard);

        LinearLayout policyCard = card();
        heading(policyCard, t("section_policy"));
        policyCard.addView(label(t("choice_intro"), 13, false, UiPrefs.secondary(this)));
        savedCount = label("", 13, false, UiPrefs.textColor(this));
        policyCard.addView(savedCount);
        savedChoicesContainer = column();
        policyCard.addView(savedChoicesContainer);
        Button reset = actionButton(t("reset_choices"), false);
        reset.setOnClickListener(v -> {
            RewardAdvisor.clearAllChoices(this);
            Toast.makeText(this, t("reset_done"), Toast.LENGTH_LONG).show();
            refresh();
            renderSavedChoices();
        });
        policyCard.addView(reset);
        settingsPage.addView(policyCard);

        LinearLayout updater = card();
        heading(updater, t("section_updates"));
        updater.addView(label(installedVersion(), 15, true, UiPrefs.textColor(this)));
        updater.addView(label(
            t(debugBuild() ? "debug_channel" : "signed_channel"),
            12, false, UiPrefs.secondary(this)));
        updater.addView(label(t("update_info"), 13, false, UiPrefs.secondary(this)));
        checkUpdates = actionButton(t("check_updates"), true);
        checkUpdates.setOnClickListener(v -> checkUpdates());
        updater.addView(checkUpdates);
        updateStatus = label("", 12, false, UiPrefs.secondary(this));
        updater.addView(updateStatus);
        updateStatus.setText(debugBuild() ? t("debug_no_inplace") : t("signed_update_ready"));
        Button githubReleases = actionButton(t("open_releases"), false);
        githubReleases.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW,
            Uri.parse("https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/releases?q=ads-kill"))));
        updater.addView(githubReleases);
        settingsPage.addView(updater);
    }

    private Spinner selector(String[] labels, String[] values, String selected) {
        Spinner spinner = new Spinner(this);
        ArrayAdapter<String> adapter = new ArrayAdapter<>(
            this, android.R.layout.simple_spinner_item, labels);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spinner.setAdapter(adapter);
        for (int i = 0; i < values.length; i++) {
            if (values[i].equals(selected)) spinner.setSelection(i, false);
        }
        return spinner;
    }

    private AdapterView.OnItemSelectedListener choiceListener(String[] values, String key) {
        return new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int pos, long id) {
                if (pos < 0 || pos >= values.length) return;
                String old = preferences().getString(key, "system");
                if (values[pos].equals(old)) return;
                preferences().edit().putString(key, values[pos]).apply();
                recreate();
            }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        };
    }

    /** Only remembered applications, not an invasive inventory of installed apps. */
    private void renderSavedChoices() {
        if (savedChoicesContainer == null) return;
        savedChoicesContainer.removeAllViews();
        Map<String, ?> all = preferences().getAll();
        List<String> packages = new ArrayList<>();
        for (String k : all.keySet()) {
            if (k.startsWith(RewardAdvisor.PREF_PREFIX)) {
                packages.add(k.substring(RewardAdvisor.PREF_PREFIX.length()));
            }
        }
        Collections.sort(packages);
        if (packages.isEmpty()) {
            savedChoicesContainer.addView(label(t("no_choices"), 12, false,
                UiPrefs.secondary(this)));
            return;
        }
        for (String pkg : packages) {
            String key = RewardAdvisor.PREF_PREFIX + pkg;
            savedChoicesContainer.addView(label(pkg, 12, true, UiPrefs.textColor(this)));
            String[] options = {"ask", "allow", "block"};
            String[] labels = {t("rule_ask"), t("rule_allow"), t("rule_block")};
            Spinner select = selector(labels, options, preferences().getString(key, "ask"));
            select.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
                @Override public void onItemSelected(AdapterView<?> parent, View view,
                                                     int position, long id) {
                    if (position < 0 || position >= options.length) return;
                    String newValue = options[position];
                    String existing = preferences().getString(key, "ask");
                    if (newValue.equals(existing)) return;
                    SharedPreferences.Editor edit = preferences().edit();
                    if ("ask".equals(newValue)) edit.remove(key);
                    else edit.putString(key, newValue);
                    edit.apply();
                }
                @Override public void onNothingSelected(AdapterView<?> parent) {}
            });
            savedChoicesContainer.addView(select);
        }
    }

    private void setTab(boolean settings) {
        preferencesVisible = settings;
        if (settings) renderSavedChoices();
        home.setVisibility(settings ? View.GONE : View.VISIBLE);
        settingsPage.setVisibility(settings ? View.VISIBLE : View.GONE);
        refresh();
    }

    /**
     * Record the user's OFF request synchronously before any service call.
     * Send ACTION_STOP to tear down the TUN explicitly, then use stopService()
     * as a fallback. The command epoch prevents an old fallback from killing
     * a newly started session when the user toggles quickly.
     */
    private void stopVpnDirectly() {
        final int epoch = ++vpnCommandEpoch;
        if (!preferences().edit()
            .putBoolean(AdsVpnService.PREF_VPN_REQUESTED, false).commit()) {
            Toast.makeText(this, t("stop_failed"), Toast.LENGTH_LONG).show();
        }
        try {
            startService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_STOP));
        } catch (RuntimeException e) {
            // On some Android builds stopService still works when a STOP intent
            // cannot be delivered. Do not drop the user's OFF request.
            try { stopService(new Intent(this, AdsVpnService.class)); }
            catch (RuntimeException ignored) { }
        }
        refresh();
        handler.postDelayed(() -> {
            if (epoch != vpnCommandEpoch || preferences()
                .getBoolean(AdsVpnService.PREF_VPN_REQUESTED, false)) return;
            try { stopService(new Intent(this, AdsVpnService.class)); }
            catch (RuntimeException e) {
                Toast.makeText(this, t("stop_failed"), Toast.LENGTH_LONG).show();
            }
            refresh();
        }, 700L);
        handler.postDelayed(this::refresh, 1400L);
    }

    private void toggleVpn() {
        if (AdsVpnService.active) {
            stopVpnDirectly();
        } else {
            Intent approval = VpnService.prepare(this);
            if (approval != null) startActivityForResult(approval, 121);
            else startVpn();
        }
    }

    @Override protected void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == 121 && result == RESULT_OK) startVpn();
    }

    private void startVpn() {
        ++vpnCommandEpoch;
        if (!preferences().edit()
            .putBoolean(AdsVpnService.PREF_VPN_REQUESTED, true).commit()) {
            Toast.makeText(this, t("start_failed"), Toast.LENGTH_LONG).show();
            return;
        }
        try {
            startForegroundService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_START));
        } catch (Exception ex) {
            preferences().edit().putBoolean(AdsVpnService.PREF_VPN_REQUESTED, false).apply();
            Toast.makeText(this, t("start_failed"), Toast.LENGTH_LONG).show();
        }
    }

    private void refresh() {
        if (state == null) return;
        boolean on = AdsVpnService.active;
        boolean stopping = on && !preferences()
            .getBoolean(AdsVpnService.PREF_VPN_REQUESTED, false);
        state.setText(t(stopping ? "status_stopping" : on ? "status_on" : "status_off"));
        state.setTextColor(on ? UiPrefs.accent(this) : UiPrefs.secondary(this));
        power.setText(t(on ? "stop" : "start"));
        pause.setEnabled(on);
        long count = preferences().getLong("queries", 0L), rejected = preferences().getLong("blocked", 0L);
        queries.setText(String.valueOf(count));
        blocked.setText(String.valueOf(rejected));
        long ms = preferences().getLong("allow_until", 0L) - System.currentTimeMillis();
        long remaining = Math.max(0L, (ms + 999L) / 1000L);
        timer.setText(on && remaining > 0
            ? UiPrefs.format(this, "pause_left", remaining) : t("pause_off"));
        blockNext.setEnabled(on && remaining > 0);
        endAllowance.setEnabled(on && remaining > 0);
        if (permissions != null) permissions.setText(UiPrefs.format(this,
            "permission_status",
            t(RewardAdvisor.hasOverlayAccess(this) ? "yes" : "no"),
            t(RewardAdvisor.hasUsageAccess(this) ? "yes" : "no")));
        if (savedCount != null) savedCount.setText(
            UiPrefs.format(this, "choices_count", RewardAdvisor.rememberedCount(this)));
    }

    private void checkUpdates() {
        checkUpdates.setEnabled(false);
        updateStatus.setText(t("checking"));
        UpdateClient.check(this, new UpdateClient.Result() {
            @Override public void ready(UpdateClient.Release version) {
                checkUpdates.setEnabled(true);
                if (version == null) {
                    updateStatus.setText(t("no_updates"));
                    return;
                }
                updateStatus.setText(UiPrefs.format(MainActivity.this, "new_version", version.version()));
                new AlertDialog.Builder(MainActivity.this)
                    .setTitle(t("install_title"))
                    .setMessage(UiPrefs.format(MainActivity.this, "new_version", version.version())
                        + " · SHA-256 · Android verifies package signature.")
                    .setPositiveButton(t("download"), (dialog, which) -> downloadUpdate(version))
                    .setNegativeButton(t("cancel"), null).show();
            }
            @Override public void error(String message) {
                checkUpdates.setEnabled(true);
                updateStatus.setText(message);
            }
        });
    }

    private void downloadUpdate(UpdateClient.Release release) {
        checkUpdates.setEnabled(false);
        updateStatus.setText(t("download_progress"));
        UpdateClient.download(this, release, new UpdateClient.DownloadResult() {
            @Override public void ready() {
                checkUpdates.setEnabled(true);
                updateStatus.setText(t("download_ready"));
                new AlertDialog.Builder(MainActivity.this)
                    .setTitle(t("install_title"))
                    .setMessage(t("download_ready"))
                    .setPositiveButton(t("install"), (dialog, which) ->
                        UpdateClient.requestInstall(MainActivity.this))
                    .setNegativeButton(t("cancel"), null).show();
            }
            @Override public void error(String message) {
                checkUpdates.setEnabled(true);
                updateStatus.setText(message);
            }
        });
    }

    @Override protected void onResume() {
        super.onResume();
        IntentFilter filter = new IntentFilter(AdsVpnService.STATUS);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(statusChanged, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(statusChanged, filter);
        }
        receiverActive = true;
        handler.post(refreshTask);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(refreshTask);
        if (receiverActive) {
            unregisterReceiver(statusChanged);
            receiverActive = false;
        }
        super.onPause();
    }
}
