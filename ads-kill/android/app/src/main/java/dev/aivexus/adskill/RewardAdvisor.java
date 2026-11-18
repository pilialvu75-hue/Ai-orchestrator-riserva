package dev.aivexus.adskill;

import android.app.AppOpsManager;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.SharedPreferences;
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
import android.widget.TextView;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Experimental, opt-in popup for WeWard only. A DNS domain cannot identify
 * whether the ad is rewarded. Remembered "allow" is a heuristic and grants a
 * GLOBAL 60-second DNS exemption, not a per-app firewall permission.
 */
final class RewardAdvisor {
    static final String PREF_KEY = "smart_reward";
    static final String CHOICE_KEY = "reward_choice_weward";
    static final String ASK = "ask";
    static final String ALLOW = "allow";
    static final String BLOCK = "block";
    static final String WATCHED_PACKAGE = "com.weward";
    private static final long COOLDOWN_MS = 180_000L;
    private static final long POPUP_MS = 7_000L;
    private static final String PREFS = "ads_kill";

    private final AdsVpnService service;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean inspecting = new AtomicBoolean(false);
    private final AtomicLong lastSuggestionAt = new AtomicLong(0L);
    private WindowManager windows;
    private View suggestion;
    private View stopControl;
    private Runnable scheduledDismiss;
    private Runnable scheduledStopDismiss;

    RewardAdvisor(AdsVpnService service) { this.service = service; }

    static boolean hasUsageAccess(Context context) {
        AppOpsManager ops = context.getSystemService(AppOpsManager.class);
        return ops != null && ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(), context.getPackageName()) == AppOpsManager.MODE_ALLOWED;
    }

    static boolean hasOverlayAccess(Context context) {
        return Settings.canDrawOverlays(context);
    }

    private SharedPreferences prefs() {
        return service.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static String readChoice(SharedPreferences prefs) {
        String value = prefs.getString(CHOICE_KEY, ASK);
        if (ALLOW.equals(value) || BLOCK.equals(value)) return value;
        return ASK;
    }

    private void remember(String choice, boolean enabled) {
        if (!enabled) return;
        prefs().edit().putString(CHOICE_KEY, choice).apply();
    }

    /**
     * Called before deciding to block an ad-domain DNS request.
     * For a remembered allow, start a time-limited global exemption.
     * A newly detected candidate can be a normal ad, not a reward.
     */
    boolean autoAllowIfRemembered() {
        if (!service.isFilteringActive() || !prefs().getBoolean(PREF_KEY, false)
            || !ALLOW.equals(readChoice(prefs()))
            || !hasOverlayAccess(service) || !hasUsageAccess(service)) return false;
        if (!inspecting.compareAndSet(false, true)) return false;
        try {
            if (!isWeWardForeground()) return false;
            service.allowAdsFor60Seconds();
            return true;
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Smart Reward automatic choice unavailable", e);
            return false;
        } finally {
            inspecting.set(false);
        }
    }

    void onBlockedAdvertisingDomain() {
        SharedPreferences prefs = prefs();
        if (!prefs.getBoolean(PREF_KEY, false)
            || !ASK.equals(readChoice(prefs))) return;
        long now = SystemClock.elapsedRealtime();
        long last = lastSuggestionAt.get();
        if (last != 0 && now - last < COOLDOWN_MS) return;
        if (!hasOverlayAccess(service) || !hasUsageAccess(service)) return;
        if (!inspecting.compareAndSet(false, true)) return;
        try {
            if (!isWeWardForeground()) return;
            now = SystemClock.elapsedRealtime();
            last = lastSuggestionAt.get();
            if (last != 0 && now - last < COOLDOWN_MS) return;
            if (lastSuggestionAt.compareAndSet(last, now)) main.post(this::showSuggestion);
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Smart Reward foreground detection failed", e);
        } finally {
            inspecting.set(false);
        }
    }

    private boolean isWeWardForeground() {
        UsageStatsManager stats = service.getSystemService(UsageStatsManager.class);
        if (stats == null) return false;
        long now = System.currentTimeMillis();
        UsageEvents events = stats.queryEvents(now - 5 * 60_000L, now);
        if (events == null) return false;
        UsageEvents.Event event = new UsageEvents.Event();
        String foreground = null;
        while (events.hasNextEvent()) {
            events.getNextEvent(event);
            int kind = event.getEventType();
            if (kind == UsageEvents.Event.ACTIVITY_RESUMED) {
                foreground = event.getPackageName();
            } else if (kind == UsageEvents.Event.ACTIVITY_PAUSED
                && event.getPackageName().equals(foreground)) {
                foreground = null;
            }
        }
        return WATCHED_PACKAGE.equals(foreground);
    }

    private int dp(int value) {
        return Math.round(value * service.getResources().getDisplayMetrics().density);
    }

    private static GradientDrawable rounded(int color, int border) {
        GradientDrawable result = new GradientDrawable();
        result.setColor(color);
        result.setCornerRadius(22f);
        result.setStroke(2, border);
        return result;
    }

    private void showSuggestion() {
        if (!service.isFilteringActive() || !hasOverlayAccess(service)
            || !hasUsageAccess(service) || suggestion != null
            || !prefs().getBoolean(PREF_KEY, false)
            || !ASK.equals(readChoice(prefs()))) return;
        try {
            windows = service.getSystemService(WindowManager.class);
            if (windows == null) return;
            LinearLayout surface = new LinearLayout(service);
            surface.setOrientation(LinearLayout.VERTICAL);
            surface.setPadding(dp(14), dp(11), dp(14), dp(11));
            surface.setBackground(rounded(Color.WHITE, Color.rgb(216, 226, 235)));
            surface.setElevation(dp(9));

            TextView title = new TextView(service);
            title.setText("Ads Kill · possibile video premio");
            title.setTextColor(Color.rgb(16, 42, 67));
            title.setTypeface(null, android.graphics.Typeface.BOLD);
            title.setTextSize(16);
            surface.addView(title);
            TextView detail = new TextView(service);
            detail.setText("WeWard sta contattando un dominio pubblicitario. Non posso sapere se dà un premio.");
            detail.setTextSize(13);
            detail.setTextColor(Color.DKGRAY);
            surface.addView(detail);

            CheckBox remember = new CheckBox(service);
            remember.setText("Ricorda questa scelta per WeWard");
            remember.setTextSize(13);
            surface.addView(remember);
            TextView warning = new TextView(service);
            warning.setText("Se ricordi Consenti, verranno consentite anche possibili pubblicità normali.");
            warning.setTextColor(Color.DKGRAY);
            warning.setTextSize(11);
            surface.addView(warning);

            LinearLayout buttons = new LinearLayout(service);
            buttons.setOrientation(LinearLayout.HORIZONTAL);
            Button deny = new Button(service);
            deny.setAllCaps(false);
            deny.setText("Continua blocco");
            Button allow = new Button(service);
            allow.setAllCaps(false);
            allow.setText("Consenti 60 s");
            buttons.addView(deny, new LinearLayout.LayoutParams(0, dp(47), 1));
            buttons.addView(allow, new LinearLayout.LayoutParams(0, dp(47), 1));
            surface.addView(buttons);

            deny.setOnClickListener(v -> {
                remember(BLOCK, remember.isChecked());
                dismissSuggestion();
            });
            allow.setOnClickListener(v -> {
                remember(ALLOW, remember.isChecked());
                dismissSuggestion();
                service.allowAdsFor60Seconds();
            });

            WindowManager.LayoutParams layout = new WindowManager.LayoutParams(
                dp(342), WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
            layout.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
            layout.y = dp(46);
            windows.addView(surface, layout);
            suggestion = surface;
            scheduledDismiss = this::dismissSuggestion;
            main.postDelayed(scheduledDismiss, POPUP_MS);
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Unable to show reward suggestion", e);
            dismissSuggestion();
        }
    }

    /** Called after any manually or automatically permitted 60-second window. */
    void showStopControl() {
        main.post(() -> {
            if (!service.isFilteringActive() || !hasOverlayAccess(service)) return;
            dismissStopControl();
            try {
                windows = service.getSystemService(WindowManager.class);
                if (windows == null) return;
                Button stop = new Button(service);
                stop.setText("Blocca ora");
                stop.setAllCaps(false);
                stop.setTextColor(Color.WHITE);
                stop.setBackgroundTintList(android.content.res.ColorStateList.valueOf(
                    Color.rgb(150, 43, 48)));
                stop.setOnClickListener(v -> {
                    // If an automatic remembered allowance was in effect, revoke it.
                    // Otherwise the next blocked DNS request would immediately re-allow.
                    if (ALLOW.equals(readChoice(prefs()))) {
                        prefs().edit().putString(CHOICE_KEY, BLOCK).apply();
                    }
                    service.blockAdsNow();
                    dismissStopControl();
                });
                WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                    dp(156), dp(54), WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                    PixelFormat.TRANSLUCENT);
                params.gravity = Gravity.BOTTOM | Gravity.END;
                params.x = dp(12);
                params.y = dp(52);
                windows.addView(stop, params);
                stopControl = stop;
                scheduledStopDismiss = this::dismissStopControl;
                main.postDelayed(scheduledStopDismiss, 60_500L);
            } catch (RuntimeException e) {
                Log.w("AdsKill", "Could not show Stop control", e);
                dismissStopControl();
            }
        });
    }

    void hideStopControl() { main.post(this::dismissStopControl); }

    private void dismissSuggestion() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post(this::dismissSuggestion);
            return;
        }
        if (scheduledDismiss != null) main.removeCallbacks(scheduledDismiss);
        scheduledDismiss = null;
        if (suggestion != null && windows != null) {
            try { windows.removeView(suggestion); } catch (RuntimeException ignored) {}
        }
        suggestion = null;
    }

    private void dismissStopControl() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post(this::dismissStopControl);
            return;
        }
        if (scheduledStopDismiss != null) main.removeCallbacks(scheduledStopDismiss);
        scheduledStopDismiss = null;
        if (stopControl != null && windows != null) {
            try { windows.removeView(stopControl); } catch (RuntimeException ignored) {}
        }
        stopControl = null;
    }

    void dismiss() {
        main.post(() -> {
            dismissSuggestion();
            dismissStopControl();
        });
    }
}
