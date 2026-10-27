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
