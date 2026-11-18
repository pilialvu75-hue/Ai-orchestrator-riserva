package dev.aivexus.adskill;

import android.app.AppOpsManager;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * All-app Smart Reward: conservative, foreground-correlated DNS hints only.
 * DNS alone cannot prove a reward or attribute a DNS request to its origin.
 * Never falsifies ad playback, reward delivery or completion percentages.
 */
final class RewardAdvisor {
    static final String PREF_KEY = "smart_reward";
    static final String ASK = "ask";
    static final String ALLOW = "allow";
    static final String BLOCK = "block";
    static final String PREF_PREFIX = "choice_app_";
    private static final String OLD_WEWARD_KEY = "reward_choice_weward";
    private static final String OLD_WEWARD_PACKAGE = "com.weward";
    private static final long COOLDOWN_MS = 180_000L;
    private static final long POPUP_MS = 7_000L;
    // An advertising DNS hit is not evidence of a rewarded video.
    // Hold notifications until the foreground app has settled and several
    // independent hits have been observed over time.
    private static final long FOREGROUND_SETTLE_MS = 12_000L;
    private static final long EVIDENCE_WINDOW_MS = 20_000L;
    private static final long EVIDENCE_SPREAD_MS = 2_000L;
    private static final int MIN_EVIDENCE_HITS = 3;

    private final AdsVpnService service;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean inspecting = new AtomicBoolean(false);
    private final Map<String, Long> cooldownByApp = new ConcurrentHashMap<>();

    private volatile String lastAllowedApp = null;
    private volatile long lastAllowedTime = 0L;
    private volatile String recentCandidateApp = null;
    private volatile long recentCandidateAt = 0L;
    private boolean revealVideoForSession = false;
    private volatile String cachedForeground = null;
    private volatile long cacheTime = 0L;
    private volatile long foregroundResumedAtWallClock = 0L;

    // Used only inside inspecting's mutually exclusive candidate section.
    private String observedForeground;
    private long foregroundSeenAt;
    private String candidateApp;
    private String firstCandidateHost;
    private long firstCandidateAt;
    private int candidateHits;
    private boolean multipleCandidateHosts;

    private WindowManager wm;
    private View suggestion;
    private View allowanceStrip;
    private Runnable closeSuggestion;
    private Runnable refreshAllowance;

    RewardAdvisor(AdsVpnService service) { this.service = service; }

    static boolean hasUsageAccess(Context context) {
        AppOpsManager ops = context.getSystemService(AppOpsManager.class);
        return ops != null && ops.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(),
            context.getPackageName()) == AppOpsManager.MODE_ALLOWED;
    }

    static boolean hasOverlayAccess(Context context) {
        return Settings.canDrawOverlays(context);
    }

    private SharedPreferences prefs() { return UiPrefs.preferences(service); }
    private String t(String key) { return UiPrefs.text(service, key); }

    private String choice(String packageName) {
        if (packageName == null) return ASK;
        SharedPreferences p = prefs();
        String value = p.getString(PREF_PREFIX + packageName, null);
        if (value == null && OLD_WEWARD_PACKAGE.equals(packageName)) {
            value = p.getString(OLD_WEWARD_KEY, ASK);
        }
        return ALLOW.equals(value) || BLOCK.equals(value) ? value : ASK;
    }

    private void saveChoice(String packageName, String value) {
        if (packageName == null || packageName.isEmpty()) return;
        prefs().edit().putString(PREF_PREFIX + packageName, value).apply();
    }

    static void clearAllChoices(Context context) {
        SharedPreferences p = UiPrefs.preferences(context);
        SharedPreferences.Editor edit = p.edit().remove(OLD_WEWARD_KEY);
        for (String key : p.getAll().keySet()) {
            if (key.startsWith(PREF_PREFIX)) edit.remove(key);
        }
        edit.apply();
    }

    static int rememberedCount(Context context) {
        int n = 0;
        for (String key : UiPrefs.preferences(context).getAll().keySet()) {
            if (key.startsWith(PREF_PREFIX)) n++;
        }
        return n;
    }

    /**
     * Usage events reveal only the foreground package. Apps may make requests
     * from their background processes; so attribution is an approximation.
     */
    private String foregroundPackage() {
        if (!hasUsageAccess(service)) return null;
        long nowMonotonic = SystemClock.elapsedRealtime();
        if (nowMonotonic - cacheTime < 1500L) return cachedForeground;
        UsageStatsManager stats = service.getSystemService(UsageStatsManager.class);
        if (stats == null) return null;
        UsageEvents events = stats.queryEvents(
            System.currentTimeMillis() - 180_000L, System.currentTimeMillis());
        if (events == null) return null;
        UsageEvents.Event e = new UsageEvents.Event();
        String foreground = null;
        long resumedAt = 0L;
        while (events.hasNextEvent()) {
            events.getNextEvent(e);
            if (e.getEventType() == UsageEvents.Event.ACTIVITY_RESUMED) {
                foreground = e.getPackageName();
                resumedAt = e.getTimeStamp();
            } else if (e.getEventType() == UsageEvents.Event.ACTIVITY_PAUSED
                && foreground != null && foreground.equals(e.getPackageName())) {
                foreground = null;
                resumedAt = 0L;
            }
        }
        if (foreground != null && (foreground.equals(service.getPackageName())
            || foreground.equals("android")
            || foreground.startsWith("com.android.systemui")
            || foreground.startsWith("com.google.android.permissioncontroller"))) {
            foreground = null;
        }
        cachedForeground = foreground;
        foregroundResumedAtWallClock = foreground == null ? 0L : resumedAt;
        cacheTime = nowMonotonic;
        return foreground;
    }

    private String appLabel(String pkg) {
        if (pkg == null) return "?";
        try {
            PackageManager manager = service.getPackageManager();
            ApplicationInfo info = manager.getApplicationInfo(pkg, 0);
            return manager.getApplicationLabel(info).toString();
        } catch (Exception ignored) {
            return pkg;
        }
    }

    /** Only called on a candidate ad-domain DNS request. */
    boolean autoAllowIfRemembered() {
        if (System.currentTimeMillis() < prefs().getLong("manual_block_until", 0L)) return false;
        if (!service.isFilteringActive() || !prefs().getBoolean(PREF_KEY, false)
            || !hasOverlayAccess(service) || !hasUsageAccess(service)) return false;
        if (!inspecting.compareAndSet(false, true)) return false;
        try {
            String pkg = foregroundPackage();
            if (pkg == null || !ALLOW.equals(choice(pkg))) return false;
            lastAllowedApp = pkg;
            lastAllowedTime = SystemClock.elapsedRealtime();
            service.allowAdsFor60Seconds();
            return true;
        } catch (RuntimeException ex) {
            Log.w("AdsKill", "Could not assess remembered choice", ex);
            return false;
        } finally {
            inspecting.set(false);
        }
    }

    void onBlockedAdvertisingDomain(String domain) {
        if (!service.isFilteringActive() || domain == null || domain.isEmpty()
            || !prefs().getBoolean(PREF_KEY, false)
            || !hasOverlayAccess(service) || !hasUsageAccess(service)) return;
        if (!inspecting.compareAndSet(false, true)) return;
        try {
            String pkg = foregroundPackage();
            long now = SystemClock.elapsedRealtime();
            if (pkg == null) {
                observedForeground = null;
                candidateApp = null;
                return;
            }

            // A foreground switch often coincides with analytics and preload
            // requests made by other processes. Never prompt just on launch.
            if (!pkg.equals(observedForeground)) {
                observedForeground = pkg;
                foregroundSeenAt = now;
                candidateApp = null;
                return;
            }
            // The UsageStats resume time also covers A -> B -> A switches
            // when no blocked DNS event was seen while B was foreground.
            long resumeAt = foregroundResumedAtWallClock;
            if (now - foregroundSeenAt < FOREGROUND_SETTLE_MS
                || (resumeAt > 0L && System.currentTimeMillis() - resumeAt < FOREGROUND_SETTLE_MS)
                || !ASK.equals(choice(pkg))) return;

            long last = cooldownByApp.getOrDefault(pkg, 0L);
            if (last != 0L && now - last < COOLDOWN_MS) return;

            if (!pkg.equals(candidateApp)
                || now - firstCandidateAt > EVIDENCE_WINDOW_MS) {
                candidateApp = pkg;
                firstCandidateHost = domain;
                firstCandidateAt = now;
                candidateHits = 1;
                multipleCandidateHosts = false;
                return;
            }
            candidateHits++;
            if (!domain.equalsIgnoreCase(firstCandidateHost)) {
                multipleCandidateHosts = true;
            }
            if (candidateHits < MIN_EVIDENCE_HITS
                || !multipleCandidateHosts
                || now - firstCandidateAt < EVIDENCE_SPREAD_MS) return;

            // Still only a DNS hypothesis, NOT proof of rewarded playback.
            candidateApp = null;
            recentCandidateApp = pkg;
            recentCandidateAt = now;
            cooldownByApp.put(pkg, now);
            main.post(() -> showSuggestion(pkg));
        } catch (RuntimeException ex) {
            Log.w("AdsKill", "Foreground heuristic unavailable", ex);
        } finally {
            inspecting.set(false);
        }
    }

    /** Remembered block applies on future requests and does NOT interrupt current video. */
    boolean blockNextTime() {
        // Prefer the currently visible app, then an explicitly allowed app,
        // and finally a recent ad-domain context. This is heuristic only.
        String pkg = foregroundPackage();
        long now = SystemClock.elapsedRealtime();
        if (pkg == null && lastAllowedApp != null && now - lastAllowedTime < 120_000L) {
            pkg = lastAllowedApp;
        }
        if (pkg == null && recentCandidateApp != null && now - recentCandidateAt < 120_000L) {
            pkg = recentCandidateApp;
        }
        if (pkg == null) return false;
        saveChoice(pkg, BLOCK);
        return true; // Does not interrupt this ad session or terminate the overlay.
    }

    private int dp(int n) { return Math.round(n * service.getResources().getDisplayMetrics().density); }

    private GradientDrawable panelBackground() {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(UiPrefs.card(service));
        shape.setCornerRadius(dp(20));
        shape.setStroke(dp(1), UiPrefs.dark(service) ? 0xff526178 : 0xffd7e4e9);
        return shape;
    }

    private TextView label(String txt, int size, boolean bold) {
        TextView view = new TextView(service);
        view.setText(txt);
        view.setTextSize(size);
        view.setTextColor(UiPrefs.textColor(service));
        if (bold) view.setTypeface(null, android.graphics.Typeface.BOLD);
        return view;
    }

    private WindowManager.LayoutParams params(int width, int height, int gravity, int y) {
        WindowManager.LayoutParams result = new WindowManager.LayoutParams(
            dp(width), height, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT);
        result.gravity = gravity;
        result.y = dp(y);
        return result;
    }

    private void showSuggestion(String pkg) {
        if (!service.isFilteringActive() || !hasOverlayAccess(service)
            || !hasUsageAccess(service) || suggestion != null
            || !prefs().getBoolean(PREF_KEY, false) || !ASK.equals(choice(pkg))
            || !pkg.equals(foregroundPackage())) return;
        try {
            wm = service.getSystemService(WindowManager.class);
            if (wm == null) return;
            LinearLayout view = new LinearLayout(service);
            view.setOrientation(LinearLayout.VERTICAL);
            view.setPadding(dp(13), dp(11), dp(13), dp(11));
            view.setElevation(dp(10));
            view.setBackground(panelBackground());
            TextView heading = label(t("overlay_title"), 16, true);
            view.addView(heading);
            TextView detail = label(UiPrefs.format(service, "overlay_body", appLabel(pkg)), 13, false);
            detail.setPadding(0, dp(7), 0, dp(4));
            view.addView(detail);
            CheckBox remember = new CheckBox(service);
            remember.setText(t("overlay_remember"));
            remember.setTextColor(UiPrefs.textColor(service));
            remember.setTextSize(13);
            view.addView(remember);
            TextView warning = label(t("overlay_warning"), 11, false);
            warning.setPadding(0, 0, 0, dp(8));
            view.addView(warning);
            LinearLayout buttons = new LinearLayout(service);
            buttons.setOrientation(LinearLayout.HORIZONTAL);
            Button deny = new Button(service), allow = new Button(service);
            deny.setText(t("overlay_deny"));
            deny.setAllCaps(false);
            allow.setText(t("overlay_allow"));
            allow.setAllCaps(false);
            buttons.addView(deny, new LinearLayout.LayoutParams(0, dp(48), 1));
            buttons.addView(allow, new LinearLayout.LayoutParams(0, dp(48), 1));
            view.addView(buttons);

            deny.setOnClickListener(v -> {
                if (remember.isChecked()) saveChoice(pkg, BLOCK);
                dismissSuggestion();
            });
            allow.setOnClickListener(v -> {
                if (remember.isChecked()) saveChoice(pkg, ALLOW);
                lastAllowedApp = pkg;
                lastAllowedTime = SystemClock.elapsedRealtime();
                dismissSuggestion();
                service.allowAdsFor60Seconds();
            });
            wm.addView(view, params(340, WindowManager.LayoutParams.WRAP_CONTENT,
                Gravity.TOP | Gravity.CENTER_HORIZONTAL, 35));
            suggestion = view;
            closeSuggestion = this::dismissSuggestion;
            main.postDelayed(closeSuggestion, POPUP_MS);
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Popup unavailable", e);
            dismissSuggestion();
        }
    }

    /** The strip shows elapsed allowance time, NOT an invented ad-completion percentage. */
    /**
     * Consent session is NOT a verified rewarded-ad playback session. The timer
     * tracks the global DNS permission, never claims ad completion or reward.
     * Optional opaque overlay can hide playback; the user may reveal it at once.
     */
    void showStopControl() {
        main.post(() -> {
            if (!service.isFilteringActive() || !hasOverlayAccess(service)) return;
            dismissAllowance();
            boolean black = prefs().getBoolean("planned_black", true) && !revealVideoForSession;
            try {
                wm = service.getSystemService(WindowManager.class);
                if (wm == null) return;

                LinearLayout panel = new LinearLayout(service);
                panel.setOrientation(LinearLayout.VERTICAL);
                panel.setPadding(dp(16), dp(15), dp(16), dp(15));
                panel.setGravity(black ? Gravity.CENTER : Gravity.CENTER_VERTICAL);
                if (black) panel.setBackgroundColor(Color.BLACK);
                else panel.setBackground(panelBackground());

                TextView header = label(
                    black ? t("screen_black_active") : t("overlay_title"),
                    black ? 19 : 13, true);
                if (black) header.setTextColor(Color.WHITE);
                panel.addView(header);

                TextView elapsed = label("", black ? 17 : 12, false);
                if (black) elapsed.setTextColor(Color.WHITE);
                elapsed.setPadding(0, dp(9), 0, dp(8));
                panel.addView(elapsed);

                ProgressBar indicator = new ProgressBar(service, null,
                    android.R.attr.progressBarStyleHorizontal);
                indicator.setIndeterminate(true);
                indicator.setIndeterminateTintList(ColorStateList.valueOf(
                    UiPrefs.accent(service)));
                panel.addView(indicator, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, dp(5)));

                TextView explanation = label(black
                    ? t("screen_black_risk") : t("overlay_timer"), 11, false);
                if (black) explanation.setTextColor(Color.rgb(205, 218, 229));
                explanation.setPadding(0, dp(10), 0, dp(10));
                panel.addView(explanation);

                Button reveal = new Button(service);
                reveal.setAllCaps(false);
                reveal.setText(black ? t("show_video") : t("cover_screen"));
                reveal.setOnClickListener(v -> {
                    revealVideoForSession = black;
                    showStopControl();
                });
                panel.addView(reveal);

                Button next = new Button(service);
                next.setAllCaps(false);
                next.setText(t("overlay_stop_next"));
                next.setOnClickListener(v -> {
                    boolean saved = blockNextTime();
                    android.widget.Toast.makeText(service,
                        t(saved ? "choice_saved" : "no_context"),
                        android.widget.Toast.LENGTH_SHORT).show();
                });
                panel.addView(next);

                Button endNow = new Button(service);
                endNow.setAllCaps(false);
                endNow.setText(t("stop_current"));
                endNow.setOnClickListener(v -> {
                    service.blockAdsNow();
                    revealVideoForSession = false;
                });
                panel.addView(endNow);

                // A fullscreen overlay must never prevent the user stopping the VPN.
                Button stopVpn = new Button(service);
                stopVpn.setAllCaps(false);
                stopVpn.setText(t("emergency_stop"));
                stopVpn.setOnClickListener(v -> service.stopFromOverlay());
                panel.addView(stopVpn);

                WindowManager.LayoutParams overlayParams;
                if (black) {
                    overlayParams = new WindowManager.LayoutParams(
                        WindowManager.LayoutParams.MATCH_PARENT,
                        WindowManager.LayoutParams.MATCH_PARENT,
                        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                        PixelFormat.TRANSLUCENT);
                    overlayParams.gravity = Gravity.CENTER;
                } else {
                    overlayParams = params(330,
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 42);
                }
                wm.addView(panel, overlayParams);
                allowanceStrip = panel;
                refreshAllowance = new Runnable() {
                    @Override public void run() {
                        if (allowanceStrip != panel || !service.isFilteringActive()) return;
                        long seconds = service.remainingAllowanceSeconds();
                        if (seconds <= 0L) {
                            dismissAllowance();
                            revealVideoForSession = false;
                            return;
                        }
                        elapsed.setText(UiPrefs.format(service, "session_remaining",
                            seconds));
                        main.postDelayed(this, 1000L);
                    }
                };
                main.post(refreshAllowance);
            } catch (RuntimeException ex) {
                Log.w("AdsKill", "Session overlay not available", ex);
                dismissAllowance();
            }
        });
    }

    void hideStopControl() {
        main.post(() -> {
            revealVideoForSession = false;
            dismissAllowance();
        });
    }

    private void dismissSuggestion() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post(this::dismissSuggestion); return;
        }
        if (closeSuggestion != null) main.removeCallbacks(closeSuggestion);
        closeSuggestion = null;
        if (suggestion != null && wm != null) {
            try { wm.removeView(suggestion); } catch (RuntimeException ignored) {}
        }
        suggestion = null;
    }

    private void dismissAllowance() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post(this::dismissAllowance); return;
        }
        if (refreshAllowance != null) main.removeCallbacks(refreshAllowance);
        refreshAllowance = null;
        if (allowanceStrip != null && wm != null) {
            try { wm.removeView(allowanceStrip); } catch (RuntimeException ignored) {}
        }
        allowanceStrip = null;
    }

    void dismiss() {
        main.post(() -> {
            revealVideoForSession = false;
            dismissSuggestion();
            dismissAllowance();
        });
    }
}
