# AIVEXUS — collaudo audio Android 17 / Galaxy S24 FE

**Ramo:** PR #1027 integrata e collaudata sulla beta 104018 per la riproduzione in background. Seguito: PR #1034 (Stop/cambio messaggio) e ramo dipendente per segnalibro dopo perdita permanente dell'audio focus.

> La CI verifica che il codice compili e che i contratti rimangano integri, ma non certifica il comportamento del telefono fisico. Installare **solo** da Impostazioni → Aggiornamenti dopo release beta autorizzata, mai APK manuali, mai disinstallare l'app. Non cambiare impostazioni della batteria per mascherare un difetto. Il microfono STT deve continuare a funzionare.

## Scenario utente (senza computer)

1. In AIVEXUS, aprire una risposta lunga (2–10 minuti) e toccare l'altoparlante.
2. Dopo 20 secondi, mettere **Pausa** per 30 secondi. Riprendere. Il testo **non deve ricominciare**; il tempo deve continuare dal punto salvato.
3. Provare **indietro 10 s**, **avanti 10 s** e trascinamento dello slider durante la sintesi ancora in corso. La posizione non può superare la porzione PCM già generata.
4. Tornare indietro nella conversazione e aprire un'altra chat: l'audio deve continuare. Tornare alla prima chat e confermare lo stesso punto della traccia.
5. Premere Home, aprire una seconda app, spegnere lo schermo. La lettura deve continuare tramite servizio foreground, anche con schermo bloccato.
6. Usare dalla notifica / schermata di blocco **Pausa, Riprendi, -10 s, +10 s, Chiudi**. I comandi devono agire sullo stesso audio e la posizione deve restare coerente.
7. Provare auricolari Bluetooth e cablati: staccandoli durante la lettura l'audio deve **fermarsi in pausa**, senza uscire improvvisamente dallo speaker.
8. Durante una chiamata o altra app con audio focus, AIVEXUS deve rispettare la perdita audio; deve riprendere automaticamente solo dopo una perdita **transitoria** e soltanto se l'utente non aveva già premuto Pausa.
   - **Perdita permanente (YouTube):** il servizio si chiude, senza riproduzione parallela. Tornare su AIVEXUS e toccare **esplicitamente** lo stesso messaggio: dopo la rigenerazione locale, deve partire dal segnalibro del clock PCM misurato, **senza riprodurre l'inizio**. Il segnalibro è solo nella memoria dell'app (non persiste se Android termina il processo).
   - **Stop esplicito, tasto Chiudi della notifica, fine naturale o testo diverso:** nessun segnalibro, la nuova lettura parte dall'inizio. Le cuffie non sono ancora state collaudate sul dispositivo.
   - **Tempo di ripresa:** potrebbe esserci attesa mentre Kokoro rigenera silenziosamente le frasi precedenti; questa funzione preserva il punto, non garantisce ripartenza immediata.
9. A lettura finita o chiusa, la notifica del servizio deve sparire e la cache PCM privata essere rilasciata. Nuovo tap sull'altoparlante deve creare una nuova sessione, senza audio duplicato.
10. Provare microfono/dettatura dopo l'uso audio e verificare che restino funzionanti. Ripetere con Wi-Fi spento: lettura locale non deve dipendere dal Cloud.

**Segnalare**: versione app, Android 17 versione software, passaggio preciso, durata della risposta e se audio/indicatore si sono fermati, senza condividere messaggi personali.

## Diagnostica avanzata (facoltativa, tramite adb sul computer)

Controllare le registrazioni del servizio:

```bash
adb shell dumpsys activity services com.aiorchestrator
adb shell dumpsys media_session
adb shell dumpsys audio
adb logcat -d | grep -E 'AudioHardening|aivexus_read_aloud|PCM_TRANSPORT|MEDIA_SERVICE'
```

Su Android 17 Beta 3+ si può forzare la modalità diagnostica dell'hardening del framework audio:

```bash
adb shell cmd audio set-enable-hardening throw
```

L'opzione `throw` trasforma alcuni errori altrimenti silenziosi in fallimenti osservabili. Ripristinare la modalità di default secondo la propria configurazione (o usare `disable` solo per confronti diagnostici temporanei). Non è necessario eseguire questi comandi per il normale test nell'app.

## Gate di accettazione

- CI Android nativa: `Assistant Android Source Validation` con `scripts/check_android_read_aloud_service.py` + compilazione debug ARM64.
- CI Flutter multi-OS e verifiche condivise.
- Prova fisica S24 FE nelle condizioni sopra, inclusi Home, altra app e lock screen.
- Nessuna regressione microfono, TTS local, memoria, HYBRID, updater e ricerca internet.
- La PR resta aperta finché manca il collaudo fisico.
