# Test Image LOCAL — Galaxy S24 FE (beta)

## Scope della build
- Versione Android ARM64; `com.aiorchestrator` (stesso applicationId delle release).
- Bridge Image LOCAL migrato al plugin Libreria `cantiere_local_image_vision@0.1.0`.
- Unico MethodChannel `com.aiorchestrator/local_image_vision` registrato dal plugin Flutter. La registrazione diretta in MainActivity non viene più eseguita.
- Il servizio chat continua a validare immagine pronta, percorso leggibile e dimensioni massime di 8 MiB; il bridge Kotlin controlla memoria insufficiente (256 MiB), decodifica ridotta a massimo 1024 px e restituisce categorie ML Kit offline.
- **Non è un VLM**: niente OCR, descrizioni complete, colori o conteggio affidabile degli oggetti.

## Installazione e verifica su S24 FE
1. Se possibile, conserva una copia dei dati importanti prima del test. Non disinstallare l'app attuale per tentare l'aggiornamento.
2. Scarica l'APK della beta ufficiale generata da `Build & Release APK` dopo il merge. Usa **app-release.apk** e non AAB.
3. Installa come aggiornamento, **solo se Android accetta la firma compatibile**. Se compare "App non installata" o "conflitto", interrompi: non cancellare l'app, non cancellare i dati.
4. Avvia AI-Orchestrator, seleziona il provider `Local` e un modello che entra nella RAM (per esempio Qwen2.5 3B già verificato).
5. Apri la chat, allega una fotografia propria, chiara e non sensibile (per esempio una mela), al massimo 8 MB, poi invia: "Cosa vedi in questa foto?".
6. Atteso: categorie probabili locali con percentuali, oppure un messaggio chiaro di insufficiente confidenza. NON aspettarti descrizioni, colori o lettura del testo.
7. Ripeti con una foto diversa; riprova con modello locale già caricato per controllare il comportamento sotto pressione RAM.
8. Invia la schermata della risposta e, in caso di errore, Diagnostics (senza foto private o dati personali).

## Stop e conservazione dati
- Se il sistema rifiuta la firma o la versione: **non disinstallare** l'app per forzare l'installazione.
- Se appare `LOCAL_VISION_MEMORY` o `LOCAL_VISION_OOM`, chiudi altre applicazioni; evita prove ripetute con modelli già al limite.
- `Image LOCAL` non inoltra la foto al Cloud; questa proprietà riguarda il classificatore locale. Usa `Cloud` solo con consenso esplicito.
- Non dichiarare superato il test fisico dal solo esito CI; servono foto e risposta reali su S24 FE.

## Riscontro CI
- Libreria plugin originale: PR #180, Android ARM64 isolato compilato e 5 test Flutter passati.
- Per questa versione Cantiere: prendere come fonte solo il run GitHub e la release **successivi** alla modifica e al merge del codice.
