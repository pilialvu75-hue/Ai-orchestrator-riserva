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
| Passaggio esplicito tra finestre (selezione da screenshot senza clic) | Implementato nel ramo QA Windows; CI e hardware da verificare |
| Testo Unicode, tasti di navigazione | Implementato; da collaudare |
| UI di laboratorio con consenso e STOP | Windows + read-only macOS e Android; Android ferma il proprio MediaProjection allo STOP/scadenza; QA fisica da eseguire |
| Test autorizzazioni, STOP, concorrenza, allowlist e verifica | Aggiunti; CI del nuovo commit da verificare |
| Interpretazione visiva LLM | NON implementata |
| Motore autonomo astratto `ComputerUseAgentRunner` | Implementato e testato con planner e verificatore simulati; NON collegato a IA reale |
| Ciclo dinamico observe → decide → agisci → ri-osserva → verifica | Implementato nel runner isolato; manca il modello reale |
| Revoca durante inferenza / nuova sessione | Revisioni di autorizzazione implementate; test in CI |
| Pianificatore LOCAL JSON con descrizione schermata | Contratto e parser tipizzato implementati; 8 test simulati, nessuna inferenza reale collegata |
| Ciclo autonomo con LLM configurato | NON implementato; esecutore e protocollo LOCAL pronti per futura integrazione, senza modello reale |
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

## Estensione del desktop multi-finestra (12 novembre 2026)

Il blocco dei clic fuori dalla finestra selezionata resta specifico
dell'azione `click`: evita un reindirizzamento involontario, **non**
limita in modo permanente Computer Use a una sola applicazione.

Aggiunto il passaggio esplicito `select_window_at(x,y)`:
- Richiede una sessione interattiva attiva e coordinate valide della
  schermata precedentemente osservata.
- Su Windows individua il bersaglio visibile alle coordinate indicate
  senza muovere il puntatore, attivare la finestra, cliccare o digitare.
  Esclude la finestra Aivexus e quelle non valide/minimizzate.
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
