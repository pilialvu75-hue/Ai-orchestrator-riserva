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
