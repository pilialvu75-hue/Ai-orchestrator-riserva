package dev.aivexus.adskill;

import java.util.Locale;

/**
 * Small, deliberately conservative offline starter list.
 * DNS filtering cannot block in-stream ads or applications using their own DoH.
 */
public final class BlockRules {
    private static final String[] DOMAIN_SUFFIXES = {
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "ads.mopub.com",
        "unityads.unity3d.com",
        "ads.unity3d.com",
        "applovin.com",
        "applvn.com",
        "vungle.com",
        "adcolony.com",
        "chartboost.com",
        "inmobi.com",
        "smaato.net",
        "tapjoy.com",
        "fyber.com",
        "mintegral.com",
        "supersonicads.com",
        "startappservice.com"
    };

    private BlockRules() {}

    public static boolean shouldBlock(String host) {
        if (host == null || host.isEmpty()) return false;
        String name = host.toLowerCase(Locale.ROOT);
        for (String suffix : DOMAIN_SUFFIXES) {
            if (name.equals(suffix) || name.endsWith("." + suffix)) return true;
        }
        return false;
    }

    public static int count() { return DOMAIN_SUFFIXES.length; }
}
