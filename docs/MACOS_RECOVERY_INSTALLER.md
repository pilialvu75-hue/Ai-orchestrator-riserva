# Ripristino macOS Aivexus — installer personale verificato

## Situazione fisica
Sul Mac del proprietario, dopo l'aggiornamento ad-hoc, `AI Orchestrator.app`
non si avvia: `codesign --verify --deep --strict` è PASS, ma `spctl`
riporta `File created by an AppSandbox, exec/open not allowed`, associato
a `RBSRequestErrorDomain Code=5` / `NSPOSIXErrorDomain Code=153`.

L'installer dedicato recupera la più recente **release macOS ufficiale**
con DMG e checksum presenti su GitHub, senza ricompilazioni superflue e
senza abbonamento Apple Developer. Non è destinato a distribuzione pubblica.

## Causa confermata sul Mac fisico (11/11/2026)
Il registro `/var/log/install.log` mostra che i pacchetti r1/r2
sono stati **rilocalizzati da PackageKit** verso una diversa copia di
`AI Orchestrator.app` con lo stesso bundle ID in una cartella tecnica,
anziché creare `/Applications/AI Orchestrator.app`.
Il `postinstall` cerca correttamente l'app in `/Applications`, ma
questa posizione rimane vuota e lo script termina con:
`Aivexus recovery: expected application was not installed.`

La soluzione **r3** impone nella component plist di `pkgbuild`
`BundleIsRelocatable=false` per i bundle rilevati, tramite
`--component-plist`. La CI registra una seconda copia in una
cartella non standard prima di installare il pacchetto sul Mac di test.
La pubblicazione viene bloccata se l'app non appare in `/Applications`.
Non cancellare altre copie, compresa quella nel Cestino: non sono
necessarie modifiche alle cartelle dati del proprietario.

## Come viene prodotto
1. Il proprietario richiede il recupero tramite il file di controllo
   `release-requests/macos-recovery.txt` nel ramo
   `release-request/macos-recovery` (una riga `tag=...`).
2. `.github/workflows/macos-recovery-pkg.yml`, solo per push del proprietario,
   verifica che il tag sia la **più recente release con DMG macOS verificato**.
3. Preleva dal release GitHub il DMG e il suo sidecar `.sha256`, confronta
   entrambi con i digest GitHub e verifica l'immagine `hdiutil`.
4. Monta l'immagine e verifica bundle ID, versione, runtime e firma dell'app.
5. `native/macos/build_recovery_pkg.sh` produce un `.pkg` con **solo**
   `/Applications/AI Orchestrator.app`, più un `postinstall` dedicato.
6. Il `postinstall`, eseguito soltanto dopo l'autorizzazione
   dell'installazione, ricontrolla bundle ID e firma, quindi elimina
   `com.apple.quarantine` **soltanto dalla copia installata dell'app**.
7. L'installer e il file `.pkg.sha256` vengono pubblicati **nella stessa
   release ufficiale** e i digest finali vengono nuovamente controllati.

## Istruzioni per il proprietario
- Lascia `AI Orchestrator.app` in `/Applications`: **non disinstallare**.
- Scarica `AI-Orchestrator-macOS-Recovery-<build>.pkg` e il suo
  `.pkg.sha256` dalla stessa release ufficiale GitHub.
- Verifica l'hash SHA-256 del pacchetto confrontandolo con l'asset pubblicato.
  Nella cartella Download (entrambi i file nello stesso posto):

  ```bash
  cd ~/Downloads
  shasum -a 256 -c AI-Orchestrator-macOS-Recovery-<build>.pkg.sha256
  ```

  Sostituisci `<build>` con il numero effettivo mostrato nella release.
- Avvia il `.pkg` e autorizza l'installazione nel percorso standard.
  Se macOS segnala che il pacchetto non è firmato/notarizzato, apri la
  specifica app/pacchetto solo dopo la verifica SHA e conferma nelle
  impostazioni di sicurezza quando la relativa opzione è disponibile.
  Se il doppio clic viene impedito, l'opzione amministrativa mirata è
  `sudo installer -pkg "/Users/USERNAME/Downloads/NOME.pkg" -target /`
  sostituendo nome/percorso reali, **solo dopo la verifica SHA-256**.
- Avvia AI Orchestrator normalmente da Applicazioni.
- Controlla versione, cronologia/chat, memoria, modelli e impostazioni;
  il corretto avvio sul Mac resta un test fisico da eseguire.

## Protezione dei dati
Il payload si limita a `/Applications/AI Orchestrator.app`.
**Non** modifica o rimuove `~/Library/Containers`,
`~/Library/Application Support`, SQLite, preferenze, chat o cartelle
dei modelli. Non cambia identificatore `com.aiorchestrator`,
entitlement sandbox o policy Gatekeeper globale.

Il pacchetto di sviluppo è **unsigned/unnotarized**. Questo è un recupero
consensuale e limitato a un dispositivo del proprietario, non prova di
distribuzione pubblica senza prompt di sicurezza. Nessun comando di
disattivazione globale Gatekeeper, nessuna promessa di avvio non verificato.

Tracking: issue #948; policy sviluppo: `docs/DEVELOPMENT_POLICY.md`.
