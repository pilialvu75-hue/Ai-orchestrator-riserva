package dev.aivexus.adskill;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/** Local, offline strings and colors for Italian, French, English, Spanish. */
final class UiPrefs {
    private static final String PREFS = "ads_kill";
    static final String LANG = "ui_language";
    static final String THEME = "ui_theme";

    private static final Map<String, String[]> STR = new HashMap<>();
    static {
        // Each entry: IT, FR, EN, ES
        put("app", "Ads Kill", "Ads Kill", "Ads Kill", "Ads Kill");
        put("subtitle", "Protezione intelligente, controllo semplice", "Protection intelligente, contrôle simple", "Smart protection, simple control", "Protección inteligente, control sencillo");
        put("home", "Home", "Accueil", "Home", "Inicio");
        put("settings", "Impostazioni", "Paramètres", "Settings", "Ajustes");
        put("section_protection", "PROTEZIONE", "PROTECTION", "PROTECTION", "PROTECCIÓN");
        put("section_permissions", "AUTORIZZAZIONI", "AUTORISATIONS", "PERMISSIONS", "PERMISOS");
        put("choices_count", "App con scelta ricordata: %d", "Applications avec choix mémorisé : %d", "Apps with remembered choices: %d", "Apps con opciones recordadas: %d");
        put("next_hint", "La scelta sarà registrata se Ads Kill ha identificato l'app della pubblicità.", "Le choix est mémorisé si Ads Kill a identifié l'appli publicitaire.", "Choice is saved if Ads Kill identified the ad app.", "La opción se guarda si Ads Kill identificó la app del anuncio.");
        put("black_default", "Schermo nero predefinito (previsto)", "Écran noir par défaut (prévu)", "Default black screen (planned)", "Pantalla negra predeterminada (previsto)");
        put("mute_default", "Muto predefinito (previsto)", "Son coupé par défaut (prévu)", "Mute by default (planned)", "Silencio predeterminado (previsto)");
        put("privacy_future", "Preferenze memorizzate per un motore futuro: in questa beta non oscurano né silenziano le altre app.", "Préférences enregistrées pour une future version : cette bêta ne masque ni ne coupe le son des autres applis.", "Preferences saved for a future engine: this beta does not black out or mute other apps.", "Preferencias guardadas para un motor futuro: esta beta no oscurece ni silencia otras apps.");
        put("status_on", "Protezione attiva", "Protection active", "Protection enabled", "Protección activada");
        put("status_off", "Protezione disattivata", "Protection désactivée", "Protection disabled", "Protección desactivada");
        put("start", "Attiva protezione", "Activer la protection", "Enable protection", "Activar protección");
        put("stop", "Disattiva protezione", "Désactiver la protection", "Disable protection", "Desactivar protección");
        put("dns_queries", "Richieste DNS", "Requêtes DNS", "DNS requests", "Solicitudes DNS");
        put("dns_blocked", "Pubblicità bloccate", "Publicités bloquées", "Ads blocked", "Anuncios bloqueados");
        put("pause", "Consenti 60 secondi", "Autoriser 60 secondes", "Allow for 60 seconds", "Permitir 60 segundos");
        put("pause_left", "Consenso attivo: %d s", "Autorisation active : %d s", "Allowed for: %d s", "Permitido durante: %d s");
        put("pause_off", "Blocco automatico attivo", "Blocage automatique actif", "Automatic blocking on", "Bloqueo automático activo");
        put("stop_next", "Blocca per la prossima volta", "Bloquer la prochaine fois", "Block next time", "Bloquear la próxima vez");
        put("stop_current", "Termina pausa ora", "Terminer la pause", "End allowance now", "Terminar pausa ahora");
        put("no_context", "Impossibile identificare l'app in primo piano", "Impossible d'identifier l'application active", "Unable to identify foreground app", "No se puede identificar la aplicación activa");
        put("next_saved", "Scelta salvata: questa pubblicità può terminare; la prossima verrà bloccata", "Choix mémorisé : cette publicité peut finir, la suivante sera bloquée", "Saved: this ad can finish; the next one will be blocked", "Guardado: este anuncio puede terminar; el próximo será bloqueado");
        put("section_smart", "SMART REWARD", "SMART REWARD", "SMART REWARD", "SMART REWARD");
        put("smart_switch", "Suggerisci una pausa per possibili video premio (tutte le app)", "Suggérer une pause pour les vidéos récompensées possibles (toutes les applis)", "Suggest an allowance for possible rewarded ads (all apps)", "Sugerir una pausa para posibles anuncios con recompensa (todas las apps)");
        put("smart_details", "Il riconoscimento è sperimentale: una richiesta DNS non prova che l'annuncio dia un premio.", "La détection est expérimentale : une requête DNS ne prouve pas qu'une pub donne une récompense.", "Detection is experimental: a DNS request does not prove an ad offers a reward.", "La detección es experimental: una solicitud DNS no demuestra que el anuncio dé un premio.");
        put("permission_overlay", "Autorizza popup sopra altre app", "Autoriser les fenêtres sur les autres applis", "Allow popups over other apps", "Permitir ventanas sobre otras apps");
        put("permission_usage", "Autorizza rilevamento app in primo piano", "Autoriser la détection de l'appli active", "Allow foreground-app detection", "Permitir detección de app activa");
        put("permission_status", "Popup: %s · Rilevamento: %s", "Fenêtres : %s · Détection : %s", "Popups: %s · Detection: %s", "Ventanas: %s · Detección: %s");
        put("yes", "sì", "oui", "yes", "sí");
        put("no", "no", "non", "no", "no");
        put("section_prefs", "ASPETTO E LINGUA", "APPARENCE ET LANGUE", "APPEARANCE & LANGUAGE", "APARIENCIA E IDIOMA");
        put("theme", "Tema", "Thème", "Theme", "Tema");
        put("language", "Lingua", "Langue", "Language", "Idioma");
        put("system", "Come il sistema", "Comme le système", "Follow system", "Según el sistema");
        put("light", "Chiaro", "Clair", "Light", "Claro");
        put("dark", "Scuro", "Sombre", "Dark", "Oscuro");
        put("italian", "Italiano", "Italien", "Italian", "Italiano");
        put("french", "Francese", "Français", "French", "Francés");
        put("english", "Inglese", "Anglais", "English", "Inglés");
        put("spanish", "Spagnolo", "Espagnol", "Spanish", "Español");
        put("section_updates", "AGGIORNAMENTI", "MISES À JOUR", "UPDATES", "ACTUALIZACIONES");
        put("check_updates", "Controlla nuove beta", "Rechercher des bêtas", "Check beta updates", "Buscar versiones beta");
        put("update_info", "Controllo manuale GitHub. Solo APK verificati con firma persistente.", "Vérification manuelle GitHub. Seulement APK vérifiés avec signature stable.", "Manual GitHub check. Only APKs with verified stable signing.", "Búsqueda manual en GitHub. Solo APK verificados con firma estable.");
        put("checking", "Controllo versioni...", "Recherche des versions...", "Checking versions...", "Buscando versiones...");
        put("no_updates", "Nessuna beta firmata più recente", "Pas de nouvelle bêta signée", "No newer signed beta", "Sin nueva beta firmada");
        put("new_version", "Nuova versione: %s", "Nouvelle version : %s", "New version: %s", "Nueva versión: %s");
        put("install_title", "Aggiornare Ads Kill?", "Mettre Ads Kill à jour ?", "Update Ads Kill?", "¿Actualizar Ads Kill?");
        put("download", "Scarica", "Télécharger", "Download", "Descargar");
        put("cancel", "Annulla", "Annuler", "Cancel", "Cancelar");
        put("install", "Installa", "Installer", "Install", "Instalar");
        put("download_progress", "Scaricamento e verifica SHA-256...", "Téléchargement et vérification SHA-256...", "Downloading and verifying SHA-256...", "Descargando y verificando SHA-256...");
        put("download_ready", "APK verificato; Android controllerà la firma.", "APK vérifié ; Android vérifiera la signature.", "APK verified; Android checks the signature.", "APK verificado; Android comprobará la firma.");
        put("section_policy", "SCELTE RICORDATE", "CHOIX MÉMORISÉS", "REMEMBERED CHOICES", "OPCIONES RECORDADAS");
        put("reset_choices", "Cancella le scelte ricordate", "Effacer les choix mémorisés", "Clear remembered choices", "Borrar opciones recordadas");
        put("reset_done", "Preferenze pubblicitarie azzerate", "Préférences publicitaires effacées", "Ad preferences cleared", "Preferencias de anuncios borradas");
        put("choice_intro", "Le scelte vengono salvate per singola app. Tutto resta sul dispositivo.", "Les choix sont mémorisés pour chaque appli et restent sur l'appareil.", "Choices are saved per app and stay on this device.", "Las opciones se guardan por app y permanecen en el dispositivo.");
        put("overlay_title", "Possibile annuncio premio", "Possible pub récompensée", "Possible rewarded ad", "Posible anuncio con recompensa");
        put("overlay_body", "Un dominio pubblicitario è stato richiesto mentre era aperta %s. Non posso verificare se dà un premio.", "Un domaine publicitaire a été demandé pendant que %s était ouverte. Récompense non confirmée.", "An ad domain was requested while %s was open. A reward is not confirmed.", "Se solicitó un dominio publicitario con %s abierta. No está confirmada la recompensa.");
        put("overlay_remember", "Ricorda per questa app", "Mémoriser pour cette appli", "Remember for this app", "Recordar para esta app");
        put("overlay_deny", "Continua blocco", "Continuer le blocage", "Keep blocking", "Seguir bloqueando");
        put("overlay_allow", "Consenti 60 s", "Autoriser 60 s", "Allow 60 s", "Permitir 60 s");
        put("overlay_warning", "Ricordare Consenti può autorizzare anche annunci normali.", "Mémoriser Autoriser peut aussi accepter des pubs normales.", "Remembering Allow may also permit ordinary ads.", "Recordar Permitir también puede aceptar anuncios normales.");
        put("overlay_stop_next", "Blocca per la prossima volta", "Bloquer la prochaine fois", "Block next time", "Bloquear la próxima vez");
        put("overlay_elapsed", "Pubblicità non verificata · consenso: %d s", "Pub non vérifiée · autorisation : %d s", "Unverified ad · allowance: %d s", "Anuncio no verificado · permiso: %d s");
        put("overlay_timer", "Tempo trascorso, non avanzamento reale", "Temps écoulé, pas progression réelle", "Elapsed time, not real ad progress", "Tiempo transcurrido, no progreso real");
        put("privacy", "MODALITÀ SCHERMO", "MODE ÉCRAN", "SCREEN MODE", "MODO PANTALLA");
        put("privacy_info", "Schermo nero, audio muto e avanzamento reale richiedono il riconoscimento affidabile di un video premio. Funzioni in studio; non si attivano ancora automaticamente.", "Écran noir, son coupé et progression réelle nécessitent une détection fiable des pubs récompensées. Non activés automatiquement.", "Black screen, mute and real progress need reliable rewarded-ad detection. Not automatically enabled yet.", "Pantalla negra, silencio y progreso real requieren detectar los anuncios con premio de forma fiable. Aún no se activan automáticamente.");
        put("internet_warning", "Se Internet non funziona, disattiva la VPN Ads Kill.", "Si Internet ne fonctionne plus, désactivez le VPN Ads Kill.", "If Internet stops working, disable the Ads Kill VPN.", "Si Internet deja de funcionar, desactiva la VPN Ads Kill.");
        put("permission_needed", "Concedi entrambe le autorizzazioni per Smart Reward.", "Accordez les deux autorisations pour Smart Reward.", "Grant both permissions for Smart Reward.", "Concede ambos permisos para Smart Reward.");
        put("update_unavailable", "Versione più recente disponibile, ma senza firma persistente. Nessun aggiornamento sicuro possibile.", "Une version récente existe sans signature stable. Mise à jour sécurisée indisponible.", "Newer release exists without stable signing. Safe in-place update unavailable.", "Hay una versión nueva sin firma estable. Actualización segura no disponible.");
    }

    private static void put(String key, String it, String fr, String en, String es) {
        STR.put(key, new String[] {it, fr, en, es});
    }

    static SharedPreferences preferences(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static String language(Context c) {
        String selected = preferences(c).getString(LANG, "system");
        if ("system".equals(selected)) selected = Locale.getDefault().getLanguage();
        if ("fr".equals(selected) || "en".equals(selected) || "es".equals(selected)) return selected;
        return "it";
    }

    static String text(Context c, String key) {
        String[] translation = STR.get(key);
        if (translation == null) return key;
        switch (language(c)) {
            case "fr": return translation[1];
            case "en": return translation[2];
            case "es": return translation[3];
            default: return translation[0];
        }
    }

    static String format(Context c, String key, Object... args) {
        return String.format(Locale.forLanguageTag(language(c)), text(c, key), args);
    }

    static boolean dark(Context c) {
        String preferred = preferences(c).getString(THEME, "system");
        if ("dark".equals(preferred)) return true;
        if ("light".equals(preferred)) return false;
        return (c.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
            == Configuration.UI_MODE_NIGHT_YES;
    }

    static int background(Context c) { return dark(c) ? Color.rgb(12, 20, 33) : Color.rgb(243, 247, 251); }
    static int card(Context c) { return dark(c) ? Color.rgb(27, 39, 58) : Color.WHITE; }
    static int textColor(Context c) { return dark(c) ? Color.rgb(234, 242, 250) : Color.rgb(22, 42, 66); }
    static int secondary(Context c) { return dark(c) ? Color.rgb(179, 196, 211) : Color.rgb(80, 102, 123); }
    static int accent(Context c) { return dark(c) ? Color.rgb(85, 220, 179) : Color.rgb(0, 120, 96); }
}
