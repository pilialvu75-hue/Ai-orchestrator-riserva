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
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Optional, local-only Smart Reward prototype for WeWard.
 *
 * A blocked DNS request is NOT proof of a reward advertisement. The prompt
 * deliberately says "possible" and asks the user to decide. No accessibility
 * service, screenshots, touch interception or personal-content analysis.
 *
 * The feature is opt-in. It needs both special permissions:
 * PACKAGE_USAGE_STATS (foreground app heuristic) and SYSTEM_ALERT_WINDOW
 * (small popup over WeWard). If either is missing it stays silent.
 */
final class RewardAdvisor {
    static final String PREF_KEY = "smart_reward";
    static final String WATCHED_PACKAGE = "com.weward";
    private static final long COOLDOWN_MS = 180_000L;
    private static final long POPUP_MS = 7_000L;
    private static final String PREFS = "ads_kill";

    private final AdsVpnService service;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean inspecting = new AtomicBoolean(false);
    private final AtomicLong lastSuggestionAt = new AtomicLong(0L);

    private WindowManager windows;
    private View popup;
    private Runnable scheduledDismiss;

    RewardAdvisor(AdsVpnService service) {
        this.service = service;
    }

    static boolean hasUsageAccess(Context context) {
        AppOpsManager ops = context.getSystemService(AppOpsManager.class);
        return ops != null && ops.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.getPackageName()) == AppOpsManager.MODE_ALLOWED;
    }

    static boolean hasOverlayAccess(Context context) {
        return Settings.canDrawOverlays(context);
    }

    void onBlockedAdvertisingDomain() {
        SharedPreferences prefs = service.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!prefs.getBoolean(PREF_KEY, false)) return;
        long now = SystemClock.elapsedRealtime();
        long last = lastSuggestionAt.get();
        if (last != 0L && now - last < COOLDOWN_MS) return;
        if (!hasOverlayAccess(service) || !hasUsageAccess(service)) return;
        if (!inspecting.compareAndSet(false, true)) return;
        try {
            if (!isWeWardForeground()) return;
            now = SystemClock.elapsedRealtime();
            last = lastSuggestionAt.get();
            if (last != 0L && now - last < COOLDOWN_MS) return;
            if (lastSuggestionAt.compareAndSet(last, now)) {
                main.post(this::showSuggestion);
            }
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Smart Reward context detection failed", e);
        } finally {
            inspecting.set(false);
        }
    }

    private boolean isWeWardForeground() {
        UsageStatsManager stats = service.getSystemService(UsageStatsManager.class);
        if (stats == null) return false;
        long now = System.currentTimeMillis();
        // Only the foreground package name is checked; no app data is read.
        UsageEvents events = stats.queryEvents(now - 6 * 60 * 60 * 1000L, now);
        if (events == null) return false;
        UsageEvents.Event event = new UsageEvents.Event();
        String latest = null;
        while (events.hasNextEvent()) {
            events.getNextEvent(event);
            int kind = event.getEventType();
            if (kind == UsageEvents.Event.ACTIVITY_RESUMED) {
                latest = event.getPackageName();
            } else if (kind == UsageEvents.Event.ACTIVITY_PAUSED
                    && event.getPackageName().equals(latest)) {
                latest = null;
            }
        }
        return WATCHED_PACKAGE.equals(latest);
    }

    private static GradientDrawable rounded(int color, int border) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(color);
        background.setCornerRadius(22f);
        background.setStroke(2, border);
        return background;
    }

    private int dp(int value) {
        return Math.round(value * service.getResources().getDisplayMetrics().density);
    }

    private void showSuggestion() {
        if (!AdsVpnService.active || !hasOverlayAccess(service)
                || !hasUsageAccess(service) || popup != null
                || !service.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getBoolean(PREF_KEY, false)) return;
        try {
            windows = service.getSystemService(WindowManager.class);
            if (windows == null) return;

            LinearLayout surface = new LinearLayout(service);
            surface.setOrientation(LinearLayout.VERTICAL);
            surface.setPadding(dp(15), dp(12), dp(15), dp(12));
            surface.setBackground(rounded(Color.WHITE, Color.rgb(216, 226, 235)));
            surface.setElevation(dp(10));

            TextView heading = new TextView(service);
            heading.setText("Ads Kill · possibile video premio");
            heading.setTypeface(null, android.graphics.Typeface.BOLD);
            heading.setTextColor(Color.rgb(16, 42, 67));
            heading.setTextSize(16);
            surface.addView(heading);

            TextView detail = new TextView(service);
            detail.setText("WeWard ha tentato di caricare una pubblicità. "
                + "Non posso sapere se dà un premio. Vuoi consentirla per 60 secondi?");
            detail.setTextColor(Color.DKGRAY);
            detail.setTextSize(13);
            detail.setPadding(0, dp(6), 0, dp(9));
            surface.addView(detail);

            LinearLayout buttons = new LinearLayout(service);
            buttons.setOrientation(LinearLayout.HORIZONTAL);
            Button ignore = new Button(service);
            ignore.setText("Continua blocco");
            ignore.setAllCaps(false);
            Button allow = new Button(service);
            allow.setText("Consenti 60 s");
            allow.setAllCaps(false);
            buttons.addView(ignore, new LinearLayout.LayoutParams(0, dp(49), 1));
            buttons.addView(allow, new LinearLayout.LayoutParams(0, dp(49), 1));
            surface.addView(buttons);

            ignore.setOnClickListener(v -> dismiss());
            allow.setOnClickListener(v -> {
                service.allowAdsFor60Seconds();
                dismiss();
            });

            WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                dp(342), WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
            params.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
            params.y = dp(60);
            windows.addView(surface, params);
            popup = surface;
            scheduledDismiss = this::dismiss;
            main.postDelayed(scheduledDismiss, POPUP_MS);
        } catch (RuntimeException e) {
            Log.w("AdsKill", "Could not show Smart Reward popup", e);
            dismiss();
        }
    }

    void dismiss() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post(this::dismiss);
            return;
        }
        if (scheduledDismiss != null) main.removeCallbacks(scheduledDismiss);
        scheduledDismiss = null;
        if (popup != null && windows != null) {
            try { windows.removeView(popup); }
            catch (RuntimeException e) {
                Log.w("AdsKill", "Popup already detached", e);
            }
        }
        popup = null;
        windows = null;
    }
}
