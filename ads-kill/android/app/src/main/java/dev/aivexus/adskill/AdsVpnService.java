package dev.aivexus.adskill;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.system.OsConstants;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * DNS-only VPN. Android's resolver targets 10.88.0.2 via the TUN;
 * ordinary app traffic is NOT routed into the VPN.
 * Non-DNS and IPv6 traffic never enters this route.
 */
public final class AdsVpnService extends VpnService {
    public static final String ACTION_START = "dev.aivexus.adskill.START";
    public static final String ACTION_STOP = "dev.aivexus.adskill.STOP";
    public static final String ACTION_ALLOW_60 = "dev.aivexus.adskill.ALLOW_60";
    public static final String ACTION_BLOCK_NOW = "dev.aivexus.adskill.BLOCK_NOW";
    public static final String ACTION_BLOCK_NEXT = "dev.aivexus.adskill.BLOCK_NEXT";
    public static final String STATUS = "dev.aivexus.adskill.STATUS";
    public static volatile boolean active = false;

    private static final String CHANNEL_ID = "ads_kill_filter";
    private static final String PREFS = "ads_kill";
    static final String PREF_VPN_REQUESTED = "vpn_user_requested_on";
    private final AtomicBoolean running = new AtomicBoolean(false);
    private ExecutorService workers;
    private ParcelFileDescriptor tun;
    private FileOutputStream out;
    private RewardAdvisor rewardAdvisor;
    private SessionAudio sessionAudio;

    @Override public void onCreate() {
        super.onCreate();
        rewardAdvisor = new RewardAdvisor(this);
        sessionAudio = new SessionAudio(this);
        sessionAudio.recoverStale();
    }

    boolean isFilteringActive() { return running.get() && tun != null; }
    long remainingAllowanceSeconds() {
        long ms = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getLong("allow_until", 0L) - System.currentTimeMillis();
        return Math.max(0L, (ms + 999L) / 1000L);
    }

    void allowAdsFor60Seconds() {
        if (!isFilteringActive()) return;
        long until = System.currentTimeMillis() + 60000L;
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putLong("allow_until", until).apply();
        if (sessionAudio != null) sessionAudio.begin(until);
        notifyStatus();
        if (rewardAdvisor != null) rewardAdvisor.showStopControl();
    }

    void blockAdsNow() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        SharedPreferences.Editor edit = prefs.edit()
            .putLong("allow_until", 0L)
            // Prevent immediate re-allow without changing the user's remembered rule.
            .putLong("manual_block_until", System.currentTimeMillis() + 60_000L);
        edit.apply();
        if (sessionAudio != null) sessionAudio.restore();
        if (rewardAdvisor != null) rewardAdvisor.hideStopControl();
        notifyStatus();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        // A killed VPN must never resurrect without a new explicit user action.
        String action = intent == null ? ACTION_STOP : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(PREF_VPN_REQUESTED, false).commit();
            shutdownVpn();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (ACTION_ALLOW_60.equals(action)
            || ACTION_BLOCK_NOW.equals(action) || ACTION_BLOCK_NEXT.equals(action)) {
            if (!isFilteringActive()) {
                stopSelf();
                return START_NOT_STICKY;
            }
            if (ACTION_ALLOW_60.equals(action)) allowAdsFor60Seconds();
            else if (ACTION_BLOCK_NOW.equals(action)) blockAdsNow();
            else if (rewardAdvisor != null) rewardAdvisor.blockNextTime();
            return START_NOT_STICKY;
        }
        // An ACTION_START is only valid if explicitly requested from Ads Kill UI.
        // A process restart or stale queued start may never re-enable the VPN.
        if (!ACTION_START.equals(action)
            || !getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(PREF_VPN_REQUESTED, false)) {
            shutdownVpn();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!running.compareAndSet(false, true)) return START_NOT_STICKY;
        active = true;
        try {
            createChannel();
            startForeground(17, makeNotification());
            Builder builder = new Builder()
                .setSession("Ads Kill DNS")
                .setMtu(4096)
                .addAddress("10.88.0.1", 32)
                .addRoute("10.88.0.2", 32)
                .addDnsServer("10.88.0.2")
                .allowFamily(OsConstants.AF_INET6);
            builder.setBlocking(true);
            tun = builder.establish();
            if (tun == null) throw new IOException("VPN authorization not granted");
            out = new FileOutputStream(tun.getFileDescriptor());
            workers = Executors.newFixedThreadPool(6);
            new Thread(this::serve, "ads-kill-dns").start();
            notifyStatus();
        } catch (Exception e) {
            Log.e("AdsKill", "Could not start DNS VPN", e);
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(PREF_VPN_REQUESTED, false).apply();
            shutdownVpn();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void serve() {
        try {
            FileInputStream in = new FileInputStream(tun.getFileDescriptor());
            byte[] buf = new byte[8192];
            while (running.get()) {
                int n = in.read(buf);
                if (n <= 0) continue;
                DnsPackets request = DnsPackets.decode(buf, n);
                if (request == null) continue;
                // Drop under saturation; do not block Android's TUN reader.
                workers.execute(() -> respond(request));
            }
        } catch (Exception e) {
            if (running.get()) Log.e("AdsKill", "DNS tunnel reader terminated", e);
        } finally {
            if (running.get()) stopSelf();
        }
    }

    private void respond(DnsPackets p) {
        if (!running.get()) return;
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        boolean adDomain = BlockRules.shouldBlock(p.domain);
        boolean allow = System.currentTimeMillis() < prefs.getLong("allow_until", 0L);
        if (!allow && adDomain && rewardAdvisor != null) {
            allow = rewardAdvisor.autoAllowIfRemembered();
        }
        boolean block = !allow && adDomain;
        byte[] response = block ? p.blockedResponse() : forwardDns(p.query);
        if (response != null && response.length >= 12) {
            byte[] reply = p.packetForResponse(response);
            if (reply != null) {
                try {
                    synchronized (this) {
                        if (running.get() && out != null) out.write(reply);
                    }
                } catch (IOException e) {
                    Log.w("AdsKill", "VPN response write failed", e);
                }
            }
        }
        prefs.edit()
            .putLong("queries", prefs.getLong("queries", 0) + 1)
            .putLong("blocked", prefs.getLong("blocked", 0) + (block ? 1 : 0))
            .apply();
        notifyStatus();
        if (block && rewardAdvisor != null) rewardAdvisor.onBlockedAdvertisingDomain(p.domain);
    }

    private byte[] forwardDns(byte[] query) {
        String[] upstream = {"1.1.1.1", "1.0.0.1"};
        for (String address : upstream) {
            try (DatagramSocket socket = new DatagramSocket()) {
                if (!protect(socket)) return null;
                socket.setSoTimeout(2000);
                byte[] ip = InetAddress.getByName(address).getAddress();
                socket.send(new DatagramPacket(query, query.length, InetAddress.getByAddress(ip), 53));
                byte[] data = new byte[4096];
                DatagramPacket answer = new DatagramPacket(data, data.length);
                socket.receive(answer);
                byte[] response = Arrays.copyOf(data, answer.getLength());
                if (response.length >= 12
                    && response[0] == query[0] && response[1] == query[1]
                    && (response[2] & 0x80) != 0) return response;
            } catch (SocketTimeoutException e) {
                Log.w("AdsKill", "DNS upstream timeout: " + address);
            } catch (Exception e) {
                Log.w("AdsKill", "DNS upstream unavailable: " + address, e);
            }
        }
        return null;
    }

    private void createChannel() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Ads Kill VPN",
            NotificationManager.IMPORTANCE_LOW);
        nm.createNotificationChannel(channel);
    }

    private Notification makeNotification() {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Intent stop = new Intent(this, AdsVpnService.class).setAction(ACTION_STOP);
        PendingIntent stopPending = PendingIntent.getService(this, 17, stop,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Ads Kill")
            .setContentText(UiPrefs.text(this, "status_on") + " · DNS Cloudflare")
            .setOngoing(true)
            .setContentIntent(pending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel,
                UiPrefs.text(this, "stop"), stopPending)
            .build();
    }

    private void notifyStatus() {
        sendBroadcast(new Intent(STATUS).setPackage(getPackageName()));
    }

    /**
     * Shut down the actual VPN interface immediately, not merely its command
     * queue. Safe to call repeatedly from UI, notification, revoke or destroy.
     */
    private void shutdownVpn() {
        running.set(false);
        active = false;
        // Close the TUN first so Android releases the VPN and the reader unblocks.
        ParcelFileDescriptor oldTun = tun;
        tun = null;
        try { if (oldTun != null) oldTun.close(); } catch (IOException ignored) {}
        FileOutputStream oldOut = out;
        out = null;
        try { if (oldOut != null) oldOut.close(); } catch (IOException ignored) {}
        ExecutorService oldWorkers = workers;
        workers = null;
        if (oldWorkers != null) oldWorkers.shutdownNow();
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putLong("allow_until", 0L).apply();
        if (sessionAudio != null) sessionAudio.restore();
        if (rewardAdvisor != null) rewardAdvisor.dismiss();
        stopForeground(STOP_FOREGROUND_REMOVE);
        notifyStatus();
    }

    /** Exposed only to the app's own in-process emergency overlay. */
    void stopFromOverlay() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(PREF_VPN_REQUESTED, false).commit();
        shutdownVpn();
        stopSelf();
    }

    @Override public void onRevoke() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(PREF_VPN_REQUESTED, false).apply();
        shutdownVpn();
        stopSelf();
        super.onRevoke();
    }

    @Override public void onDestroy() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(PREF_VPN_REQUESTED, false).apply();
        shutdownVpn();
        super.onDestroy();
    }

    @Override public android.os.IBinder onBind(Intent intent) {
        return super.onBind(intent);
    }
}
