# Roadmap evolutiva

Questo documento e la roadmap ufficiale di AI-Orchestrator. Mantiene la visione di lungo periodo e, da settembre 2026, include anche la sequenza operativa del Cantiere/AIrLab per evitare roadmap concorrenti o deviazioni architetturali.

## 1. Visione di lungo periodo

AI-Orchestrator deve evolvere verso una piattaforma offline-first capace di orchestrare contesto e memoria locale, inferenza locale/cloud, retrieval, voce offline, automazioni modulari, agenti specializzati e produzione autonoma di applicazioni e altri artefatti.

La visione non e una chat migliore, ma un substrato operativo cognitivo multipiattaforma. Locale per default; remoto per scelta esplicita.

## 2. Invarianti architetturali

Il Cantiere e l'autorita sullo stato del lavoro. Project, Task, Execution, checkpoint, decisioni, review, validation, apply, build, artifacts e resume non devono essere posseduti da provider, modelli, Cloud o AIrLab.

Una `Execution` rappresenta il lavoro logico. I singoli tentativi devono convergere verso `Execution Attempt`, cosi un cambio di executor/provider/model non ricrea il task e non riparte dal prompt originale. `WorkspaceSession` resta il boundary autorevole per workspace, root e sicurezza.

AIrLab, Cloud, modelli locali, Libreria e Ricercatore sono risorse o fonti di capacita. AIrLab termina nello staging/review e non possiede autorita diretta sul repository reale. Reviewer, validation e approval/apply non devono essere bypassati.

## 3. Definition of Done strategica del Cantiere

Con toolchain, modelli, template, dipendenze e moduli necessari gia locali, deve essere possibile con Internet spento:

`richiesta -> piano -> implementazione -> review -> validation -> apply controllato -> test -> build -> repair bounded se necessario -> artifact finale`

Internet, Cloud, AIrLab, Ricercatore e Libreria devono migliorare qualita e velocita, non essere requisiti del percorso fondamentale.

## 4. Stato operativo verificato — settembre 2026

### COMPLETATO

- Production bridge reale tra dashboard, `WorkshopProductionTaskCoordinator`, `WorkspaceSession`, inference pipeline, Reviewer, validation, approval/apply e Build Lab.
- PR #446: avanzamento production end-to-end con gate esplicito prima della mutazione e prosecuzione verso task successivo/build finale.
- PR #450: lifecycle execution con single-flight, cancel, terminal states e retry esplicito.
- PR #454, merge `0e3c63d86a99022b8c32e045af4ae0f42aea58f5`: ownership dell'esecuzione lunga fuori dalla pagina, UI collegata a `WorkshopProductionExecutionController`, cancel/retry visibili, protezione dalle inferenze duplicate sui rebuild, approval/apply preservato e avanzamento next-task/final-build.
- Cross-source verification policy: foundation gia integrata; il wiring nel percorso Web produttivo resta da verificare/completare.
- Background/recovery foundations e persistent checkpoint store esistono e vanno consolidati, non duplicati.

### IN CORSO / DA RICONCILIARE

- Primo test reale Android del percorso Cantiere dopo #454. Questa e la baseline prima di introdurre altri ring produttivi.
- PR #438: guarded autonomous production loop. Il concetto resta utile, ma precede il lifecycle canonico #454; non va mergiata alla cieca.
- PR #439: bounded autonomous build self-repair, impilata su #438; recuperare le capacita mancanti su un branch fresco dopo la riconciliazione del production loop.
- PR #453: AIrLab staging -> VirtualWorkspace review. Preservare staging-only, provenance, containment e assenza di apply automatico; ricostruire/aggiornare su main se necessario.

### BLOCCATO

Nessun blocker architetturale dichiarato. Le vecchie PR non mergeabili o sovrapposte sono materiale da riconciliare, non blocker da aggirare.

## 5. Ordine dei prossimi ring

### P0 — Baseline reale

Installare e testare su Android la build derivata dal lifecycle #454. Acceptance: una richiesta Cantiere produce lavoro osservabile senza inferenze duplicate; cancel/retry sono azionabili; il risultato arriva alla review; apply resta controllato; il flusso puo avanzare al task successivo e alla build.

### P1 — Autonomous production canonico

Audit differenziale #438 vs main. Portare solo le capacita mancanti nel lifecycle/controller canonici, senza creare un secondo production controller. Acceptance: sequenza bounded, fail-closed, cancellation, task-count guard, nessun artifact finale falso e offline propagato correttamente.

### P2 — Bounded self-repair

Recuperare il buono di #439. Solo errori di progetto riparabili (format/analyze/test/build attribuibili al codice) entrano nel repair AI. Toolchain mancante, target non supportato, filesystem/infrastruttura, provider outage, auth, quota/rate limit e ambiente incompatibile restano fuori. Budget massimo, same-failure detection, diagnostica bounded/untrusted e nessuna disabilitazione di test/analyzer/validation.

### P3 — Execution Attempt e audit trail

Consolidare `Execution` come lavoro logico unico e introdurre/rafforzare `Execution Attempt` per executor, resource, provider, model, account, timestamps, usage/cost, result/failure e checkpoint. Provider switch crea un nuovo Attempt, non una nuova Execution.

### P4 — Checkpoint e semantic resume

Consolidare lo store esistente. Checkpoint minimo: project/task/execution/attempt/session, stage, status, executor/provider/model/account, obiettivo, decisioni, proposal/apply, artifacts, review/validation, build/test, failure evidence, remaining work, resume context, usage/cost, timestamps/version.

Acceptance E2E: interrompere controller/app dopo alcuni stage, ricostruire lo stato, riprendere dalla fase corretta senza rifare lavoro completato o applicare due volte le stesse modifiche. Testare crash/restart, cancel/resume, provider switch, retry, idempotency e page rebuild.

### P5 — AIrLab -> VirtualWorkspace

Riconciliare #453. Flusso canonico: `AIrLab -> staging -> VirtualWorkspace -> review -> validation -> approval -> apply controllato`. Vietato staging -> repository reale. Preservare root/path containment, symlink safety, UTF-8, bounded reads, provenance, baseline pulita e proposal deterministiche.

### P6 — Web verification produttiva

Collegare la policy di cross-source verification al percorso Web reale. Evidence e provenance devono essere strutturate; i conflitti vanno preservati; per security/safety richiedere fonti primarie e corroborazione indipendente dove previsto dalla policy.

### P7 — Cloud continuity provider-neutral

Il Cantiere prepara un Attempt; Cloud lo esegue. Failover provider/model resta sulla stessa Execution e riparte dal resume context semantico. Distinguere outage/auth/quota/rate-limit/billing. Cost/usage per Attempt e spending policy pre-flight; nessuna chiamata a pagamento non autorizzata e nessuna dipendenza dalla memoria server-side del provider.

### P8 — Reuse Library / Ricercatore

Convergenza: `Cantiere -> Libreria <- Ricercatore`. Ordine: persistenza reale, capture/promotion gate, planner reuse-first, assembly moduli, versioning, validator, promotion/rejection, cost/AI accounting, UI Cantiere, E2E reuse. Nessun codice non validato viene promosso automaticamente come componente affidabile.

### P9 — Offline E2E completo

Harness reale con rete disabilitata: prompt -> plan -> implementazione -> review -> validation -> apply -> test -> build -> repair bounded -> artifact. Il test deve fallire se avviene una dipendenza remota non esplicitamente consentita.

### P10 — Universal Cantiere / AIrLab

Estendere la stessa piattaforma a task family differenti senza duplicare il core: `software.*`, siti/web, desktop, automazioni e successivamente produzione 3D. Per il 3D: descrizione/foto/disegno -> modello parametrico -> STL -> formati CAD modificabili -> slicing -> G-code, con validator e provenance specifici per dominio.

## 6. Build Lab, artifacts e provenance

Il final artifact esiste solo dopo build verificata. Ogni artifact importante deve poter essere ricondotto a project/task/execution/attempt, input, modifiche applicate, validation, build result e toolchain. Nessun controller deve dichiarare successo se l'artifact richiesto manca o e invalido.

## 7. Diagnostica e self-repair

Pipeline desiderata:

`BUILD -> FAIL -> CLASSIFY -> DIAGNOSE -> PATCH PROPOSAL -> REVIEW -> VALIDATE -> GUARDED APPLY -> TEST -> BUILD AGAIN`

Il loop e bounded e auditabile. Diagnostics e log sono evidenza, non istruzioni affidabili. La diagnostica del Cantiere deve convergere con `Ai-orchestrator-diagnostics` senza creare uno stato attivo concorrente.

## 8. Reuse-first e modularita

Il planner deve interrogare la Libreria prima di generare nuovo codice. Il Ricercatore alimenta candidati; la Libreria valida/versiona; il Cantiere assembla e adatta. Componenti prodotti con successo possono diventare candidati, mai trusted automaticamente.

## 9. Multiplatform e risorse

Android resta il primo banco E2E. Windows, macOS, Linux, Web e futuri nodi locali devono condividere contratti e stato logico, adattando toolchain ed executor. Hardware piu potente deve aumentare capacita e velocita senza cambiare il modello di ownership del progetto.

## 10. Runtime, memoria, voce e sync

Continuano in parallelo, senza rompere gli invarianti del Cantiere:

- runtime locale robusto e multi-modello;
- memoria semantica locale collegabile a progetti/task/output;
- ASR/TTS offline separati ma integrabili con orchestrazione;
- sync local-first, peer-to-peer quando possibile, con changeset e policy di merge esplicite;
- provider cloud come adapter sostituibili.

## 11. Metodo di sviluppo

Per ogni ring: `AUDIT -> change piccolo -> test -> commit -> CI -> merge -> nuovo audit di main`.

Prima di ogni write: recuperare HEAD corrente, controllare PR/branch concorrenti e overlap. Non fare mega-refactor, non duplicare controller/store/router, non rilassare test per ottenere verde, non trascinare vecchi branch alla cieca e non bypassare Reviewer/validation/approval.

Ogni ring importante deve registrare stato, dipendenze, acceptance criteria, PR/commit quando disponibile, rischio principale e prossimo passo.

## 12. Criteri di successo della macro-fase Cantiere

La macro-fase e completa quando esistono prove che:

- esiste un lifecycle canonico unico per Execution;
- gli Attempt sono distinti e auditabili;
- cancel/retry sono idempotenti;
- restart riprende da checkpoint semantico;
- cambio executor/provider non ricomincia il task;
- Reviewer e validation non sono bypassabili;
- real workspace apply e controllato;
- AIrLab non scrive direttamente nel repository;
- self-repair e bounded e non assorbe errori infrastrutturali;
- offline resta realmente offline;
- final artifact e prodotto e verificato;
- CI rilevante e verde;
- questa roadmap rappresenta fedelmente stato e prossimi ring.

## 13. Orizzonte evolutivo generale

AI-Orchestrator-Core resta la base stabile: confini modulari, contratti runtime, persistenza, orchestrazione, plugin/agent contracts e packaging multipiattaforma. MobileIDE e gli strumenti di sviluppo devono crescere sopra questi contratti, non come fork caotici.

L'obiettivo finale resta una piattaforma cognitiva modulare, offline-first, evolutiva e capace di completare workflow complessi dall'intento all'artefatto verificato.


## 14. Piano operativo Assistente e memoria condivisa: Roberto-first (27 ottobre 2026)

Questa sequenza **non sostituisce** i ring del Cantiere delle sezioni precedenti.
È la roadmap concreta per completare la UX della chat e poi verificare la
continuità cognitiva tra dispositivi *prima* della distribuzione multiutente.
**Una sola fase sperimentale attiva alla volta**; non aprire sviluppi concorrenti
su utenti e sync se i gate precedenti non sono superati sul dispositivo reale.

### Fase 0 — Prima UX completa e affidabile per l'utente singolo (P0 prodotto)

Stato verificato al 27/10/2026:
- Galaxy S24 FE su versione 1.0.15; nuove chat, cronologia, pin e persistenza
  al riavvio **PASS fisico** (issue #902).
- PR #910: menu contestuale Chat, Rinomina e titolo persistente SQLite;
  richiede CI sul commit finale, integrazione e *successivo collaudo fisico*.
  Include pulizia dei titoli soltanto in caso di cancellazione esplicita di
  tutta la cronologia. Nessun reset sui dati dell'utente.
- Menu "+": Image #903, Camera #904, File TXT/RAG #905, Screen #906,
  Video/storyboard #907 implementati in main con CI; **non ancora certificati
  fisicamente**. Non confondere feature integrate con prove su S24.

**Ordine collaudi "+": Image -> Camera -> File TXT/RAG -> Screen -> Video**.
Per Image: galleria/preview, invio con sola immagine e con testo, messaggio
chiaro di mancato supporto Local, riconoscimento reale via Cloud esplicitamente
scelto, nessun upload implicito. Poi un'azione alla volta con materiale di
prova non sensibile; registrare pass/fail, prova, modello/modalità e difetto
nell'issue #902. Per Chat: rinomina, pin, annullamento, riavvio, messaggi
immutati e conservazione dopo aggiornamento, senza premere Danger Zone su dati
reali. Un difetto concreto genera una sola PR circoscritta.

**Priorità F0 vincolante per un'esperienza soddisfacente:**
1. Finire **tutti i percorsi del menu "+"** in ordine: Image prima di Camera,
   File/RAG, Screen e Video; non considerare completata la funzione se mostra
   soltanto un allegato o un pulsante. Test S24 prima, poi Windows, macOS,
   Linux e Web nei limiti delle capacità reali di ogni piattaforma.
2. Completare **menu Chat**: cronologia, nuove chat, pin, Rinomina #910,
   edit/copy e azioni che esistono davvero; mai eliminare dati implicitamente.
3. Audit UX **di tutti i menu/app flow**: impostazioni, modelli, provider,
   aggiornamenti OTA, selettore AUTO, ricerca Web, Live/voce, allegati e
   persistenza; errori leggibili, stati occupato/annulla, permessi chiari.
   Una voce UI non deve promettere un comportamento non implementato.
4. Robustezza del motore **per l'utente singolo**: contenere allucinazioni,
   risposte vuote e non pertinenti, lingua sbagliata, tempi eccessivi,
   conflitti Local/Hybrid/Cloud, disponibilità reale dei provider,
   rispetto dei consensi ai Cloud e limiti di spesa. Misurare latenza e
   regressioni con test di richieste ripetibili. Un fallback deve scegliere
   solo un modello compatibile, configurato e autorizzato; se nessuno
   esiste, spiegare perché senza fingere successo.
5. QA **per piattaforma disponibile**: scenari E2E Android S24 e, quando
   pronti, ASUS Windows, Mac, Linux e Web. Distinguere build CI verde da
   test fisici superati; registrare PASS/FAIL e prove.

**Image LOCAL — prima fase Android, riconoscimento offline reale:**
il runtime FFI `llama.cpp` attuale tratta solo testo e non riceve pixel.
Implementare prima un classificatore locale limitato (ML Kit modello *bundled*)
con etichette e confidence, pre-decoding bounded <=1024 px, bitmap RGB_565,
limite file 8 MB, zero upload e nessuna nuova key API. Dichiarare visivamente
che si tratta di categorie probabilistiche, **non** di visione generale
del modello 3B. LOCAL/HYBRID non devono deviare silenziosamente a Cloud.
Un backend desktop non disponibile deve esporre il limite, non inviare foto.
Seconda fase separata: vera inferenza multimodale `llama.cpp/libmtmd`
con progetto MM projector + GGUF vision quantizzato, modello visivo
esplicitamente scaricato/autorizzato dall'utente, stima RAM con caricamento
esclusivo o dismissione temporanea del modello testo; benchmark S24 fisico
e fallback CPU/accelerazione GPU solo dopo test. Non caricare due grandi
modelli contemporaneamente né considerare il dispositivo incapace a priori.

**Nuovo risultato fisico Image del 27/10/2026:**
sulla build 1.0.15.103459-beta LOCAL mostra correttamente l'impossibilità
di visione, galleria/thumb salvati; Gemini Cloud HTTP 503 ripetuti e timeout
45s, nessuna descrizione riuscita. **FAIL visione**. PR #917 propone
selezione AUTO Gemini configurato in Cloud senza fallback paid e retry
bounded su 503, ancora da integrare/collaudare. I modelli locali correnti
non ricevono pixel solo perché la UI consente di allegare un'immagine.

**Gate F0**: flussi principali e menu "+" e Chat utilizzabili in modo
affidabile e soddisfacente sulle piattaforme disponibili, con errori/limiti
e fallback verificati. Difetti P0 (Web/Live rotto, crash, perdita di chat,
allucinazione grave ricorrente, timeout senza recovery) impediscono di
dichiarare questa fase completa. Le limitazioni hardware non supportate
devono essere esplicite. Nessuna nuova beta solo per accelerare i test:
release e OTA rimangono deliberate, mai installazioni manuali o downgrade.

### Fase 1 — Un solo utente: memoria SQLite di Roberto su un dispositivo

Partire da S24 con dati sintetici e consensuali, non da dati personali reali.
Verificare pipeline reale
\`messaggio -> candidato -> verifica/promozione -> SQLite -> richiamo\` e RAG
con fonte/provenienza; deduplica, aggiornamento e dimenticanza. Provare un
fatto aggiornato (per esempio \`C=420 -> C=680\`), una preferenza durevole,
un riferimento ad una conversazione precedente e un fatto irrilevante.
Distinguere memoria del profilo e memoria della singola chat. Offline,
riavvio e pressione RAM non devono cancellare input o inventare ricordi.
Non promuovere automaticamente in «confermato» un'uscita del modello.
Tracciamento: issue #899.

**Gate F1**: recupero corretto dopo riavvio e su nuova conversazione con
provenienza; reset/dimenticanza solo su dati di prova e senza resurrezione.

### Fase 2 — Roberto su più dispositivi: S24, ASUS, Mac, Raspberry Pi quando pronto

Un solo **profilo personale Roberto**, più installazioni autorizzate, senza
alcun secondo utente reale. Ogni dispositivo conserva una proiezione SQLite
locale minima (ricordi confermati, catalogo, riferimenti alla fonte); non
replicare alla cieca l'intero file DB. Chat recenti e fissate restano locali;
archivio storico cifrato esterno **opt-in** e recuperabile on demand quando
online. Mai inviare conversazioni al repository Diagnostics, che è pubblico.
\`diagnostics.installationId\` può aiutare ad individuare l'installazione e
\`diagnostics.deviceName\` è soltanto l'etichetta visuale, non una credenziale
o una prova di ownership. Pairing e chiavi sono separati (issue #915).

Sequenza di prova crescente, senza sovrapporre tecnologie:
1. **Due database sintetici locali** con export/import cifrato, roundtrip,
   duplicati, correzioni, conflitti, revoca e dimenticanza verificati offline.
2. **S24 <-> ASUS**, usando uno storage privato e un meccanismo di pairing
   autorizzati e scelti esplicitamente. Verificare la memoria in entrambi
   i sensi: parlare di una moto su S24, chiedere su ASUS, confrontare fonti,
   fare una correzione su ASUS, controllarne la propagazione a S24.
3. **Mac** e successivamente **Raspberry Pi/Linux ARM**, solo dopo aver
   verificato compatibilità/build effettive; non dichiarare piattaforme
   installabili senza prova. Test con rete assente e ritorno online.
4. Valutare dimensione SQLite, occupazione disco, RAM, latenza, limiti token
   e banda distintamente. Il trasferimento remoto non libera RAM da solo:
   retrieval selettivo, chunking e cache bounded evitano prompt enormi.
   Nessuna eliminazione locale finché non esistano copia remota cifrata,
   recupero verificato e policy di conservazione approvata.

Riferimenti: issue #911 / PR #912 catalogo additivo, #899 memorie,
#915 dispositivi. Queste basi tecniche possono essere mantenute come PR
pronte, ma **non attivare sincronizzazione multiutente** in questa fase.

**Gate F2**: lo stesso fatto autobiografico è richiamabile solo sui
dispositivi abbinati di Roberto, online e con fallback offline, senza
confusione e senza perdere la conversazione originale.

### Fase 3 — Secondo profilo fittizio sui dispositivi di Roberto

Solo dopo F2, creare profilo test **Roberto1** (o Paolo/Tom) su ASUS e Mac,
con dataset *interamente fittizio*. Per ogni profilo: ID opaco persistente,
base dati/namespace e chiavi separati, account/device pairing autenticato.
Mai usare il nome Diagnostics come autenticazione.

Prove A/B: Roberto associa sport = equitazione e moto A; Roberto1 sport =
nuoto e moto B. Stesse parole, date, ID conversazione \`default\` e memory
key sui due profili non devono causare recupero reciproco; testare cambio
profilo, logout, cache, backup, device revocato e ricerca RAG cross-owner.
Nessun vero utente/familiare viene arruolato qui.

Riferimenti: issue #913 / PR #914 (isolamento del *catalogo* soltanto) e
issue #915 (pairing). La PR #914 **non prova** ancora l'isolamento completo
di SQLite, embedding, provider, cache o storage: richiede test end-to-end.

**Gate F3**: zero contaminazioni tra profili, neppure negli indici e nei
metadati; dati di Roberto sempre intatti.

### Fase 4 — Evoluzione del motore condivisa, memorie private

Due canali indipendenti:
- **Diagnostica tecnica opt-in**, con eventi chiusi/filtrati, senza prompt,
  chat, documenti o informazioni sensibili sul repository Diagnostics
  pubblico; serve a correggere stabilità, prestazioni, regressioni.
- **Skill/esperienze condivisibili opt-in**, estratte come candidati,
  private-data redaction, verifica di utilità, test di regressione,
  protezione da prompt injection/poisoning e approvazione prima della
  distribuzione. Condividere capacità generali (es. confrontare anche
  colori e prezzi se pertinenti), non ricordi sulle moto o sport di
  persone identificate. Non dichiarare training dei pesi del LLM quando
  si tratta di retrieval o procedure.

Avvisi a familiari/contatti di fiducia: funzione separata e successiva,
con consenso revocabile per adulti, requisiti specifici per minori,
minimizzazione, tutela della privacy e attenzione ai falsi positivi.
Nessuna lettura generalizzata delle conversazioni di altri adulti.

**Gate F4**: due profili beneficiano della stessa correzione generale e
mantengono risposte personali differenti e corrette.

### Fase 5 — Distribuzione ad amici e familiari

La versione 1.0.16 resta un **obiettivo futuro riservato**:
solo dopo F0-F4 e autorizzazione esplicita del proprietario del progetto.
Checklist: provisioning, account separati, onboarding, privacy e opt-in,
restore/revoca, cancellazioni, test Android/desktop sulle piattaforme
effettivamente disponibili, test signing e OTA non distruttivo.
Nessuna release, invio di chat, raccolta di dati personali o monitoraggio
a terzi autorizzati soltanto dall'esistenza di questa roadmap.

### Regole operative per evitare dispersione

1. Priorità viva = completare e collaudare menu Chat / "+";
   il prossimo test fisico dopo le chat/pin PASS è **Image** sul S24.
2. Una fase sperimentale **attiva** per volta. La pianificazione di
   memoria multi-dispositivo e multiutente non interrompe F0.
3. Riutilizzare PR #910, #912 e #914; verificare prima CI/overlap/head,
   non creare implementazioni parallele o rami duplicati.
4. Ogni gate richiede **evidenza fisica o test end-to-end pertinente**:
   il verde CI non è «funziona sull'ASUS» o «sincronizzato».
5. Conservare la versione 1.0.15 e la distribuzione OTA ufficiale
   finché una nuova release non sia autorizzata; nessuna modifica
   alla numerazione per questo aggiornamento documentale.

## 15. Direzione prodotto concordata — 29 ottobre 2026

Questo aggiornamento prodotto prevale, per **priorita UX immediate**, sugli
elementi storici delle sezioni precedenti, senza eliminarli né cambiare i
contratti architetturali del Cantiere. Due filoni procedono in parallelo:
**qualita delle risposte** e **design leggero della chat**. La velocita gia
raggiunta e un requisito da preservare, non una nuova corsa all'ottimizzazione.

### P0-A — Risposte affidabili prima dell'apparenza

- Ridurre allucinazioni, affermazioni non supportate, risposte incomplete,
  confusione tra domanda corrente e precedente e citazioni di pagina errate.
  Non inventare valori, fonti, risultati, azioni o percentuali di successo.
- Distinguere e verificare separatamente: recupero dei dati/documenti,
  completezza della risposta, correttezza, contesto della sessione e
  formattazione. Un PDF letto bene non certifica la fedelta di tutte le
  domande future o la qualita del ragionamento.
- LOCAL deve rimanere realmente funzionante senza rete; quando Internet e
  disponibile puo aggiungere funzionalita opzionali. Contenuti di documenti
  locali non vanno inviati a ricerca Web o provider Cloud senza scelta
  autorizzata. Nessun fallback remoto implicito.
- Test riproducibili su Galaxy S24 FE (Phi-3.5 Mini e modelli compatibili),
  ASUS Windows e CI multipiattaforma: documento tabellare, domande consecutive
  senza riallegare il file, chat nuova vs vecchia, fonte/pagina, no
  `prompt_budget`, no ricerca Web indesiderata. CI verde e prova fisica
  restano due livelli distinti. **PASS fisico limitato** sulle build
  103528/103532: in modalita aereo, le risposte successive sul PDF
  hanno riportato quantita, prezzo, codice e pagina corretti per
  Teiera rossa e Tazza blu senza riallegare il documento. Non estendere
  questo PASS alla robustezza generale del modello, alle altre chat o
  al rendering delle tabelle.

### P0-B — Design piu ricco ma economico

- Chat con tabelle Markdown **native e scorrevoli**, titoli, evidenziazioni,
  elenchi, codice e link leggibili; mantenere testo, copia, cronologia e TTS.
  Inserire piccole icone comprensibili (documento, successo, errore,
  avvertenza, copia) solo se sostenute da uno stato realmente verificato.
- Condividere, quando tecnicamente fattibile, lo stesso linguaggio visivo e
  componenti riutilizzabili fra Android, Windows, Linux, macOS e Web.
  Non chiedere a un piccolo modello locale di disegnare l'interfaccia:
  l'app interpreta output strutturati e sceglie componenti nativi.
- Stato al 29/10: PR #931 **integrata** in `main` con sei workflow
  multipiattaforma PASS; APK ufficiale stabile `1.0.15+103532` pubblicato
  e installato su Galaxy S24 FE. Il renderer supporta soltanto tabelle
  Markdown esplicite, con vere righe di testo e fuori dai blocchi di codice.
  **Collaudo fisico S24 eseguito: dati recuperati, resa tabellare NON PASS**.
  Il modello Phi-3.5 Mini LOCAL ha serializzato intestazione, separatore
  e righe su un'unica linea logica (inizialmente anche in un code fence).
  Dopo una richiesta piu precisa produce cinque colonne e tre articoli,
  ma ancora senza i ritorni a capo necessari al renderer. Nessuna tabella
  grafica appare nell'app. Non attribuire il difetto alla sola UI o al solo
  modello e non dichiarare risolto il formato sulla base della CI.
  Collaudo delle tabelle su ASUS ancora da eseguire.
- Ordine incremento UX: tabelle (#931) -> tipografia e piccoli simboli di
  stato verificati -> blocchi codice/link/copia -> eventuali grafici o schede
  leggere. Ogni incremento deve avere test visuali e di regressione.

### Vincolo non negoziabile — Non peggiorare le prestazioni

- **Congelare temporaneamente nuove iniziative di ricerca della velocita**.
  Riprendere le ottimizzazioni delle prestazioni quando la modalita Work
  sara nuovamente disponibile. Non ripristinare vecchi colli di bottiglia.
- Nel frattempo le prestazioni **non sono congelate verso il basso**:
  non introdurre regressioni in latenza percepita, memoria, fluidita chat,
  apertura delle conversazioni, tempo al primo token e reattivita durante
  inferenza locale. Confrontare con la build stabile precedente su S24 FE
  e ASUS con test comparabili.
- Preferire widget nativi, rendering lazy/on-demand, isolamento dei messaggi,
  niente animazioni continue o librerie pesanti per semplici icone/tabelle;
  rispettare la pressione RAM di Phi. Se un cambiamento grafico rallenta,
  correggerlo o rinunciarvi prima della distribuzione.
- Conservare la possibilita di rollback e non cancellare chat, modelli o
  dati dell'utente durante gli aggiornamenti.

### P2 — Avanzamento reale delle attivita: **roadmap futura, non P0**

- Indicatori di fasi, checklist e percentuali **solo quando il Cantiere o gli
  strumenti pubblicano eventi reali e verificabili**. Mai simulare azioni,
  inventare progressi o affermare che una build/PR/ricerca e completata
  senza prova. Non mettere questa funzione davanti ad affidabilita,
  contesto e formattazione della chat.
- Gate futuro: tracciamento persistente verificato, annullamento/ripresa
  reali, UI reattiva senza costi rilevanti sulla inferenza.

### Metodo e prossima verifica

1. Stabilire un piccolo benchmark ripetibile su S24 e ASUS prima/dopo ciascun
   intervento grafico, senza avviare nuove campagne di ottimizzazione.
2. **Punto attuale / prossimo gate:** risolvere il formato tabellare
   generato da Phi-3.5 Mini con un intervento piccolo e sicuro: istruzione
   concisa senza code fence; se necessario, normalizzazione deterministica
   SOLO delle tabelle collassate con intestazioni, separatori, numero di
   colonne e celle non ambigui. Non inventare righe, valori o pagine e
   non trasformare testo normale in tabelle. Preferire dati strutturati
   verificati al chiedere al piccolo modello di riparare output difettosi.
   Test automatici: markdown valido, tabella su riga unica, code fence,
   risposta non tabellare, streaming incompleto e righe ambigue.
   Ripetere il collaudo S24 offline con cinque colonne, tre articoli,
   scorrimento orizzontale e confronto di fluidita/RAM rispetto alla
   build 103532. Finche il test fisico non passa, P0-B resta aperto.
3. Proseguire con affidabilita delle risposte e micro-componenti visivi in
   cambiamenti piccoli, CI pertinente e test su dispositivo, senza aprire
   un secondo percorso di lavoro concorrente sul performance tuning.


## 16. Patrimonio condiviso Aivexus — modelli, esperienze e piattaforme (1 novembre 2026)

Questa sezione aggiorna la visione delle sezioni 10, 14 e 15; non crea una seconda
roadmap. Obiettivo: **il modello e il provider sono esecutori sostituibili**,
mentre i fatti e le esperienze verificati appartengono al core Aivexus.
L'utente può passare da Qwen a Phi, Nemotron o a un provider Cloud autorizzato
senza ripartire da zero. Tutte le piattaforme supportate devono utilizzare il
medesimo contratto, con copie personali sincronizzate solo dopo pairing e
consenso esplicito.

### Stato reale (non estendere i PASS)

- `AssistantDurableMemoryRecord`, `AssistantDurableMemoryStore` e
  `AssistantDurableMemoryContextService` esistono e sono indipendenti dal
  model ID. Il decorator ordinario di chat recupera memorie **confirmed-only**.
- L'acquisizione produttiva oggi supporta istruzioni esplicite `Ricorda che...`;
  non è una capacità di apprendimento semantico generale dalla conversazione.
- S24 FE beta 103627: il recupero di un nome nella stessa chat anche dopo
  uscita/rientro è stato verificato; NON è prova di memoria user-wide fra chat,
  né di trasferimento fra modelli o dispositivi.
- `MemoryFabric` e un adapter CRDT sono presenti nel codice ma la facciata non
  risulta ancora collegata alla DI di produzione: non dichiarare attivo il sync.
- Le test fixture di handoff fra modelli e per procedure verificate sono una
  verifica del core condiviso, **non un test fisico di provider o sincronizzazione**.

### Ordine di realizzazione (P0-A/F1 → F2)

1. **Gate M1 — stesso device, modelli diversi:** record confermato/scope user
   scritto da modello A, letto da modello B tramite il gateway comune; nessun
   replay della chat, candidate invisibili, correzioni e dimenticanza coerenti.
   Distinguere memorie di sessione e memorie di proprietario. Coprire LOCAL e
   provider Cloud soltanto con controlli espliciti della privacy.
2. **Gate M2 — esperienza trasferibile:** introdurre il tipo `procedure` solo
   per esperienze verificate e tracciabili. Un risultato proposto da un modello
   non può auto-certificarsi. Recupero leggibile e non eseguibile per default;
   i moduli della Libreria restano soggetti ai loro gate di test/licenza/sicurezza.
3. **Gate M3 — comprensione e retrieval semantici multilingue:** usare le capacità
   linguistiche del modello e un retrieval multilingue offline dove supportato,
   senza catalogare infinite domande regex. Verificare parafrasi in it/fr/en/es,
   disambiguazione di persone/oggetti e nomi propri, con fallback trasparente.
4. **Gate M4 — memoria personale cross-chat:** acquisizione di candidati con
   provenienza, controllo/promozione dell'utente, rilevanza, deduplica,
   correzioni, cancellazione e isolamento owner/account, preservando SQLite e
   il contesto minimo sullo smartphone.
5. **Gate M5 — dispositivi:** S24 → ASUS Windows → Mac → Linux/Web compatibili;
   schema/versione portabili, export/import cifrato e pairing autorizzato,
   sync verificata, cache offline e propagazione di revoche/tombstone.
   Riferimenti #899 e #911, senza duplicare la Libreria o il Cantiere.
6. **Gate M6 — apprendimento esterno:** conoscenza Web con fonti e data,
   autorizzazione a rete/Cloud distinta dalla memoria privata, verifica delle
   fonti, protezione prompt injection. Memorizzare conoscenza validata e skill,
   non promettere fine-tuning dei pesi automatico.

### Invarianti e prove

- Nessun modello, plugin o servizio remoto diventa proprietario dei ricordi.
- Niente upload automatico di chat/ricordi personali per farli leggere a un
  modello Cloud. Uso di un Cloud AI ≠ consenso per sincronizzare su storage.
- Nessun modello può promuovere la propria risposta a procedura verificata senza
  prova indipendente. Il richiamo di una procedura non abilita l'esecuzione.
- Memoria presente offline, isolata da altre persone/owner e consultabile,
  correggibile e dimenticabile; riferimenti originali non riscritti.
- Misurare S24 FE: RAM/TTFT, finestra token, batteria e regressioni;
  preservare le prestazioni attuali e non aggiungere carichi per ogni token.
- CI condivisa e QA delle piattaforme sono necessari, ma una CI verde non
  sostituisce un test fisico. Distribuzione Android solo tramite
  **Impostazioni → Aggiornamenti**, senza reinstallazione né reset delle chat.

## 17. Modalita Hybrid cognitiva — obiettivo approvato (1 novembre 2026)

**Tracciamento unico:** [#973](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/973). Questa sezione e parte della roadmap canonica e non sostituisce i ring del Cantiere, la memoria #899, il sync #911 o il gate privacy #972.

### Esperienza da raggiungere

- **Intelligenza:** Aivexus distribuisce compiti a Local e Cloud secondo capacita e costo; usa verifiche incrociate e fonti quando servono. La superiorita delle risposte e una ipotesi misurabile, non una proprieta gia dimostrata.
- **Rapidita:** Local-first sul semplice, Cloud autorizzato sul complesso, parallelismo solo per step indipendenti. Non aumentare il tempo di prima risposta o la pressione RAM per ogni messaggio.
- **Memoria evolutiva:** unico core indipendente dai modelli, dati duraturi verificati e ricerca semantica multilingue, provenienza, correzione/dimenticanza e separazione personale/generale. Riutilizzare #899/#911/#913, non duplicare writer/stores.
- **Continuita:** ad ogni step importante persistito, salvare checkpoint semantici riutilizzabili da un modello diverso. Se Cloud cade, Local recupera l'ultimo stato *effettivamente ricevuto e salvato*, completa il lavoro compatibile oppure conserva lo stato per la ripresa successiva.
- **Privacy e consenso:** il modello Cloud riceve solo contesto necessario, autorizzato e classificato. Memorie PRIVATE non passano automaticamente a Cloud/Hybrid. Protezione in PR #972 e consenso granulare futuro; non aggirare questa barriera per ottenere una risposta migliore.
- **Offline:** HYBRID degradato a Local con modello valido, senza chiamate remote; nessuna perdita delle chat, dei file originali o dello stato persistito.

### Vincolo tecnico sulla continuita dei ragionamenti

Non e possibile recuperare la chain-of-thought nascosta di un provider Cloud o output non ancora restituiti. Il protocollo deve richiedere e acquisire **risultati intermedi espliciti**: piano/stato, passi completati, evidenze, fonti, calcoli trasmessi, artifact verificati, parti rimanenti, versione/identita del lavoro, modello/provider e consumi. Uno stream parziale non verificato resta provvisorio. Il passaggio Cloud -> Local crea un nuovo Attempt della stessa Execution; non una nuova attivita e non un retry del prompt iniziale.

### Priorita incrementale (una fase attiva alla volta)

1. **H0 — Baseline e compatibilita:** audit di routing/fallback attuali, test di privacy/offline/costi, verifica contratti Cantiere riutilizzabili. Stato: **da implementare e validare**.
2. **H1 — Checkpoint e recupero effettivo Cloud -> Local (P0):** persistenza locale atomica, idempotenza, handoff minimo, crash/restart, disconnessione simulata e ripresa senza ripetere gli step conclusi. Stato: **da implementare e validare**.
3. **H2 — Collaborazione per capacita:** planner e policy bounded, parallelismo prudente, critic/verifica finale, routing osservabile. Stato: **futuro**.
4. **H3 — Memoria evolutiva comune:** completare #899 e privacy #972 prima dei trasferimenti personali, poi sync cifrata opt-in #911 e retrieval multipiattaforma. Stato: **parziali fondamenta, non E2E certificato**.
5. **H4 — Benchmark fisici:** prove sintetiche ripetibili Local vs Cloud vs Hybrid su accuratezza, fonti, continuita, tempo, RAM, batteria e spesa; prima S24 FE, poi Windows/macOS. Stato: **futuro**.
6. **H5 — API per compiti estremi (ricerca futura):** cercare modelli di almeno 500B parametri con accesso API **verificabilmente gratuito** e termini compatibili, valutando qualita, limiti e stabilita. Nessuna garanzia di disponibilita/costo zero; dimensione del modello non equivale a qualita. Stato: **ricerca futura, non dipendenza P0**.

**Gate H1 prima di dichiarare PASS:** perdita rete dopo risultati Cloud persistiti -> Local usa gli step completati; perdita rete prima di output -> nessuna invenzione; output parziale marcato provvisorio; crash/restart e doppio callback idempotenti; nessuna rete in offline e nessuna fuga di dati privati; nessun peggioramento ingiustificato delle prestazioni S24. CI verde non equivale a collaudo fisico. Release Android/desktop esclusivamente dal percorso di aggiornamento in-app #948.
