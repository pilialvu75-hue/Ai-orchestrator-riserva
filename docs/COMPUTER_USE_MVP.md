# AIVEXUS Computer Use — Windows MVP (11 novembre 2026)

## Obiettivo e confini

Questo checkpoint NON dichiara Computer Use autonomo pronto. E una prima
implementazione reale di input/cattura schermo Windows, montata dietro al
contratto tool e a un laboratorio manuale accessibile da **Impostazioni >
Computer Use — Laboratorio** su Windows.

- Windows: prima piattaforma, azioni OS effettive ma ancora senza test fisici.
- macOS: adattatore sperimentale di sola osservazione collegato a
  CoreGraphics tramite FlutterMethodChannel nativo, senza subprocess.
  Il laboratorio chiede Screen Recording su azione esplicita dell'utente;
  sandbox/firma e compatibilita del Mac richiedono collaudo reale.
- Android: adattatore sperimentale di sola osservazione creato; riusa il
  servizio MediaProjection gia presente nell'app, previo consenso Android.
- Linux: adattatore non ancora sviluppato.
- Il laboratorio e ora raggiungibile dal codice Impostazioni su macOS e Android,
  ma la funzione non e rilasciata; consente solo osservazione autorizzata.
  Sull'Android il consenso MediaProjection viene richiesto dal sistema e la
  proiezione avviata dal laboratorio si arresta con STOP o scadenza.
- Web: sandbox browser; non e possibile controllare il desktop dell'host.
- Su Google Play non e consentito impiegare AccessibilityService per un agente
  generalista che pianifica/esegue azioni autonome; prima di aggiungere input
  Android serve un'architettura e distribuzione conformi alle policy. Nessun
  servizio di accessibilita aggiunto alla build corrente.
- Nessuna dipendenza dal Cloud o da llama.cpp per le azioni manuali.
- Nessuna registrazione del tool nel loop del modello; il modello NON puo
  attivare la sessione di propria iniziativa.
- Screenshot in memoria; file temporaneo di cattura eliminato dopo la lettura.
- Testo digitato e immagini non vengono inviati a Diagnostics ne al Cloud.

## Checkpoint di implementazione

| Componente | Stato |
| --- | --- |
| Contratto ComputerUseAdapter | Implementato |
| Mac: acquisizione PNG via CoreGraphics/FlutterMethodChannel con Screen Recording TCC | Implementato sul ramo, 5 test bridge simulato aggiunti; da collaudare su hardware reale; input disabilitato |
| Android: osservazione tramite ScreenVision MediaProjection | Adattatore e schermata read-only preparati; test con bridge simulato aggiunti, hardware non collaudato; input disabilitato |
| Protezione contro abilitazione interazione su adattatori read-only | Implementata, test aggiunti |
| Sessione temporanea e revocabile (10 min) | Implementato |
| Observe / screenshot PNG schermo primario | Implementato; da collaudare su Windows reale |
| Click coordinate e selezione finestra attiva | Implementato; da collaudare |
| Paint e 2048 offline QA, punteggi osservati | Implementati nel ramo Windows; script testato sintatticamente e prova headless in CI; test fisico ancora da eseguire |
| Passaggio esplicito tra finestre (selezione da screenshot senza clic) | Implementato nel ramo QA Windows; CI e hardware da verificare |
| Testo Unicode, tasti di navigazione | Implementato; da collaudare |
| UI di laboratorio con consenso e STOP | Windows + read-only macOS e Android; Android ferma il proprio MediaProjection allo STOP/scadenza; QA fisica da eseguire |
| Test autorizzazioni, STOP, concorrenza, allowlist e verifica | Aggiunti; CI del nuovo commit da verificare |
| Lettura locale UI Automation (Windows) | Sorgente nativa e filtro privacy implementati nel ramo QA; test simulati/parser CI in corso; da collaudare su Windows reale |
| Interpretazione visiva LLM | NON implementata |
| Car Jam Solver (Ladaneta) S24 FE / WEmulDroid | Protocollo di benchmark registrato; compatibilita emulatore e input autonomo Android NON verificati |
| Motore autonomo astratto `ComputerUseAgentRunner` | Implementato e testato con finti planner/verificatore; collegato sperimentalmente al modello reale SOLO per 2048 QA, ancora da collaudare |
| Ciclo dinamico observe → decide → agisci → ri-osserva → verifica | Implementato; collegamento reale al modello selezionato SOLO per 2048 QA, da validare sul dispositivo |
| Revoca durante inferenza / nuova sessione | Revisioni di autorizzazione implementate; test in CI |
| Pianificatore LOCAL JSON con descrizione schermata | Contratto e parser tipizzato implementati; 8 test simulati, nessuna inferenza reale collegata |
| Ciclo autonomo con LLM configurato | Prova 2048 con il LOCAL selezionato collegata al pulsante QA Windows; non provata su hardware, non abilitata per altri task |
| UI Automation: verifica solo marcatore sintetico QA | Implementata sperimentalmente; non validata su Windows fisico |
| Sequenza controllata Blocco note → scrittura → verifica → screenshot | Implementata; CI da verificare e QA fisico necessario |
| Integrazione Diagnostics anonimizzata | NON implementata |
| Aggiornamento beta | NON rilasciato |

## Test manuale su ASUS Windows (senza disattivare Defender)

1. Installare solo tramite il canale aggiornamenti dell'app una futura
   beta che includa il commit verificato.
2. Aprire Impostazioni > Computer Use — Laboratorio.
3. Scegliere Osserva schermo e autorizzare: comparira l'immagine dello
   schermo primario; il pulsante Aggiorna acquisira un altro frame.
4. Fermare, avviare Abilita interazione, poi scegliere
   "Seleziona finestra attiva (4 secondi)". Subito dopo usare Alt+Tab per
   portare in primo piano il Blocco note senza informazioni riservate.
5. Tornare al laboratorio e premere Aggiorna: il sistema deve riportare la
   schermata della finestra selezionata; toccare una posizione nella preview
   e verificare che il clic arrivi alla finestra corretta.
6. Tornare al laboratorio, scrivere "Prova Computer Use Aivexus", premere
   Inserisci testo. Verificare che venga scritto nella finestra selezionata,
   non nei controlli Aivexus.
7. Provare Tab, Invio, frecce; premere STOP anche durante un'operazione.
8. Fermare e riavviare Abilita interazione. Premere
   **Test automatico: Blocco note** e non cambiare app durante l'esecuzione.
   Il test deve avviare Blocco note, selezionarlo, scrivere un marcatore QA,
   ritrovarlo tramite UI Automation e acquisire una schermata; conta come PASS
   **solo** se il testo esatto e verificato. In caso di impossibilita di
   leggere il controllo, segnare NON SUPERATO, non assumere un successo.
9. Controllare la scadenza a 10 minuti e ripetere dopo riavvio dell'app: le
   autorizzazioni non devono essere persistenti.

Non provare su finestre che contengono password, dati riservati o modifiche
irreversibili. Windows UAC/elevazione, sessioni bloccate e Secure Desktop
non sono in scope. Se Defender/Smart App Control blocca un binario non firmato,
registrare il blocco come limite dei test fisici; proseguire con i controlli
CI senza disattivare Windows Security. La firma e rinviata alla release finale.

## Prossimo ciclo: agenti autonomi

1. Estendere la sonda UI Automation limitata ai marcatori QA a un backend
   di accessibilita strutturato e rilevamento contesto senza OCR obbligatorio.
2. Collegare un planner LLM LOCAL e un verificatore indipendente al runner,
   usando l'accessibilita strutturata o una visione locale. Cloud solo dopo
   consenso esplicito separato per le immagini; nessun upload automatico.
3. Consolidare il runner gia creato: limiti di step, durata, ripetizioni,
   anti-loop e STOP; estendere al recupero dagli errori reali, audit
   metadata-only e verifica dello stato finale.
4. Integrazione con l'orchestratore Aivexus e il Cantiere senza introdurre
   Main/Reviewer obbligatori.
5. Convalida fisica Windows, macOS e Galaxy S24 FE dopo riparazione Aivexus.
   Prima l'osservazione autorizzata; poi, in un secondo passo, input macOS
   tramite permessi Accessibilita e valutazione tecnica/policy Android.
   Nessuna richiesta di installazione beta finche il runtime non e riparato.

## Benchmark reale Car Jam Solver — Android e WEmulDroid (12 novembre 2026)

**Scelta del proprietario**: [Car Jam Solver: Traffic Jam di Ladaneta Games](https://play.google.com/store/apps/details?id=car.parking.jam.solver.puzzle.games), package Android esatto `car.parking.jam.solver.puzzle.games`.
Il gioco e di terzi, contiene pubblicita e acquisti in-app; **non**
distribuire APK modificati, automazioni di acquisto o soluzioni dei livelli.

L'obiettivo e un confronto pratico fra:
- **Galaxy S24 FE** con Aivexus Android e modello effettivamente
  selezionato, avviando il gioco da Google Play soltanto su approvazione
  dell'utente. L'attuale adattatore Android Computer Use e **read-only**
  con MediaProjection; non puo ancora toccare il gioco autonomamente.
  Per input autonomo servira una modalita di test legittima e conforme
  alle policy Android/Google Play, senza eludere il sistema.
- **ASUS Windows + WEmulDroid** sul profilo Google Play Android 15
  x86_64, dopo verifica di installazione e avvio reali del titolo.
  La compatibilita del gioco con emulatore/ABI non e garantita.
  WEmulDroid e un prodotto e repository indipendente: un eventuale
  driver di comandi sara una integrazione opzionale e consensuale,
  non una dipendenza nascosta del runtime Aivexus Windows.
- **2048 su Windows** resta test iniziale tecnico, con seed ripetibile
  solo per confrontare la stessa posizione iniziale. Le direzioni
  devono venire dal modello LOCAL a ogni turno: non e presente
  una lista predefinita di mosse da vincere. Il codice agent
  e collegato al laboratorio, ma la prova reale su ASUS manca ancora.

### Validazione delle decisioni (non uno script fisso)

Per Car Jam ogni turno deve passare da una **nuova** osservazione:
screenshot consensuale -> riconoscimento auto/passeggeri/direzioni
-> decisione del modello corrente -> input controllato -> nuova
schermata -> verifica indipendente dell'esito. Nessun livello
e' considerato vinto soltanto perche la IA lo dichiara.

Gli annunci sono parte del test: distinguere `GAME`, `AD`,
`MENU`, `LEVEL_COMPLETE`, `PAYMENT`, `PERMISSION`, `UNKNOWN`.
Se un livello chiede annunci o denaro per essere sbloccato,
marcare `AD_GATED` o `PAYWALL`; non attribuire quel blocco
alla mancanza di intelligenza. Non aprire annunci, acquisti,
permessi, link esterni o Play Store da decisione autonoma.

Metriche: livello verificato, mosse riuscite/fallite,
score ove disponibile, tempo per scelta/livello,
auto-correzioni, annunci e loro durata, blocchi da monetizzazione,
modello e modalita LOCAL/CLOUD/HYBRID, eventuali crash.
Screenshot/account rimangono locali salvo consenso separato;
STOP revoca la sessione. I dati visuali di gioco e annunci
sono dati non attendibili, mai istruzioni operative.

**Stato:** titolo verificato su Google Play; percorso di test e
requisiti registrati, ma gioco non ancora installato né giocato
automaticamente nei due ambienti. Il laboratorio Android non e ancora
abilitato all'input. Nessun PASS fisico deve essere inferito dalla CI.

WEmulDroid: [protocollo Car Jam](https://github.com/pilialvu75-hue/WEmulDroid/blob/main/docs/CAR_JAM_SOLVER_QA.md)
e [issue #10](https://github.com/pilialvu75-hue/WEmulDroid/issues/10).

## Nuove prove pratiche: Paint e 2048 offline (12 novembre 2026)

Per misurare l'intelligenza di Computer Use (non solo l'uso del mouse),
la allowlist Windows QA comprende anche:

- **Paint** (`paint`): applicazione creativa utile per testare
  clic precisi, trascinamenti futuri e la navigazione tra finestre.
  I trascinamenti NON sono ancora implementati, quindi per ora i
  test Paint si limitano ai clic e ai controlli consentiti.
- **Gioco 2048 offline** (`qa2048`): minigioco autonomo WinForms
  creato con script PowerShell costante, senza rete, librerie esterne,
  download, documenti personali o installer. E' avviabile
  **soltanto** in build con
  `AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true`.

Il gioco ha una griglia 4x4, frecce direzionali, generatore con seed
costante `20261112` per ripetere una partita iniziale e obiettivo
misurabile: raggiungere una casella di valore **64**. Punteggio,
numero di mosse e miglior casella sono esposti tramite i nomi accessibili
dei controlli Windows, senza contenuti utente.

`ComputerUse2048Benchmark.parse()` legge il riepilogo UIA osservato
e accetta solo una griglia completa di 16 caselle, valori potenza di 2
e score/status plausibili. Il pulsante `Leggi controlli finestra (LOCAL)`
presenta punteggio, miglior casella, mosse e differenza dal rilevamento
precedente. Non usa output del modello come prova del risultato.

**Distinzione fondamentale**: una build funzionante del minigioco e un
test di tasti o clic non dimostrano intelligenza. Per dichiarare
`AIVEXUS HA GIOCATO 2048`, servira' collegare un modello LOCAL reale
al lettore semantico/UIA, fargli scegliere le mosse **dopo** ogni
osservazione, registrare solo metriche non sensibili e verificare
un miglioramento di punteggio con il benchmark indipendente.
L'agente LOCAL reale e' ora collegato **solo** all'esperimento 2048
nel laboratorio QA, ma manca una prova fisica end-to-end; non e'
ancora disponibile nella versione stabile.
Nessun test fisico e' stato ancora effettuato sull'ASUS; i test di CI
non fanno girare un gioco con finestra interattiva.

### Partita con il modello LOCAL reale (solo laboratorio Windows)

Nel laboratorio QA, il pulsante **Fai giocare Aivexus LOCAL a 2048**
esegue il seguente esperimento, senza Cloud e con consenso esplicito:

1. Richiede una sessione interattiva e una finestra 2048 gia selezionata.
2. Recupera il modello LOCAL attualmente scelto tramite
   `LocalAiRepository.getSelectedModel()` e verifica che il GGUF sia
   disponibile; usa `LocalRuntimeProvider` esistente, senza modificare
   la selezione di modello o il runtime di chat.
3. Il planner `ComputerUse2048LocalPlanner` riceve **solo** i 16 valori
   della griglia, punteggio e numero di mosse tramite UI Automation locale.
   Il modello deve produrre esattamente un JSON `{"move":"left"}`
   o altra direzione legittima.
4. Il runner esegue solo `press_key` su una delle quattro frecce,
   acquisisce lo stato nuovo e usa un verificatore **indipendente**
   per accettare come obiettivo raggiunto solo una casella da 64.
5. L'esperimento si interrompe a 24 mosse, 8 minuti, scadenza sessione
   o STOP; STOP annulla la generazione LOCAL in corso.

Non si tratta di una sequenza di mosse fisse, di un giocatore euristico
o di una simulazione dell'intelligenza: le decisioni sono formulate dal
modello selezionato, **se** l'inferenza e il lettore funzionano
nell'ambiente reale. L'esperimento non e' ancora stato collaudato
su ASUS, e la CI usa modelli finti per verificare il protocollo.
Se fallisce, il test deve riportare NON VERIFICATO, non un successo.

## Lettura controlli Windows tramite UI Automation (12 novembre 2026)

Aggiunta una prima sorgente di osservazione strutturata in Computer Use,
specifica per Windows. Non sostituisce la futura visione completa dello
schermo: legge **solo la finestra gia' selezionata**, attraverso le API
locali UI Automation, senza cambiare il focus o inviare input.

- `WindowsComputerUseAdapter.captureSelectedAccessibilityJson()` usa uno
  script PowerShell costante, che enumera al massimo 64 controlli e
  non oltre tre livelli di profondita', con limite sui fratelli.
- Produce tipo controllo, coordinate e nomi brevi, senza chiamare
  `ValuePattern` o `TextPattern`. I contenuti di Edit/Text/Document
  non vengono letti. Le schermate con controllo password e gli alberi
  incompleti producono un segnale sensibile e **nessun riepilogo**.
- `WindowsComputerUseAccessibilityReader` valida il JSON, limita
  dimensione/lunghezza, intercetta indicatori sensibili e richiede una
  sessione attiva: STOP + nuova autorizzazione invalidano risposte vecchie.
- Il pulsante QA `Leggi controlli finestra (LOCAL)` mostra il risultato
  sul dispositivo; non usa rete, servizi Cloud o log con contenuti.
- Aggiunti test Dart per consenso, dati benigni, password, JSON
  malformato, limite dimensionale e STOP/regrant. Un test Windows analizza
  staticamente la sintassi PowerShell, senza leggere il desktop CI.

Letture incompiute possono risultare inutilizzabili; comportamento corretto
in QA: fermarsi e NON generare azioni non verificate. L'accessibilita'
non offre una rappresentazione visuale completa di tutte le applicazioni;
serviranno integrazione vision/semantica e collaudo reale ASUS.
Questa sorgente non e' ancora collegata automaticamente al modello LOCAL.

## Collegamento LOCAL isolato — ancora non attivato (12 novembre 2026)

L'app Aivexus funziona nuovamente. Per evitare di toccarne l'inferenza
principale, e' stata preparata una classe di collegamento **solo nel ramo
Computer Use**: `AivexusComputerUseLocalDecisionModel`.

- Riceve un `LocalRuntimeProvider` esistente come dipendenza tipizzata;
  nessun Cloud router o fallback puo' essere fornito tramite il contratto.
- Forma `InferenceRequest` con `localOnly`, `isOffline=true`,
  `allowWebSearchTool=false`, `allowCloudProviderFailover=false`,
  `maxTokens=256` e temperatura 0.1.
- Accetta soltanto un output finale positivo, esamina un massimo di 4096
  caratteri, e rifiuta stream incompleti, errori e risposte vuote.
- STOP nell'agent runner notifica il planner e il modello; il token di
  cancellazione interrompe una generazione LOCAL ancora in esecuzione.
- Test isolati con runtime falso coprono routing offline, risposta finale,
  errore, stream incompleto, STOP e configurazione mancante.

**Non e' ancora attivo**: manca un componente affidabile per descrivere
la schermata (accessibilita' strutturata / visione locale), collegare il
modello reale selezionato alla sessione UI e verificare l'esito su hardware.
Il test Win32/passaggio tra finestre non equivale a Computer Use autonomo.

## Estensione del desktop multi-finestra (12 novembre 2026)

Il blocco dei clic fuori dalla finestra selezionata resta specifico
dell'azione `click`: evita un reindirizzamento involontario, **non**
limita in modo permanente Computer Use a una sola applicazione.

Aggiunto il passaggio esplicito `select_window_at(x,y)`:
- Richiede una sessione interattiva attiva e coordinate valide della
  schermata precedentemente osservata.
- Su Windows la selezione usa l'identita' della finestra realmente
  in primo piano **al momento della cattura**, registrata prima di avviare
  il processo PowerShell. Quando si torna all'anteprima Aivexus non cerca
  la finestra presente *ora* sotto la coordinata (sarebbe Aivexus).
  Il punto scelto deve appartenere all'HWND catturato, ancora valido,
  visibile e di processo diverso da Aivexus. Nessun click o focus durante
  la selezione. Le finestre in secondo piano nella stessa immagine NON
  sono ancora selezionabili: vanno portate in primo piano e riacquisite.
- Il bersaglio selezionato puo' essere diverso da quello precedente.
  Dopo la selezione, il successivo clic rimane verificato rispetto alla
  **nuova** finestra, non a quella originaria.
- Il protocollo del planner LOCAL e il runner accettano il nuovo comando.
  Le coordinate diverse sono distinte nel rilevamento anti-loop.
- Nel laboratorio Windows e' disponibile il pulsante
  "Scegli altra finestra dalla schermata": la prima pressione
  sull'anteprima sceglie senza cliccare; il clic richiede una seconda
  pressione. Per cambiare ancora applicazione si ripete la selezione.
- La cattura schermo Windows e' ora passiva e non riporta forzatamente
  in primo piano la vecchia finestra: l'agente puo' vedere il desktop
  mutato dopo un passaggio tra applicazioni.
- Nel laboratorio il pulsante "Acquisisci tra 4 secondi" permette di passare
  a un'altra app prima del frame; poi si torna al laboratorio, si seleziona
  il nuovo bersaglio con un tocco **senza inviare clic**, quindi si puo'
  agire sul bersaglio scelto. STOP durante l'attesa invalida la cattura.

La scelta di una finestra non equivale a un'autorizzazione per operazioni
sensibili: STOP, durata, controlli sulla destinazione e autorizzazioni
per incarico restano indipendenti. Il passaggio a una vera IA autonoma
collegata all'inferenza LOCAL **non e' ancora implementato**.
La verifica della UI su hardware Windows rimane da eseguire.

## Decisione sul ciclo di sviluppo (12 novembre 2026)

L'utente ha autorizzato a proseguire senza firma digitale durante i test.
La firma di Windows va affrontata quando Aivexus Computer Use sara' pronto
per la distribuzione finale: non rappresenta piu' un blocco per i test QA.

E' stato aggiunto al workflow Computer Use un terzo job,
\`windows-lab-preview\`, che su runner Windows 2022:
- attende il PASS di test unitari e Win32 interop;
- verifica il flag esplicito di laboratorio QA;
- compila la app Windows in modalita' release **senza firmarla**, con
  \`AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true\`;
- verifica il bundle llama.cpp/local inference;
- conserva un archivio CI temporaneo con SHA-256 e manifesto del commit,
  marcato chiaramente come non pubblicato e non firmato.

Il job non crea una GitHub Release, non modifica main, non attiva l'updater
e non e' una istruzione a installare manualmente l'archivio. L'uso su
hardware vero richiede un canale QA appropriato, mantenendo le protezioni
di Windows attive. Un runner Windows non sostituisce la prova fisica ASUS.

## Gate di distribuzione: laboratorio default OFF

La PR #1114 mantiene Computer Use in stato sperimentale. Il laboratorio
non compare in Impostazioni e non concede una sessione in una build
ordinaria: e' abilitabile esclusivamente durante la compilazione con
\`--dart-define=AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true\`.

Il flag non e' una preferenza modificabile dall'LLM e non attiva
automaticamente OS Accessibility, MediaProjection o permessi macOS.
La CI dedicata controlla sia il comportamento OFF predefinito, sia
l'abilitazione esplicita in una compilazione di test.

Nessuna pipeline di pubblicazione attualmente attiva riceve quel flag:
**il laboratorio non e' stato distribuito al dispositivo dell'utente**.
Prima di coinvolgere l'updater sono richiesti gate CI, verifiche di
sicurezza e una procedura QA esplicitamente autorizzata. La firma non
blocca i test interni, ma rimane un obiettivo della distribuzione finale.

## Preparazione del primo collaudo fisico Windows

Dopo la conferma di ripristino di Aivexus, il laboratorio rimane comunque
isolato nella PR draft #1114; non e ancora una funzionalita installata.

Il primo test automatico e ancora strettamente limitato:
- Aprire solo notepad.exe con argomenti vuoti.
- Conservare il PID restituito dal processo avviato.
- Attendere e selezionare il primo piano **solo se** il PID della finestra
  corrisponde al processo avviato. Dopo il tempo iniziale, riprovare fino a
  cinque volte, a distanza di 400 ms, esclusivamente per finestra non pronta.
  Altrimenti ritornare il codice LAUNCHED_APP_NOT_FOREGROUND, senza scrivere
  o premere tasti. STOP o una nuova autorizzazione interrompono il vecchio
  test e non permettono di riutilizzarne il permesso.
- Digitare esclusivamente un marcatore sintetico AIVEXUS-CU-QA-...
- Dichiarare PASS solo dopo verifica UI Automation del marcatore esatto.
- La finestra Windows 11 di una app packaged potrebbe appartenere a un
  processo broker differente: in tal caso il test fallisce esplicitamente
  anziche inviare testo a una applicazione sbagliata. L'eventuale supporto
  broker richiede identificazione affidabile del processo, non un bypass.

Quattro test puri di policy controllano il PID atteso, un'altra app in
primo piano, la finestra della stessa Aivexus e la selezione manuale priva
di vincoli del test lanciato. Altri test del flusso verificano avvio lento,
finestra estranea, errore di focus, STOP durante l'attesa e STOP seguito da
nuova autorizzazione. Non sostituiscono la prova sul dispositivo.

**Gate per il collaudo Windows (firma differita su decisione utente)**:
CI Computer Use dedicata PASS; build/test Windows PASS; regressioni principali
valutate; prova QA con l'opt-in di laboratorio. Una firma Authenticode NON e'
obbligatoria per compilare o verificare internamente il prototipo.
Per collaudi sul vero ASUS, serviranno un percorso di aggiornamento/test
controllato e l'autorizzazione del proprietario: NON disattivare Defender,
Smart App Control o altri meccanismi di protezione.
La firma e la reputazione saranno risolte per la distribuzione definitiva.
Non pubblicare da branch PR draft e non fare merge per aggirare il gate.

**Criterio di completamento**: Aivexus deve eseguire da richiesta naturale
almeno tre scenari non distruttivi su Windows (aprire un'app, compilare un
campo di prova, verificare il risultato) senza passi manuali intermedi, con
STOP e consensi effettivi. Il solo PASS di Flutter test non basta.


## Disponibilita dei dispositivi

L'utente ha confermato l'11 novembre 2026 di avere gia disponibili un Mac e
un dispositivo Android. Il requisito hardware non blocca lo sviluppo. L'utente ha confermato il ripristino di Aivexus il 12 novembre 2026.
Non interferire con Work: i collaudi Computer Use inizieranno solo quando
una build QA verificata sara disponibile tramite aggiornamento integrato.

Importante: avere il dispositivo disponibile **non** significa che Computer Use
su quella piattaforma sia gia operativo. L'obiettivo rimane autonomia
multisistema; il test di lettura schermo e un checkpoint, non il traguardo.


## Punti di controllo (12 novembre 2026)

- Corretto un errore Dart di sintassi nel runner autonomo astratto.
- Estesa la schermata Laboratorio a Windows/macOS/Android sul ramo PR #1114,
  con modalita read-only per Mac e Android, consenso esplicito, STOP e timer
  di scadenza a 10 minuti. Non e una release per i tester.
- Aggiunti test fittizi Android che coprono consenso schermo obbligatorio,
  frame PNG, rifiuto di click e STOP durante una cattura in ritardo.
- Mac ora usa un ponte nativo CoreGraphics e non la utility `screencapture`.
  ScreenCaptureKit (moderna API streaming) e un miglioramento futuro. Servono
  ancora test reali per sandbox, consenso TCC, firma e compatibilita.
- Il motore IA autonomo non e collegato a nessun provider finche l'inferenza
  Aivexus non ritorna funzionante. Continuiamo senza toccare la sua riparazione.


## Checkpoint macOS nativo (12 novembre 2026)

- Corretto il test STOP che si aspettava il vecchio codice di errore:
  la revoca in corso ora produce `SESSION_REVOKED`, come previsto.
- Il progetto Mac registra il canale nativo
  `com.aiorchestrator/computer_use_mac` in `MainFlutterWindow.swift`:
  `getStatus`, `requestScreenRecording` (solo su gesto utente) e
  `captureScreenshot`. Nessun input o comando arbitrario esposto.
- `MacComputerUseAdapter` usa il canale con permessi CoreGraphics e PNG in
  memoria; eliminata l'esecuzione del tool di sistema `screencapture`.
- Aggiunti 5 test Flutter simulati del bridge Mac: consenso, frame valido,
  divieto interazione, STOP/riautorizzazione e revoca del consenso.
- Ancora necessario collaudare compilazione nativa Swift, TCC e runtime su Mac.


## Protocollo per futura IA autonoma (12 novembre 2026)

La classe `ComputerUseLocalJsonPlanner` trasforma l'osservazione del desktop
in un'unica azione GUI tipizzata per passo, senza affidarsi a macro fisse.
Riceve due dipendenze ancora **non collegate alla produzione**:

- `ComputerUseLocalScreenReader`: un interprete locale che produce una
  descrizione strutturata e indica se lo schermo e sensibile. Una schermata
  segnalata sensibile interrompe il ciclo prima della chiamata al modello.
- `ComputerUseLocalDecisionModel`: modello LLM vincolato a inferenza LOCAL.
  Non e un adapter Cloud; la concreta implementazione, dopo il ripristino
  della inferenza, deve impedire esplicitamente ogni fallback online.

Il parser accetta solo un JSON esatto: `act` con azioni `open_app`,
`select_window`, `click`, `type_text`, `press_key`; oppure `complete`
o `abort`. Rifiuta comandi shell, extra chiavi, click con coordinate non
intere, app non consentite e tasti non in allowlist. La conferma `complete`
richiede una verifica indipendente del risultato finale nel runner.

I test attuali simulano interpretazione dello schermo e risposte del modello:
**non dimostrano che Aivexus ragioni o veda gia il desktop**. La visione
reale, consenso Cloud (se usato) e collegamento del runtime saranno valutati
solo dopo che Work avra ripristinato Aivexus.
