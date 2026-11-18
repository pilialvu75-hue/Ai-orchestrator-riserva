package dev.aivexus.adskill;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.net.Uri;
import android.provider.Settings;
import android.widget.CheckBox;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.graphics.Color;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

public final class MainActivity extends Activity {
    private TextView status;
    private TextView counters;
    private TextView pauseStatus;
    private Button toggle;
    private Button pause;
    private CheckBox smartReward;
    private TextView smartStatus;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private final Runnable periodicUpdate = new Runnable() {
        @Override public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };
    private final BroadcastReceiver updates = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { refresh(); }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Color.rgb(247, 249, 252));
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(28, 40, 28, 32);
        scroll.addView(root);

        addText(root, "Ads Kill", 32, Color.rgb(20, 39, 64), true);
        addText(root, "Beta Android 0.1.1 · Smart Reward sperimentale", 14, Color.DKGRAY, false);
        status = addText(root, "", 23, Color.rgb(24, 99, 64), true);
        toggle = addButton(root, "Avvia protezione", v -> toggle());
        pause = addButton(root, "Consenti pubblicità per 60 secondi", v -> {
            startService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_ALLOW_60));
            Toast.makeText(this, "Blocco sospeso per 60 secondi", Toast.LENGTH_SHORT).show();
            refresh();
        });
        pauseStatus = addText(root, "", 15, Color.rgb(128, 69, 13), false);
        counters = addText(root, "", 19, Color.rgb(20, 39, 64), true);

        addText(root, "SMART REWARD · WeWard", 16, Color.rgb(20, 39, 64), true);
        smartReward = new CheckBox(this);
        smartReward.setText("Suggerisci la pausa con un popup (solo WeWard)");
        smartReward.setTextSize(15);
        smartReward.setChecked(getSharedPreferences("ads_kill", MODE_PRIVATE)
            .getBoolean(RewardAdvisor.PREF_KEY, false));
        smartReward.setOnCheckedChangeListener((button, checked) -> {
            getSharedPreferences("ads_kill", MODE_PRIVATE).edit()
                .putBoolean(RewardAdvisor.PREF_KEY, checked).apply();
            if (checked && (!RewardAdvisor.hasOverlayAccess(this)
                || !RewardAdvisor.hasUsageAccess(this))) {
                Toast.makeText(this, "Concedi le due autorizzazioni qui sotto per i popup",
                    Toast.LENGTH_LONG).show();
            }
            refresh();
        });
        root.addView(smartReward);
        addButton(root, "1. Autorizza popup sopra altre app", v -> {
            Intent permission = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + getPackageName()));
            startActivity(permission);
        });
        addButton(root, "2. Autorizza accesso app in primo piano", v ->
            startActivity(new Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)));
        smartStatus = addText(root, "", 14, Color.DKGRAY, false);
        addText(root,
            "Avviso opzionale di 7 secondi, non più di una volta ogni 3 minuti. "
          + "Non legge lo schermo o i tuoi dati: considera solo l'app in primo piano "
          + "e i domini DNS bloccati. Un annuncio normale può sembrare ricompensato. "
          + "Dopo aver premuto Consenti, riprova il video premio in WeWard.",
            14, Color.DKGRAY, false);

        addText(root, "COME FUNZIONA", 16, Color.rgb(20, 39, 64), true);
        addText(root,
            "La VPN locale intercetta soltanto le richieste DNS dirette al resolver configurato. "
          + "Blocca un elenco iniziale di " + BlockRules.count() + " domini pubblicitari. "
          + "Le richieste consentite sono risolte mediante Cloudflare (1.1.1.1 / 1.0.0.1). "
          + "Nessun server AIVEXUS riceve dati.", 15, Color.DKGRAY, false);
        addText(root, "LIMITI DEL PROTOTIPO", 16, Color.rgb(20, 39, 64), true);
        addText(root,
            "Non blocca la pubblicità integrata nei video YouTube, il traffico di app che usa "
          + "DNS cifrato proprio o pubblicità proveniente dal dominio principale del servizio. "
          + "Non è compatibile contemporaneamente con altre VPN Android. "
          + "La sospensione di 60 secondi è globale, non limitata a un gioco. "
          + "Se Internet non funziona, disattiva la protezione.", 15, Color.DKGRAY, false);
        setContentView(scroll);
        refresh();
    }

    private TextView addText(LinearLayout root, String value, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(value);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(null, android.graphics.Typeface.BOLD);
        t.setPadding(0, 10, 0, 14);
        root.addView(t);
        return t;
    }

    private Button addButton(LinearLayout root, String title, View.OnClickListener click) {
        Button b = new Button(this);
        b.setText(title);
        b.setAllCaps(false);
        b.setOnClickListener(click);
        root.addView(b);
        return b;
    }

    private void toggle() {
        if (AdsVpnService.active) {
            startService(new Intent(this, AdsVpnService.class).setAction(AdsVpnService.ACTION_STOP));
        } else {
            Intent consent = VpnService.prepare(this);
            if (consent != null) startActivityForResult(consent, 101);
            else startVpn();
        }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == 101 && resultCode == RESULT_OK) startVpn();
    }

    private void startVpn() {
        try {
            startForegroundService(new Intent(this, AdsVpnService.class)
                .setAction(AdsVpnService.ACTION_START));
        } catch (Exception e) {
            Toast.makeText(this, "Impossibile avviare VPN: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
        refresh();
    }

    private void refresh() {
        if (status == null) return;
        boolean on = AdsVpnService.active;
        status.setText(on ? "● Protezione attiva" : "○ Protezione disattivata");
        status.setTextColor(on ? Color.rgb(20, 125, 80) : Color.rgb(135, 65, 56));
        toggle.setText(on ? "Disattiva protezione" : "Avvia protezione");
        pause.setEnabled(on);
        SharedPreferences prefs = getSharedPreferences("ads_kill", MODE_PRIVATE);
        counters.setText("Richieste DNS: " + prefs.getLong("queries", 0)
            + "\nPubblicità bloccate: " + prefs.getLong("blocked", 0));
        if (smartStatus != null) {
            boolean overlay = RewardAdvisor.hasOverlayAccess(this);
            boolean usage = RewardAdvisor.hasUsageAccess(this);
            smartStatus.setText("Popup: " + (overlay ? "OK" : "non autorizzati")
                + " · Accesso app in primo piano: " + (usage ? "OK" : "non autorizzato")
                + " · Smart Reward: "
                + (prefs.getBoolean(RewardAdvisor.PREF_KEY, false) ? "richiesto" : "spento"));
        }
        long left = Math.max(0, (prefs.getLong("allow_until", 0) - System.currentTimeMillis() + 999) / 1000);
        pauseStatus.setText(left > 0 && on ? "Pubblicità temporaneamente consentita: " + left + " s"
            : "La sospensione si riattiva automaticamente dopo 60 secondi.");
    }

    @Override protected void onResume() {
        super.onResume();
        IntentFilter filter = new IntentFilter(AdsVpnService.STATUS);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(updates, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(updates, filter);
        }
        handler.post(periodicUpdate);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(periodicUpdate);
        unregisterReceiver(updates);
        super.onPause();
    }
}
