# AIVEXUS 1.0.16-dev — aggiornamento Windows 8.1 con recupero

## Obiettivo

Distribuire una nuova versione **tramite l'aggiornamento interno** del
vecchio AIVEXUS Windows 8.1, senza riutilizzare la `104238`, senza
disabilitare protezioni Windows 11 e senza creare una seconda app.

Il canale sperimentale scelto è **Dev**, con versione base
`1.0.16` (maggiore della `1.0.15` di tutte le beta disponibili).
Questa scelta è necessaria perché il comparatore ordinario preferisce
beta a dev **a parità di versione base**. La versione `1.0.16-dev`
deve quindi essere strettamente maggiore, anche nel vecchio updater.

## Distribuzione con gate del proprietario

Questa procedura diventa utilizzabile **solo dopo il merge della PR**
e i controlli verde su `main`. Non avviare da un branch sperimentale.

1. Il proprietario apre
   [GitHub Actions — Build & Release APK](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/actions/workflows/build.yml).
2. Seleziona `Run workflow`, ramo `main`, `release_channel: dev`,
   `hybrid_consent_beta: false`. Questa è un'autorizzazione esplicita
   alla pubblicazione di una release sperimentale **anche Android Dev**;
   non eseguire automaticamente senza approvazione.
3. Quando il workflow riesce, la pipeline
   `Publish Windows Release Asset` verifica commit/tag e aggiunge
   `AI-Orchestrator-Setup-x64.exe` + SHA-256 **alla stessa release Dev**.
4. Per un tag `v1.0.16-dev+<build>`, il publisher inserisce
   `AivexusWin81UnsignedQABuild`, che **richiede il recupero**
   e limita Inno Setup a Windows 8.1
   (`MinVersion=6.3`, `OnlyBelowVersion=10.0`).
   Nessuna firma Authenticode è necessaria per il collaudo specifico
   Windows 8.1. Windows 10 e 11 sono **esclusi dall'installazione**.
5. Verificare SHA e asset della nuova release e testare il profilo dati
   del Lenovo **prima** di installare. L'app `1.0.12.2` deve mostrare
   l'opzione `Dev` nel suo pannello Aggiornamenti; non è stato ancora
   collaudato sul vecchio eseguibile se tutti i canali siano presenti.
6. Se il vecchio aggiornamento interno offre Dev e riconosce la nuova
   versione, eseguire la normale procedura in-app, senza
   disinstallare l'app precedente.

## Dopo l'aggiornamento su Windows 8.1

Verificare avvio, inferenza LOCAL, modelli, memoria e impostazioni.
Se la nuova applicazione non parte, usare l'utilità **Recupera versione
precedente** dal menu Start; se funziona, chiuderla e usare
**Conferma aggiornamento funzionante**. Conservare il backup storico.

Attenzione: Flutter 3.47 non supporta ufficialmente Windows 8.1;
nessun test CI Windows 2022 prova l'esecuzione reale sul Lenovo.
Prima del primo upgrade controllare cartella di installazione,
profilo utente effettivo, percorsi Local/Roaming e spazio libero
(incluso il caso UAC con credenziali di un altro amministratore).

## Contenimento dell'eccezione

- Nessuna disattivazione di Smart App Control, Defender, WDAC o McAfee.
- Le release Windows **Beta/Stable** non attivano il flag legacy. Su
  ASUS, se è selezionato Beta, l'utente **non riceve il Dev** tramite
  il rilevamento per canale; su Windows 11 con Dev selezionato il setup
  rifiuta l'installazione.
- Le versioni Dev Android possono essere visibili **solo agli utenti che
  hanno selezionato Dev**. La pubblicazione di questa release resta
  un'azione manuale del proprietario.
- L'implementazione rimane unica su `main`; una funzione validata
  passa alla release ordinaria soltanto dopo prove reali.

Riferimenti: issue #1140; PR #1156 (rollback); PR #1157 (installer
Win8.1-only); policy `docs/EXPERIMENTAL_PROMOTION_POLICY.md`.
