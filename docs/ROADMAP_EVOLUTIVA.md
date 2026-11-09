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

### Gate M4-C — Consenso per l'effettiva divulgazione Cloud in HYBRID

- **Conoscenza Aivexus, decisione dell'utente.** Il modello LOCAL che esegue
  realmente un passaggio HYBRID recupera le memorie pertinenti e confermate
  autorizzate sul dispositivo; la protezione #972 che le escludeva in HYBRID
  prima del routing resta un gate TEMPORANEO fino al collegamento sicuro.
- La modalità Cloud/HYBRID **non equivale** a consenso implicito per tutti i
  ricordi. Prima di qualsiasi invio l'utente deve sapere il provider/account
  destinatario, l'esatto testo del payload, il motivo, la fonte (domanda,
  cronologia, memoria, RAG, documenti/allegati, strumenti, istruzioni) e il
  livello di riservatezza. Non soltanto i ricordi SQLite possono essere privati.
- Per ogni categoria e provider: **solo questa volta**, **sempre per questa
  categoria con questo destinatario**, **approva ora e chiedi ogni volta in
  futuro**, **nega questa volta**, **non condividere (persistente)**.
  Memorizzazione protetta, dashboard Impostazioni per revisione/revoca,
  propagazione delle cancellazioni/forget e nessuna replica automatica.
  I contenuti non classificati non ottengono permessi automatici permanenti.
- Se una sezione non è autorizzata, impedire l'invio dell'intero vecchio
  payload; ricomporre un prompt senza quella sezione oppure proseguire Local
  e chiedere il consenso pertinente. Nessun fallimento nascosto né dati
  classificati inventati da un modello: serve un assemblatore trusted che
  certifichi che i segmenti coprono **esattamente** il testo inviato.
- **LOCAL = senza provider IA esterni/Cloud**: non significa per forza
  assenza totale di Internet. Strumenti Web, retrieval remoto, download e sync
  sono servizi separati e soggetti alle rispettive impostazioni/consensi. Non
  inviare mai prompt o ricordi ai provider IA remoti tramite fallback implicito.
  L'inferenza LOCAL deve continuare a funzionare anche senza connessione.
- **Impostazioni → Modalità IA → Consensi Cloud**: sottomenu per consultare,
  modificare e revocare regole per fonte e sensibilità, provider e account.
  L'autorizzazione «solo questa volta» non viene salvata. Il sottomenu
  e la finestra di review sono realizzati nella PR #977. Una identità locale
  protetta per installazione abilita la gestione delle regole sul dispositivo,
  ma **non autentica l'utente nei provider Cloud** e non basta per autorizzare
  il dispatch. Collegare in seguito la verifica del destinatario, il dialogo
  nella Chat e il controllo esatto del payload. Prevedere inoltre
  autorizzazione esplicita opzionale su tutti i provider approvati senza
  includere automaticamente provider/account futuri.
- **Stato tecnico H10–H22 (#977, ancora DRAFT):** contratto di consenso,
  revoca e permessi monouso, dialogo/UI multilingue, invio nativo mock
  OpenAI/Gemini e risposta nel formato Aivexus. Il produttore reale RAG
  `ChatFileContextService` conserva separatamente domanda, istruzioni e
  estratti senza cambiare il prompt LOCAL (H11). Il retrieval reale di
  `AssistantDurableMemoryContextService` espone intestazione applicativa e
  record confermati, senza includere candidati (H12). L'assemblatore
  `HybridCloudTrustedRequestAssembler` verifica che domanda, cronologia,
  RAG e memorie corrispondano **esattamente** all'`AiRequest` da autorizzare,
  impedendo append invisibili (H13).
- **H14 — trasporto con consenso davvero separato (solo opt-in):**
  `CloudRuntimeProvider(consentGated: true)` richiede una callback
  `consentGatedSend` dedicata. Senza di essa rifiuta la richiesta;
  non esegue mai il vecchio `sendQuery`, non usa cache Cloud, non tenta
  automaticamente un altro provider nemmeno su errore generico. La richiesta
  viene prima proiettata nelle forme realmente serializzate da OpenAI/Gemini.
  `HybridCloudRuntimeConsentCoordinator` collega le prove originali,
  l'identità locale protetta, credenziale con account esplicito,
  assemblatore H13, review, permesso monouso e invio native HTTP in un
  test completo con client mock. Sorgente o dialogo assenti = nessun HTTP.
  Il percorso applicativo ordinario NON è stato abilitato.
- **H15 — annullamento durante review e revoca prima di HTTP:** il token
  della richiesta segue il percorso `CloudRuntimeProvider` ->
  `HybridCloudRuntimeConsentCoordinator` -> manager di consenso ->
  permesso monouso -> native HTTP. Annullare la conversazione mentre è
  visibile il dialogo impedisce sia il POST sia nuovi permessi persistenti;
  un ulteriore controllo sincrono del token è fatto nel punto in cui
  `dispatchApproved` avvia realmente il client HTTP. Test simulano un
  dialogo sospeso, l'annullamento prima di rispondere e l'annullamento
  dopo un permesso ottenuto, prima dell'avvio HTTP.
- **H16 — provenienza dalla Chat realmente attraversata dal runtime:**
  `ChatRepositoryImpl` genera un oggetto di provenienza per le domande
  inviate con routing Cloud diretto, usando la vera domanda originale,
  l'istantanea della cronologia recuperata, le istruzioni ricevute e, ove
  presente, la provenienza dell'estratto `ChatFileContextService`. Dati
  immagine/video/allegati non ricondotti a un documento verificato rimangono
  privi di evidenza e saranno negati dal gate se attivato. La nuova proprietà
  tipizzata di `InferenceRequest` è in RAM, preservata da `copyWith`
  e mai serializzata nei metadata HTTP.
- `InferenceService` aggiunge normalmente data/ora e fuso orario
  dell'app al system prompt. H16 lega anche questa aggiunta al testo esatto
  realmente creato dal runtime; se un'altra fase ha alterato il sistema,
  elimina l'evidenza senza cambiare il percorso LOCAL/Cloud esistente.
  `HybridCloudTrustedRequestAssembler` include il suffisso certificato
  nella review, mentre `HybridCloudRuntimeConsentCoordinator` controlla
  che la cronologia Cloud ottimizzata sia solo una sottosequenza dei turni
  realmente letti dalla Chat, senza aggiunte o riordinamenti.
- **H17 — gateway di approvazione nella vera pagina Chat:** il nuovo
  `HybridCloudChatConsentGateway` mostra il dialogo già localizzato
  IT/FR/EN/ES soltanto quando la pagina Chat è montata, il suo ID conversazione
  corrisponde alla richiesta e un invio è attivo. La pagina registra un
  binding revocabile, invalida i dialoghi pendenti quando si apre o si
  ripristina un'altra conversazione, all'inizio di un nuovo invio, al recupero
  da blocco e durante dispose. Il gateway rimuove soltanto la rotta esatta
  della review, senza chiudere pagine o dialoghi estranei; una risposta tardiva,
  il cambio pagina e l'annullamento ritornano una mappa vuota e NON un
  consenso. Le scelte non persistono qui: soltanto il consent manager possiede
  tale responsabilità. Il coordinatore dispone di `chatReview` con l'ID
  sessione Chat e la condizione `requestStillActive` separati dall'identità
  locale owner.
- **H18 — provenienza fino alla decisione di Hannibal in HYBRID:**
  `ChatRepositoryImpl` assegna la stessa prova tipizzata usata dal percorso
  Cloud anche al percorso `Orchestrator.handleStream`. Hannibal trasporta
  la prova immutata attraverso `InferenceRequest` quando sceglie un provider
  Cloud per una domanda ordinaria, con contesto e istruzioni effettivamente
  identiche; la perde intenzionalmente in caso di risultato Web/tool aggiunto,
  argomento riscritto, prompt con marker Web offline per documenti, allegati
  senza fonte verificata. `AssistantWebAwareOrchestrator` scarta la prova
  dopo arricchimento Web, senza interrompere l'inferenza LOCAL/Cloud
  preesistente. Test con router HYBRID mock certificano mantenimento nei
  percorsi invariati ed esclusione dei risultati Web/estratti modificati.
- Test widget reali del gate H17 inseriti nella pipeline CI condivisa
  su Ubuntu e macOS, insieme al dialogo di review multilingue preesistente.
  Non scambiare il solo verde dei sorgenti Android per test UI eseguiti.
- **H19 — memoria confermata SOLO nel ramo Hybrid->LOCAL:**
  dopo la decisione reale `Orchestrator._routeRequest`, se Hannibal ha scelto
  `localOnly` e la prova deriva dalla chat corrente, usa
  `AssistantDurableMemoryContextService.augmentSystemPrompt` per recuperare
  soltanto ricordi pertinenti e confermati in SQLite. La ricerca non avviene
  prima della decisione di routing e non cambia la risposta quando la memoria
  non è pertinente o il database non è disponibile. L'aggiunta avviene su
  una `InferenceRequest` **localOnly**, senza fallback ad altri provider IA,
  senza evidence Cloud riutilizzabile e con Web/tool-call disabilitati
  quando la memoria entra nel prompt (evita che un tool dinamico trasformi
  un ricordo in una query di rete). Se Hannibal sceglie Cloud, il retrieval
  privato non è nemmeno invocato: restano solo domanda, contesto e dati
  già condivisibili secondo regole preesistenti, senza memoria durevole.
  Il servizio LOCAL nativo non viene alterato; nessuna nuova tabella DB.
- **H20 — revalidazione della credenziale Cloud alla frontiera HTTP:**
  il coordinatore acquisisce in memoria la chiave esatta del provider prima
  di mostrare l'anteprima e la passa soltanto al sender gated, senza salvarla
  nelle decisioni, nel prompt, nei log o nel fingerprint della disclosure.
  Il `HybridCloudNativeWireSender` confronta sincronicamente la chiave
  attuale con quella fissata prima della review, nel punto immediatamente
  precedente al POST. Cambio di chiave durante la review, persino con
  provider e nome account identici, impedisce l'invio. L'attestazione
  riguarda la singola richiesta; NON dimostra ancora l'identita
  autenticata lato provider e non risolve i permessi persistenti dopo
  riconfigurazione delle credenziali tra sessioni. Test mock HTTP coprono
  entrambi i casi di sostituzione account/chiave e non-send.
- **H21 — permessi persistenti legati alla generazione della credenziale:**
  ogni chiave API configurata manualmente ottiene in secure storage
  un identificativo casuale a 192 bit, stabile ai riavvii e rinnovato
  con ogni modifica della credenziale, **anche con lo stesso account e
  la stessa chiave**. Credenziali vecchie vengono migrate nello stesso
  store protetto, senza importare alcun consenso da registri legacy;
  se la migrazione fallisce, il Cloud ordinario non perde la chiave ma
  il trasporto gated rifiuta la condivisione.
  La review continua a mostrare l'etichetta account, mentre chiavi
  dei permessi e fingerprint contengono anche l'identificativo di
  generazione. Nessun permesso `allowAlways` registrato con la sola
  etichetta account viene riutilizzato dopo la migrazione.
  `HybridCloudNativeWireSender` controlla la generazione corrente
  insieme a provider, account, chiave esatta e token di cancellazione.
  Anche Impostazioni -> Consensi Cloud usa questa identita protetta;
  cambi chiave mentre un dialogo di modifica e aperto annullano la
  scrittura. Test automatici includono persistenza e riavvio,
  sostituzione credenziale con stesso nome, migrazione, mancata
  ereditarieta dei permessi, UI e cancellazione durante review.
  La generazione non prova un login verificato dal provider, quindi
  il dispatcher Cloud in produzione rimane disattivato finche non
  saranno completati bootstrap, E2E dispositivo e selezione account.
- **H22 — Chat Cloud opt-in collegata al trasporto gated reale:**
  `HybridCloudAssistantRuntimeBundle` costruisce un provider Cloud
  dedicato alla sola Chat con lo stesso protocollo reale delle sorgenti
  OpenAI/Gemini: origini trusted da Chat, verifica destinatario e
  credenziale, review del dialog visibile, permesso monouso e POST
  HTTP nativo. Il provider ordinario registrato globalmente per
  Cantiere, diagnostica e altre funzioni resta invariato.
  `CloudRoutingBootstrap.configure` accetta il flag esplicito
  `enableConsentGatedAssistantCloud`, che per il normale avvio
  resta **false**: non attivare senza account/migrazione Settings,
  collaudo E2E e test sul Galaxy S24 FE. Se abilitato, il provider
  dedicato e passato sia al `DirectiveAwareInferenceService` della
  Chat sia al router Hannibal; mancanza di UI, credenziali legate
  a un account o evidenza trusted blocca l'invio. Solo OpenAI/Gemini
  sono ammessi nel gate; nessun fallback al callback Cloud legacy.
  `HybridCloudRuntimeConsentCoordinator` rifiuta ogni cambio
  silenzioso da un provider fissato dall'utente a un provider diverso.
  Test mock HTTP verificano invio approvato, dati esatti, esclusione
  dei provider non supportati, rifiuto senza origine confermata
  e blocco delle chiavi ambiente senza consenso account.
  **Non ancora release:** mancano opt-in UI/Settings autenticati,
  selezione provider verificata sul dispositivo, gestione del consenso
  negato senza perdita dei ricordi Local e QA fisica.
- **H23 — barriera agli allegati visivi nel trasporto Chat con consenso:**
  il flag sperimentale `enableConsentGatedAssistantCloud` blocca il percorso
  separato Image/Video Cloud prima di invio e conversione storyboard, poiche
  l'anteprima corrente classifica testo e documenti, non pixel/fotogrammi.
  Il controllo avviene all'ingresso e prima del trasporto visivo, anche dopo
  eventuali cambi della modalita durante la preparazione. LOCAL e HYBRID
  mantengono l'analisi locale delle immagini e la Chat installata mantiene
  il flag predefinito false. Aggiunta regressione alla CI Assistant Shared
  Tests: il suo esito sul commit H23 va ancora verificato. Nessuna release.
- **H24 — regressione del ChatRepository effettivo e avviso documentale:**
  test con datasource fittizio e impostazione Cloud dimostra che la Chat
  opt-in rifiuta Image/Video prima della scrittura del messaggio, della
  creazione del contesto e di qualsiasi inferenza; il test si aggiunge
  alla CI condivisa Ubuntu/macOS. Per documenti Cloud con gate attivo,
  la Chat ora indica che gli estratti sono preparati per la review e non
  dichiara prematuramente un upload riuscito. Test simulato, non prova
  di traffico reale su S24; risultati CI della HEAD ancora da confermare.
- **H25 — rifiuto di consenso Cloud con prosecuzione HYBRID->LOCAL:**
  il sender gated restituisce il motivo `InferenceErrorCode.cloudConsentDenied`,
  anziche affidarsi al testo del messaggio. Una richiesta HYBRID di origine
  Chat verificata puo quindi proseguire con `localOnly` dopo rifiuto
  senza un secondo provider Cloud: il riferimento al provider Cloud e
  la vecchia evidence vengono rimossi. Il recupero dei ricordi
  confermati si verifica soltanto DOPO la scelta LOCAL, impedendo
  trasferimenti impliciti di memoria privata. Non avviene fallback
  per errori generici, Cloud ordinario, o dopo testo gia prodotto.
  Test di routing e test del bundle con HTTP simulato nella suite
  Assistant Shared Tests; il risultato CI di H25 va verificato.
  Non ancora continuita con checkpoint/semantic resume reale.
- **H26 — integrazione Chat reale -> consent -> HTTP simulato:**
  prova integrata `ChatRepositoryImpl` con datasource in memoria e
  `ConversationMemoryService` simulato, servizio di inferenza che
  delega al provider consent-gated reale, credenziale/identita protette
  fittizie, review Chat sintetica e HTTP OpenAI mock. Verifica la
  provenienza generata dal ChatRepository, provider fissato,
  contenuto esatto approvato, risposta salvata e mancato POST
  quando la review nega consenso. Questa non e una prova di bootstrap
  integrato, provider reale, UI Flutter fisica o connettivita S24;
  i nuovi test entrano nella suite CI Ubuntu/macOS e non consentono
  ancora l'attivazione del flag produttivo.
- **H27 — nessuna ricerca Web anticipata senza consenso:**
  l'adattatore Chat Cloud `CloudWebEnrichingChatRepository` possiede un
  percorso separato per cercare automaticamente domande aggiornate su
  motori pubblici prima della review Cloud. Nel trasporto sperimentale
  gated ora la ricerca preventiva e proibita, per impedire che testo
  personale venga trasmesso a servizi Web senza informativa specifica.
  La domanda originale passa intatta al consent gateway; il percorso
  Web legacy, con flag disattivato, resta invariato. Test di regressione
  verificano zero chiamate al Web tool nel gated Cloud e il normale
  percorso legacy gia collaudato. I risultati CI H27 sono da verificare.
  Una ricerca Web nel nuovo trasporto richiedera in futuro un consenso
  dedicato e provenienza verificata; questa protezione non copre ancora
  tutte le operazioni Web di altri flussi.
- **H28 — tutela delle query Web pre-consenso in HYBRID:**
  il router Web-aware cerca notizie, verifiche e risultati freschi
  prima della selezione CLOUD/LOCAL. Quando usa il provider Cloud
  `consentGated` in HYBRID, il pre-enrichment ora non puo interrogare
  il Web esterno senza una review specifica. Gli intenti Web espliciti
  passano al modello LOCAL senza eseguire il tool Web, tramite una
  richiesta offline-per-quella-operazione; la modalita LOCAL scelta
  dall'utente e la ricerca legacy non cambiano. Test di regressione
  verificano zero chiamate Web e il routing locale per l'intento
  Web esplicito. Non si promette aggiornamento live dei fatti
  senza un consenso separato; CI della HEAD ancora da verificare.
- **H29 — rifiuto Cloud senza query Web nel fallback LOCAL:**
  il consenso Cloud negato avvia esclusivamente il modello LOCAL e non
  autorizza un'ulteriore trasmissione della stessa domanda tramite un tool
  di ricerca Web. Il fallback disabilita `allowWebSearchTool` anche quando
  la memoria non aggiunge alcun testo o non e disponibile. Due regressioni
  con rifiuto tipizzato e senza/con callback memoria invariata verificano
  `localOnly`, assenza di failover e divieto Web. La modifica non spegne
  le ricerche Web ordinarie nella modalita LOCAL impostata dall'utente,
  ma vincola soltanto questa continuazione dopo diniego. CI della nuova
  HEAD da verificare, flag Cloud produttivo ancora false e nessuna release.
- **H30 — prerequisiti build di collaudo HYBRID (solo sorgente):**
  `RuntimeBootstrap` permette un flag Dart compile-time
  `AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA=true`, di default FALSE
  nelle release e negli aggiornamenti correnti. Solo le build QA
  preparate esplicitamente collegano il sender gated al bootstrap.
  `Modalita IA -> Consensi Cloud` apre la pagina inerte nelle build
  ordinarie e, solo in una build QA attiva, le regole verificabili
  mediante la medesima identita locale OS-protected del sender;
  tale identita di installazione NON equivale a un login Cloud
  e non autorizza sincronizzazione o multiutente.
  Per OpenAI/Gemini e disponibile un campo esplicito etichetta account,
  salvato insieme a una NUOVA API key nel record OS-protected:
  le credenziali preesistenti prive di account NON diventano autorizzate
  in automatico. La sostituzione chiave ruota la generazione di consenso.
  CI verifica entrambi i valori del gate e test di consenso preesistenti.
  Il bundle non viene registrato in modalita ordinaria; nessun invio
  di dati privati o release e autorizzato da questo solo commit.
  Windows Beta: download runtime CPU/Vulkan ufficiali ritenta fino
  a 3 volte su errori HTTP transitori conservando entrambi gli hash
  SHA-256 obbligatori. Il packaging macOS sqlite3 resta bloccato
  finche non e verificata l'origine del file con SHA errato.
- **H31 — riconciliazione con main (5 novembre):** dopo confronto
  a tre versioni da `b795b3b`, sono preservate 17 modifiche Web/NVIDIA
  e memoria ME-2 indipendenti; `app_localizations.dart` integra
  le otto sostituzioni testo ME-2 nelle cinque lingue mantenendo
  le nuove traduzioni H7/H21 dei consensi Cloud. Merge a due
  genitori nel SOLO branch draft #977; main intatto, nessuna release.
  Verificare la CI completa di questa HEAD prima di attivare QA.
- **H32 — collaudo Windows HYBRID compile-time ON:**
  il workflow autonomo `.github/workflows/hybrid-consent-windows-qa.yml`
  esegue esclusivamente sulla PR #977 interna test di consenso con
  flag QA attivo, build Windows release con lo stesso flag, integra
  CPU e Vulkan ufficiali con SHA256 pin, prova GGUF Local e produce
  ZIP portatile isolato + SHA256 + istruzioni. Non pubblica release
  o aggiornamenti Android. Serve comunque collaudo fisico e provider
  reale per dichiarare HYBRID pronto.
- **H33 — QA con consenso attivo su macOS e Linux:**
  Workflow isolato `.github/workflows/hybrid-consent-macos-linux-qa.yml`
  per la sola PR #977 interna: compila macOS e Linux con
  `AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA=true`, testa il gate
  e i componenti Chat, esegue il motore GGUF reale e conserva
  controlli nativi/signature/GUI delle pipeline desktop ordinarie.
  Produce solo archivi portatili GitHub Actions, con SHA256 e README,
  senza release, installer .deb o manifest OTA. Corretto il README
  delle nuove build Windows QA per imporre un profilo OS separato:
  archivi portatili NON isolano automaticamente database, preferenze
  o credenziali. La CI H33 deve superare i suoi test; e' ancora
  necessario il collaudo su hardware reale con provider autorizzato.
- **H34 — regola permanente: beta HYBRID multipiattaforma per milestone**
  (direttiva owner 6 novembre 2026):
  pubblicare occasionalmente una **beta di collaudo** quando HYBRID sia
  sufficientemente funzionante e si ottenga un progresso concreto; non
  effettuare release di routine a ogni commit e non aspettare che ogni
  funzionalita' futura della roadmap sia completa. Cadenza guidata dai
  gate, non da una scadenza arbitraria. Un controllo periodico dedicato
  al readiness viene eseguito due volte a settimana; NON equivale a
  autorizzazione a saltare test o inviare dati personali.
  I workflow H32 Windows e H33 macOS/Linux con flag di consenso ON
  hanno superato test runtime, GGUF e bundling su runner Actions:
  **QA desktop CI PASS**, NON E2E fisico ne' rilascio/OTA.
  La convalida Android e' ancora source-only. Il canale release
  produttivo continua a compilare il flag di consenso su FALSE.

  **Gate minimo per la prima beta HYBRID:** (1) integrare il branch
  HYBRID su main dopo riconciliazione delle modifiche concorrenti;
  (2) impostare e verificare il consenso protetto **solo nelle beta**
  Android e desktop, senza abilitarlo nelle stabili o nelle build
  preesistenti; (3) prove automatiche e almeno uno smoke E2E della
  Chat reale: provider/account selezionato senza sostituzione
  silenziosa, preview prima di qualunque invio, permesso una sola
  volta/sempre, rifiuto e revoca senza leak, rotazione della chiave,
  memoria confermata in HYBRID-LOCAL senza invio non autorizzato,
  fallback LOCAL e recupero dopo interruzione rete quando supportati;
  (4) CI verde per il **medesimo commit** Android, Windows, macOS,
  Linux e, ove applicabile, Web; verifica runtime/local GGUF e
  checksum degli asset; (5) Android firma e versionCode compatibili
  con l'app installata, distribuzione **solo** da Impostazioni ->
  Aggiornamenti (nessun APK manuale, uninstall o downgrade);
  (6) pubblicazione con il meccanismo GitHub owner-beta-checkpoint
  esistente, che avvia un Android beta autorizzato e i publisher
  Windows Setup, macOS DMG e Linux .deb **dallo stesso SHA e tag**.
  Verificare realmente che gli asset di tutte le piattaforme
  compaiano nella release e che gli aggiornamenti siano raggiungibili
  dall'app. La firma macOS ad-hoc e' ammissibile per l'uso privato
  se OS la accetta; mai spacciare ad-hoc per notarizzazione.
  Web richiede collaudo/deploy separato della sua implementazione,
  non simulare un'app HYBRID Web nativa se non esiste.
  Se un asset o un percorso essenziale fallisce, marcare beta
  INCOMPLETA e correggere prima di annunciare release coordinata.
  Ogni checkpoint deve riportare SHA/tag, piattaforme, risultato
  installazione/OTA, difetti e prossime prove. Main e stabile
  rimangono protetti mentre i gate sono aperti.
- **H36 — attestazione verificata per la futura beta coordinata:**
  i sorgenti dei workflow publisher vengono predisposti per compilare
  il consenso HYBRID **solo** quando l'owner seleziona esplicitamente
  `hybrid_consent_beta=true` nel workflow Android beta autorizzato.
  Il default rimane false per beta ordinarie, stable, nightly, dev e CI.
  Se qualcuno tenta di attivare il gate fuori dal canale beta, il
  workflow fallisce prima di compilare o pubblicare.

  `scripts/hybrid_beta_release_manifest.py` produce un'attestazione
  senza segreti, allegata alla release Android, con SHA commit
  sorgente, run number, tag SemVer, canale e flag. I publisher
  Windows/macOS/Linux leggono la release già autorizzata, verificano
  che tag, SHA e run number corrispondano precisamente a quelli
  della build Android, poi applicano lo stesso flag Dart alle
  proprie build. Un'attestazione mancante/incoerente in una release
  di nuovo formato e' un errore; release legacy prive dello script
  restano con il gate spento. L'attestazione verifica la provenienza
  della release, **non** e' una firma digitale autonoma.
  Test automatici separati verificano beta ON, default OFF,
  stable/nightly/dev non attivabili, SHA/tag/run errati, manomissioni,
  collegamento alle quattro build e gate publisher preesistenti.
  Non sono mai disattivati SHA256 dei runtime, firma Android o
  controlli privacy.

  Questa modifica preparatoria e' **solo nel branch draft #977**
  finche' non saranno superati test Chat reale, interruzioni rete,
  permessi revocati, resume LOCAL e QA fisico. Il comando owner
  `/aivexus beta-checkpoint <SHA>` esistente continua a generare
  una beta ordinaria con consenso HYBRID spento, finche' non viene
  esplicitamente esteso/autorizzato. Nessuna release in questa fase.
- **H38 — Android HYBRID QA con flag realmente ON, senza OTA:**
  estesa la CI `Assistant Android Source Validation` affinche'
  soltanto la PR interna #977 sul branch HYBRID compili il suo APK
  **debug effimero** ARM64 con
  `AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA=true`; per ogni altro
  PR/ref il flag resta false. Prima della compilazione viene testato
  il valore del bootstrap con define ON/OFF, i test di runtime
  consent-gated e integrazione Chat, il widget del dialogo con
  sessione visibile, l'impostazione Consensi Cloud; poi rimangono
  obbligatori l'audit delle esportazioni FFI arm64 e hash del
  pacchetto. La compilazione serve soltanto a rilevare regressioni
  Flutter/Gradle/native su Android, NON firma un rilascio beta,
  NON carica l'APK come release, NON installa sui dispositivi.
  Dopo CI PASS restano da verificare test fisico sul S24 FE,
  canale OTA firmato approvato, assenza di leak di memoria e
  passaggio LOCAL/Cloud su rete interrotta e ripristinata.
- **H40 — continuita HYBRID quando il trasporto Cloud cade:**
  primo passo del requisito Cloud->LOCAL->Cloud, senza introdurre
  ripetizioni di invii Cloud o nuovo Web automatico. Il sender HTTP
  consent-gated riconosce **solo** `http.ClientException` e
  `TimeoutException` al confine della richiesta gia' autorizzata
  e le converte in una causa tipizzata senza contenuto privato.
  Una risposta HTTP (inclusi 401, 429, 503), un rifiuto di consenso,
  un parser fallito o un'eccezione generica NON sono perdita di rete.
  Il runtime produce `InferenceErrorCode.cloudTransportUnavailable`,
  registra il provider temporaneamente indisponibile e non prova
  mai un secondo provider Cloud nella stessa richiesta.

  Solo un'origine Chat verificata, modo HYBRID, trasporto protetto
  e zero testo Cloud gia' prodotto consentono a Hannibal di proseguire
  **quella singola domanda** in LOCAL. Il nuovo InferenceRequest
  scarta provider Cloud, evidenza Cloud e failover, vieta ricerche Web
  automatiche e arricchisce memoria confermata soltanto dopo
  `localOnly`. L'annullamento non attiva il fallback.
  Test con rete mock che cade dopo un solo invio autorizzato,
  assenza di retry Cloud, zero leak, risposta 401/429/503,
  provenienza non verificata e stream gia' parzialmente prodotto.
  La perdita di rete dopo un HTTP inviato puo' lasciare incerto
  se il server abbia elaborato il payload: non ritentare il POST.

  **Rimane fuori da H40** la continuita semantica multipasso
  con checkpoint persistenti, la ripresa di un task Cloud iniziato,
  la rigenerazione di contesto dopo riavvio, nonche' il
  reinstradamento automatico LOCAL->Cloud al ritorno della rete.
  Questi richiedono un journal e test end-to-end separati.
  H40 e' una modifica nel solo branch draft #977 finche' i
  nuovi workflow CI e i test fisici non risultano verificati;
  nessuna beta e' pubblicata da questa sola modifica.
- **H41 — checkpoint beta con consenso HYBRID esplicito:**
  Il comando owner preesistente `/aivexus beta-checkpoint <SHA>`
  continua a rilasciare la beta ordinaria con gate HYBRID OFF.
  Il nuovo comando separato `/aivexus hybrid-beta-checkpoint <SHA>`,
  valido **solo** come commento dell'owner sull'issue #1008 aperta,
  seleziona l'input beta `hybrid_consent_beta=true`.
  Un checkpoint proveniente dal merge di una PR non puo' abilitare
  HYBRID implicitamente. Restano le verifiche obbligatorie:
  autore e attore owner, corpo esatto SHA corrente di main,
  nessun secondo run Android per lo stesso SHA, cinque suite CI
  post-merge verdi su main, presenza del flag protetto nel
  workflow sorgente. Il comando non esegue testo utente come
  shell, non abilita la stabile e mantiene l'unico workflow
  downstream di release Android per tutti i publisher desktop.
  Test statici Python nel gate CI verificano i confini owner,
  idempotenza e differenza beta normale/HYBRID.

  **H41 non e' una pubblicazione**: e' solo un percorso per un
  checkpoint HYBRID deliberato, quando i gate H40/Android sono
  verdi e la PR #977 sia stata integrata su main. Dopo la release,
  confermare effettivamente asset e checksum delle quattro
  piattaforme e test OTA tramite menu Impostazioni -> Aggiornamenti.
- **H43 — nessuna regressione della modalita CLOUD ordinaria:**
  `AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA=true` deve attivare
  il consenso **solo sulle richieste HYBRID**, senza limitare i
  provider esistenti (NVIDIA, Mistral, Claude, custom) nella modalita
  CLOUD scelta esplicitamente. Il wrapper
  `DirectiveAwareInferenceService` separa `runtimeDefault` e
  `cloudOnly` in base al modo reale al momento della richiesta:
  CLOUD usa il runtime originale con provider e funzionalita
  preesistenti; HYBRID usa soltanto il runtime OpenAI/Gemini
  verificato e non passa mai ad un provider Cloud non approvato.
  I percorsi LOCAL rimangono invariati. Il decoratore Web e la
  gestione visiva della Chat in CLOUD ripristinano il comportamento
  originario, mentre HYBRID conserva controllo Web e provenienza
  della richiesta prima di qualsiasi uscita.
  Aggiunto test di regressione con modalita CLOUD e NVIDIA attivi,
  switch a HYBRID protetto e rifiuto di una destinazione non
  approvata; la suite condivisa ora esegue anche il test del
  componente barra audio integrato da `main` e il routing
  `DirectiveAwareInferenceService` su Ubuntu/macOS.
  Gate release: H43 CI multipiattaforma PASS, merge su main,
  firma Android e publish beta esclusivamente autorizzato.
  Test manuali con provider reali e aggiornamenti in-app restano
  necessari, nessuna release prodotta da questo commit.
- **H45 — merge periodico dei rami sperimentali, test ad hoc obbligatori**
  (direttiva owner 6 novembre 2026): non trattenere il codice
  sperimentale fino al prodotto completo. A milestone funzionanti
  integrare periodicamente su `main` per verificare il comportamento
  reale e far emergere difetti cross-feature, preservando un flag OFF
  nelle versioni ordinarie e la separazione della release beta.
  Prima di ogni merge ricostruire le differenze con `main`,
  riconciliare manualmente i conflitti senza perdere progressi
  concorrenti, e aggiungere regressioni mirate per i percorsi
  che si incrociano. Il merge non equivale automaticamente a
  pubblicazione, installazione o autorizzazione a inviare memoria.
  Dopo il merge rifare le CI sullo SHA **di main** prima del
  checkpoint beta; proseguire i filoni incompleti in nuovi branch.

  Per questo checkpoint: unire i nuovi controlli ME-2 sui
  referenti nominati con la provenienza confermata HYBRID,
  senza divulgare informazioni su Jerome/Kader in risposte
  relative all'altra persona o in una domanda autobiografica.
  Conservare il nuovo ponte del checkpoint owner: attesa della
  release Android completata con successo prima del publisher
  Windows, oltre all'attivazione HYBRID esplicita solo per beta.
  Test ad hoc `assistant_hybrid_merge_identity_regression_test.dart`
  piu test Python di handoff beta e test Flutter esistenti
  (consensi, local fallback, CLOUD legacy, audio, UI, Markdown).
  Nessun trasferimento di dati personali Cloud implicito.
- **H47 — ripristino rete tra due domande HYBRID, test ad hoc:**
  dopo una richiesta Cloud consentita che perde il trasporto, la
  domanda corrente puo' finire in LOCAL senza ripetere HTTP Cloud.
  L'assenza di rete rende il provider temporaneamente non
  selezionabile; il ritorno della connessione NON avvia nessun
  POST, nessun nuovo provider e nessun resume silenzioso. Soltanto
  una **nuova domanda** puo' selezionare di nuovo lo stesso Cloud
  trascorso il cooldown, e deve sottostare di nuovo alla review
  `allowOnce`, a identita' account, credenziali e provenienza Chat.
  Un orologio iniettabile **esclusivamente per test** permette
  di avanzare deterministicamente il retry di 20 secondi senza
  sleep, tempi lunghi o richieste reali. La nuova regressione
  `hybrid_cloud_network_recovery_next_turn_test.dart` usa
  `MockClient` (primo POST fallisce, nessun POST durante
  cooldown, secondo POST su nuova domanda con consenso esplicito
  e senza ricordi LOCAL nel payload). Il codice di produzione
  usa `DateTime.now` come prima. Nessuna modifica a CLOUD
  ordinario, caching, profili di sicurezza o consensi.

  **Gate CI H47:** il vecchio controllo Android che abilitava
  l'esperimento soltanto nella PR #977 chiusa ora ammette
  le PR interne del medesimo repository con prefisso
  `feat/hybrid-`; PR da fork, branch estranei e push `main`
  mantengono il flag **false**, e nessun APK diagnostico viene
  pubblicato. La suite condivisa e il QA Android eseguono il
  nuovo test, mentre un test Python controlla il nuovo vincolo
  CI. Il ramo H47 rimane source-only fino al superamento dei
  workflow e al prossimo merge sperimentale periodico.

  **Fuori da H47:** ripresa dei checkpoint semantici multipasso,
  retry della medesima richiesta Cloud in volo e migrazione
  automatica LOCAL->Cloud del testo gia' generato: questi
  rimangono esplicitamente vietati/non implementati.
- **H48 — registro protetto di avanzamento HYBRID, prima pietra
  dei checkpoint durevoli (non ripresa semantica):**
  nuovo `HybridProgressCheckpointJournal` indipendente dal
  Cantiere, utilizzabile in seguito dall'orchestratore di un
  lavoro multi-step: ogni task ha ID opachi owner/session/task,
  numero totale e completato di fasi (max 1000), revisione
  monotona e ultimo esecutore LOCAL/CLOUD. Non salva testi di
  domande, risposte, immagini, cronologia, ricordi, credenziali,
  account o contenuti di prompt. Il backend e' il medesimo
  storage OS-protetto dei consensi; il record e' firmato con
  HMAC SHA-256 su chiave casuale generata nello storage
  protetto, con validazione rigorosa dello schema e legame
  esatto a owner/session/task. Una corruzione, cancellazione
  parziale o modifica del record fa fallire il caricamento
  chiuso, senza recupero automatico di materiale Cloud.

  Il registro salva soltanto stati `paused` e `completed`,
  mai `running`, quindi riaprire l'app dopo un riavvio
  NON avvia una chiamata Cloud/LOCAL. Avanzare di una sola
  fase richiede l'ID corretto, l'autorizzazione owner/session,
  una revisione attesa e una fase precedentemente completata
  dal chiamante. Invii Cloud e autorizzazioni privacy
  restano esclusivamente responsabilita' del consent gate
  esistente; un record non e' un consenso riutilizzabile.
  Le mutazioni sono serializzate entro un singolo isolate
  Dart e protette da revisione; non si promette coordinamento
  fra processi diversi.

  Test H48 ad hoc: reopen dopo restart, passaggio
  LOCAL→CLOUD→LOCAL, nessuna ripresa automatica, owner
  diverso bloccato, HMAC alterato, chiave mancante,
  chiamate concorrenti/doppie, record gia' completo,
  credenziali non persistite e storage OS non disponibile.
  Le suite shared Ubuntu/macOS e QA Android/Windows/Linux/macOS
  eseguono questi test. Nessuna release da questa PR,
  flag HYBRID ancora OFF default.

  **Limiti dichiarati:** questo e' un registro di avanzamento
  e non conserva il contesto semantico sufficiente a riprendere
  attivita' interrotte da 10 checkpoint. L'integrazione
  nel planner/esecutore, le dipendenze fra fasi, la ripresa
  del contenuto in LOCAL e l'eventuale passaggio futuro a
  CLOUD con consenso granulare richiedono milestone separate.
- **Limite attuale:** gateway UI e provenienza Hannibal sono presenti;
  ricordi confermati funzionano nel ramo HYBRID-LOCAL del codice sperimentale
  ma il runtime Cloud produttivo resta quello preesistente, senza dispatcher
  gated nel bootstrap e senza consenso in Chat attivo. Mancano destinatario
  Cloud/account verificato per la review, prove E2E con HTTP reale e test
  fisici S24 FE. I permessi non autorizzano replica o invio automatico della
  memoria.
- I dati utente/documenti/ricordi e cronologia con sensibilità non verificata
  restano `unknown`: sono autorizzabili soltanto per una richiesta, non con
  permesso permanente; contenuti con false direttive `[SYSTEM]` rimangono
  dati della fonte. Servono classificazione affidabile, provenienza dei
  risultati Web/tool, allegati binari e trasporti oltre OpenAI/Gemini.
  **Il percorso H14 funziona nei test con HTTP simulato, non nella Chat
  produttiva:** UI review e sorgenti typed sono ora disponibili in Chat,
  ma bisogna ancora propagare l'evidenza trusted lungo Hannibal/Hybrid
  senza aggiunte da Web/tool, agganciare il coordinator al bootstrap
  con un destinatario Cloud effettivamente verificato e completare
  l'E2E sul Galaxy S24 FE.
- PR #975 è il checkpoint sperimentale separato. #899 governa la memoria,
  #973 HYBRID, #948 OTA. Non dichiarare prodotto completo né pubblicare
  release sulla sola base di test source-only.
- Massimizzare completezza e accuratezza con verifica e fonti senza promettere
  risposte **esaustive al 100%**, impossibili da garantire.

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

## 17. Progetto unico MEMORIA EVOLUTIVA AIVEXUS — visione, stato e piano operativo (4 novembre 2026)

Questa sezione e la **specifica operativa complessiva** della memoria evolutiva. Integra,
senza sostituire o duplicare, le sezioni 10, 14 e 16: la roadmap resta questo unico
documento. Quando un gate piu vecchio descrive una baseline precedente alla beta
Android 103717, prevale lo stato fisico datato qui sotto, non un PASS retroattivo.

**Obiettivo di prodotto:** Aivexus apprende le informazioni utili dal dialogo naturale,
ricorda fatti, preferenze, decisioni ed esperienze verificabili, corregge errori,
recupera soltanto cio che serve e rende tale patrimonio disponibile ai modelli e ai
dispositivi autorizzati. Non richiede formule artificiali come «Ricorda che» per
ogni informazione e non confonde una risposta plausibile con una conoscenza certa.

### 17.1 — Comportamento finale atteso

Esempi di conversazione normale, con dati sintetici:

- «Mi chiamo Paolo», «I'm John», «Je m'appelle Annabelle», «Soy Ana»:
  riconoscere una **presentazione diretta** nelle lingue IT/EN/FR/ES.
- «La mia auto e blu»: individuare un fatto autobiografico candidato,
  distinto da «l'auto di Anna e blu» e da una citazione/roleplay.
- «Preferisco Intel» oppure «Parlami normalmente in italiano»: riconoscere
  preferenze durevoli solo quando espresse come tali, con perimetro e
  provenienza.
- «Ho cambiato auto: ora e rossa»: **non sovrascrivere** il colore
  del veicolo precedente, perche la nuova auto potrebbe essere distinta.
  Soltanto «Ho riverniciato la mia auto: ora e rossa» identifica
  esplicitamente una modifica al medesimo oggetto (sempre con review).
- «Quella soluzione non funzionava; questa e stata verificata»: conservare
  esito, condizioni e prove per riutilizzare una procedura, NON promuovere
  automaticamente il testo del modello a verita verificata.
- «Dimentica il colore della mia auto»: eliminare solo quel dato;
  «Dimentica tutto sulla mia auto»: chiedere conferma e applicare la
  cancellazione limitata al soggetto e allo scope autorizzati.

Esempio end-to-end: dopo aver comunicato un nome in una chat LOCAL,
aprire una nuova chat con un altro modello e ricevere il nome corretto;
dopo una correzione recuperare solo la versione attuale; dopo una
dimenticanza non recuperare ne inventare un sostituto. Una copia
sincronizzata deve rispettare gli stessi aggiornamenti e le stesse revoche.

**Non equivale a riaddestramento automatico dei pesi LLM:** apprendimento
operativo significa principalmente memoria esterna selettiva, RAG,
provenienza, esperienza e retrieval affidabile. Fine-tuning rimane una
eventualita separata, solo dopo dataset, licenze, test e autorizzazioni.

### 17.2 — Un'unica architettura, modello indipendente

Percorso canonico:

1. **Ingresso affidabile:** distinguere messaggio scritto direttamente
   dall'utente da output modello, documenti, Web, citazioni e tool; i dati
   esterni non impartiscono istruzioni al motore memoria.
2. **Comprensione e filtro:** estrarre candidati con soggetto, attributo,
   valore, lingua, tempo, fonte, livello di sensibilita, attendibilita e
   identificazione del proprietario. Non schedare indiscriminatamente
   ogni frase; rispettare opt-in, preferenze e budget CPU/RAM.
3. **Politica di acquisizione:** separare fatto dichiarato dall'utente,
   candidata da rivedere, inferenza del modello, conoscenza verificata e
   esperienza procedurale. Acquisizione diretta consentita solo nelle
   categorie a basso rischio scelte dall'utente; dubbio/sensibile -> review.
4. **Archivio locale autorevole:** SQLite e indici RAG/semantici bounded,
   scopes USER / CONVERSAZIONE / PROGETTO, ownership e provenienza.
   Il modello non possiede il database e non puo auto-promuovere i
   candidati. Provenienza e storico delle revisioni devono essere leggibili.
5. **Recupero:** selezionare memorie confermate pertinenti per domanda,
   modello, scope e consenso; non riversare tutte le chat nel prompt;
   distinguere assenza di ricordo, ricordo cancellato, incertezza e
   contraddizione; mantenere latenza/RAM adatte a S24 FE.
6. **Ciclo di vita:** visualizzare, correggere, confermare, esportare,
   aggiornare, dimenticare un fatto, dimenticare un argomento e revocare
   l'eventuale condivisione. Tombstone/ID revisionati impediscono la
   resurrezione di dati eliminati durante sincronizzazioni o recovery.
7. **Condivisione opzionale:** medesimo contratto per Qwen, Phi,
   Nemotron e altri modelli, indipendente dal provider. Le copie su
   dispositivi diversi richiedono pairing, cifratura, ownership,
   merge policy, revoca e prova E2E.

**Tipologie di patrimonio:**

| Tipo | Significato | Fonte e autorizzazione |
| --- | --- | --- |
| Personale | Identita dichiarata, fatti, preferenze, abitudini | Utente, con acquisizione controllata |
| Episodico | Eventi, decisioni, contesto e risultati di un lavoro | Chat/task, scope e provenienza |
| Semantico/RAG | Documenti, progetti, conoscenza e riferimenti | Fonti originali, citazioni, validazione |
| Procedurale | Errori, fix, test ed esperienza riutilizzabile | Evidenza verificata, mai sola risposta modello |

Non replicare conversazioni originali per default: fatti deduplicati, sintesi
controllate e riferimenti alle fonti devono coesistere senza diventare
duplicati incontrollabili. La cronologia della chat, la memoria durevole
dell'utente e l'indice RAG sono **tre insiemi distinti**.

### 17.3 — Stato verificato e lacune, baseline S24 FE

**Codice e CI:** servizio capture per comandi espliciti, store SQLite
duraturo, contesto confirmed-only, code path condiviso fra modelli,
gestione selettiva dell'eliminazione in PR
[#983](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/983)
(merged). La risposta ai comandi di salvataggio/dimenticanza e
generata dall'app solo dopo l'operazione locale, non inventata dal LLM.
La pipeline di acquisizione naturale e ancora **non collegata al chat flow
in modo generale**: il flusso candidato-preferenza gia esistente e
conservativo, opt-in e limitato a poche formule, non ai nomi personali.

**Evidenza fisica del 4 novembre, Android beta 1.0.15-beta+103717:**

| Prova | Evidenza riferita dal tester | Valutazione |
| --- | --- | --- |
| Due ricordi in LOCAL Qwen | Colore prova Aivexus=viola, data=domani; due conferme applicative | PASS |
| Recupero in nuova chat Qwen | Entrambi i fatti restituiti | PASS |
| Forget selettivo Qwen | Eliminazione colore confermata; nuova chat non ripete viola, conserva «domani» | PASS comportamentale |
| Cambio Qwen -> Nemotron | Nemotron recupera «domani», non il viola cancellato | PASS parziale cross-model |
| Fedelta dopo forget | Qwen dice «non e colorata», Nemotron inventa «rossa» | DIFETTO qualita, non prova che il colore sia ancora memorizzato |
| Riferimenti temporali | Qwen inventa data assoluta incompatibile con «domani» | DIFETTO di ancoraggio/qualita |
| Phi-3.5 Mini, frasi naturali | «Mi chiamo Paolo», «La mia auto e blu» non richiamate dopo la chat | GAP acquisizione naturale |
| Phi-3.5 Mini, comando | «Ricorda che la mia auto e blu» confermato; richiamo in altra chat riferito corretto | PASS esplicito |
| Chat origine eliminata DOPO save esplicito | Test STELLA73 non ancora eseguito fisicamente | DA PROVARE |
| Android -> Windows/Mac | Nessuna sincronizzazione dimostrata | NON ATTIVO |

Interpretazione prudente: la prima cancellazione di chat Phi avveniva
**prima** di un salvataggio esplicito; non prova che l'eliminazione della
chat cancelli la memoria confermata. Lo stato di «nel cestino» e distinto
da eliminazione definitiva. I test Qwen/Nemotron non dimostrano un audit
diretto dei record SQLite, ma sono evidenze fisiche utili.

Le anomalie di lingua, risposte inventate e date sono consegnate al
filone qualita [#973](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/973),
gestito da Work: **evitare PR concorrenti sugli stessi file di qualita**.

### 17.3 bis — Aggiornamento operativo del 5 novembre 2026 (codice vs test fisici)

Il piano e gli obiettivi di 17.1–17.6 restano invariati. Questo registro
aggiorna le **evidenze di implementazione**, senza attribuire un PASS fisico
alle modifiche che sono state controllate soltanto con GitHub Actions.

| Tranche | Esito verificato nel repository | Stato reale / gate residuo |
| --- | --- | --- |
| ME-0 — persistenza e scope | [PR #993](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/993), integrazione test file-backed; [#994](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/994), eliminazione selettiva della chat nel cestino; [#995](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/995), barriere in-process contro scritture tardive. Tutte integrate con CI verde. | Mancano collaudo S24 (incluso STELLA73), protezioni persistenti ME-2 e verifica su ripristini/restart reali. Il pulsante di purge definitivo non e ancora esposto nella UI. |
| ME-1 — presentazioni naturali | [#996](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/996), parser diretto IT/EN/FR/ES con review; [#998](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/998), opt-in locale persistente inizialmente OFF, revocabile e connesso alla chat ordinaria senza allegati. Integrate con CI verde. | Il riconoscimento crea soltanto candidati; conferma/correzione/rifiuto avvengono nella pagina Memoria. Non e ancora estrazione libera di conversazioni lunghe, e l'opt-in del dispositivo non e pairing multipiattaforma. |
| ME-1 — primo fatto autobiografico oltre il nome | [#999](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/999), «La mia auto e blu» e equivalenti EN/FR/ES, parser conservativo, conferma umana e retrieval locale mirato. Integrata con CI verde. | Rimane da misurare falsi positivi, variazioni linguistiche, contraddizioni e qualità reale delle risposte con Qwen/Phi/Nemotron. |
| ME-0 + ME-1 — regressione integrata | [PR #1000](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1000) integrata con CI verde: candidati invisibili prima della review, conferma, purge chat origine, riavvio SQLite, recupero nelle 4 lingue e forget selettivo. | Il test automatico non sostituisce STELLA73, offline e il collaudo fisico dell'aggiornamento su Galaxy S24 FE. |

**Separazioni obbligatorie:** la chat eliminata, i record USER e i vettori
semantici sono dati distinti; i candidati non sono fatti confermati.
LOCAL non richiede provider esterni/Cloud; nei modi HYBRID/Cloud non
aggiungere ricordi personali al prompt senza gli appositi consensi
([#977](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/977)).
Un test CI non e un test fisico, una build compilata non e una release
installata, e il nuovo parser non corregge automaticamente le risposte
allucinate dei modelli (filone [#973](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/973)).

### 17.3 ter — ME-2: identita, riferimenti e incertezza (5 novembre 2026)

Il requisito chiave e **non confondere un attributo con una identita**.
La vecchia chiave singola `natural.user.car_color` e una scorciatoia
limitata a un veicolo gia accettato e riconosciuto; non e un ID veicolo.
La [PR #1003](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1003)
ha introdotto correzioni revisionate e protette dalla versione, ma il
test «Ho cambiato auto: ora e rossa» dimostra l'ambiguita di oggetto:
sostituzione, riverniciatura e seconda auto **non sono equivalenti**.

**Prima fondazione operativa di entity resolution (questa tranche):**

- Distinguere riferimento nominato, menzione anonima e identita verificata;
  `person:name:nora` e un'etichetta provvisoria, non un identificatore
  univoco. Due persone possono avere lo stesso nome. Non deduplicare
  persone per altezza, corporatura, sport, giudizi o successione delle chat.
- Esempio di accettazione con sette frasi: «Il mio collega e un idiota»,
  «Ho un collega alto», «Un collega si chiama Nora»,
  «Nora e sovrappeso», «Lino fa tanto sport»,
  «Teo e un mio collega», «Non mi piace il mio collega».
  Collegamenti espliciti solo per il riferimento scritto «Nora»;
  Lino **non** diventa automaticamente collega e il collega alto non
  diventa automaticamente Teo. Opinioni negative restano attribuite
  **all'utente**, non diventano fatti oggettivi su un terzo.
- «La mia bicicletta e veloce» registra al massimo la valutazione
  dichiarata di una bici **non identificata**: nessuna deduzione su eta,
  acquisto, riparazioni o prestazioni misurate.
- Un parser deterministico, locale e **transitorio** copre questi
  esempi: restituisce riferimenti con attribuzione e incertezza ma non
  salva profili terzi, non alimenta il prompt e non invia dati Cloud.
  Questo e un *componente preparatorio testato*, non ancora la memoria
  relazionale operativa della chat.

**Gate successivi indispensabili per un grafo durevole:**

1. Entita con identificatore persistente opaco, proprietario, versione,
   relazioni ed eventi; riferimenti ambigui separati e dedup solo se
   supportata da evidenza esplicita o revisione del proprietario.
2. Politica di privacy distinta per dati di terzi, attributi sensibili
   e giudizi soggettivi: nessuna profilazione automatica della rete
   sociale, opt-in puntuale/review/revoca e controllo scope.
3. UI di chiarimento soltanto quando serve a una risposta o a una
   modifica; audit di provenienza e controllo di correzioni e forget.
4. Collisione omonimi, pronomi, acquisto di secondo oggetto, trasferimenti
   di proprieta, ambiguita temporali, riavvio SQLite e dispositivo
   multipiattaforma, con test avversari e collaudo S24.

**Correzione del gate esistente:** il parser ME-2 del colore deve
accettare per l'aggiornamento dell'unico veicolo soltanto espressioni
esplicite di riverniciatura della stessa auto in IT/EN/FR/ES. «Ho cambiato
auto: ora e rossa», «My car is now red» e «Ho comprato una seconda auto
rossa» non devono sovrascrivere la vecchia auto. L'affermazione puo
essere compresa come evento ancora da disambiguare, non promossa a
ricordo confermato.

### 17.3 quater — Checkpoint 8 novembre 2026: memoria corretta, LOCAL AUTO e release gate

**Questa voce aggiorna lo stato del 5 novembre senza modificare i criteri di accettazione 17.4–17.5.** I test automatici e l'integrazione in main NON equivalgono a collaudo fisico o beta distribuita.

- **ME-0/ME-2, vista canonica:** [PR #1079](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1079) MERGED. Risolve la vista dei fatti confermati dopo correzioni esplicite: restituisce ai diversi modelli LOCAL il fatto attuale, conserva lo storico SQLite, richiede nome esplicito per memorie di terzi ed evita di promuovere candidati non confermati.
- **ME-2, correzione naturale con review:** [PR #1080](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1080) MERGED. La frase limitata «Non Jerome, Kader è alto» produce soltanto una proposta; conferma/rifiuto nella pagina Revisione memoria, snapshot stale protetto; niente auto-profilazione o auto-approvazione.
- **ME-2, isolamento:** [PR #1083](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1083) MERGED. L'oscuramento dei vecchi fatti è qualificato per scope, scopeId e recordKey, senza contaminare conversazioni diverse.
- **ME-2, forget concatenato:** [PR #1085](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1085) MERGED su main l'8 novembre (squash `6de0ba37bdd8aa61f87cb0672045853271f07ebc`). Dimenticare l'ultima correzione segue e rimuove atomicamente la catena univoca esatta nel medesimo ambito; se il predecessore è ambiguo abortisce senza scrivere, e i fatti indipendenti restano. Test mirati nel workflow LOCAL Affinity Unit Tests (SQLite di sistema, **non release**) PASS su Ubuntu/macOS/Windows. Difetto tracciato in [#1084](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/1084); QA fisica ancora da effettuare.
- **LOCAL AUTO, affinità:** [PR #1074](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1074) espone l'identificativo del modello realmente usato nei log Diagnostics; [PR #1075](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/1075) MERGED, con affinità per conversazione, isteresi e cooldown dopo completamento. Non dichiarare ancora switch impercettibile senza TTFT/RAM/benchmark su dispositivi reali.
- **Prossimo incremento LOCAL AUTO:** [issue #1086](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/1086): un solo fallback GGUF LOCAL compatibile **prima del primo token**, mai con LOW_MEMORY/cancel, mai per MANUALE/Workshop/HYBRID, nessun Cloud, duplicato di risposta o alterazione di memoria e permessi. La pressione RAM rilevata su Galaxy S24 FE impone unload/limiti prima di tentare il secondo LLM.
- **Gate di distribuzione P0:** [issue #1076](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/1076): mismatch SHA-256 per asset nativi SQLite in CI; non disabilitare checksum e non usare SQLite di sistema come sostituto per release. Una beta installabile richiede verifiche di packaging, firma, updater interno e collaudo fisico; Android solo **Impostazioni → Aggiornamenti**, senza APK manuali, reinstallazione o reset.
- **Lacune ME-1/ME-4/ME-6:** riconoscimento e acquisizione automatica configurabile di preferenze innocue senza approvare ogni ricordo, entity ID persistenti senza inferenze su omonimi, forget/tombstone sincronizzati, pairing cifrato S24–ASUS, test cross-model IT/EN/FR/ES e connettività/offline ancora da completare o dimostrare. Consenso Cloud separato dalla memoria LOCAL, come in 17.5. Non dichiarare sincronizzazione effettiva fra dispositivi.

**Ordine operativo conservato:** consolidare cancellazione/consistenza ME-0/ME-2 e QA; proseguire LOCAL AUTO P0 #1086 in parallelo alla risoluzione indipendente del blocco release #1076; poi benchmark qualità/costi di switch e acquisizione naturale configurabile. Il Cantiere mantiene la priorità generale della prima app autonoma funzionante: questi lavori sulla memoria non costituiscono una roadmap concorrente.

### 17.3 quinquies — Collaudo fisico ME-2 su Galaxy S24 FE (8–9 novembre 2026)

Questo checkpoint registra **risposte realmente osservate** in modalità
LOCAL sulle versioni `1.0.15-beta+103962` (Test 1–3) e
`v1.0.15.104156` (Test 4); resta distinto dal codice più recente
elencato in §17.3 quater, che non è automaticamente presente sul dispositivo.
Fonti: [issue #899](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/899),
[report Test 2](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/899#issuecomment-6717759716)
e [report Test 3](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/899#issuecomment-6717939273).

| Test | Prova reale | Esito e limite |
| --- | --- | --- |
| 1 — candidato naturale | Messaggio `Jerome è alto.` produce una proposta di memoria locale, con review | **PASS**, non ancora ricordo confirmed prima dell'approvazione |
| 2 — recupero cross-chat | Candidato approvato, nuova conversazione: `Che cosa sai di Jerome?` → `Sai che Jerome è alto.` | **PASS** per ricordo confermato in una nuova chat LOCAL |
| 3 — isolamento persone | Nuova chat: `Che cosa sai di Kader?` → `Mi dispiace, non ho informazioni specifiche su Kader. Potresti fornire più dettagli?` | **PASS**: nessuna falsa attribuzione dell'altezza di Jerome a Kader nel caso provato |
| 4 — chat rimossa e memoria dopo arresto app | Nuovo fatto sintetico `Marco è alto.` approvato; chat origine cancellata dall'utente; Forza arresto; nuova chat LOCAL Qwen2.5 3B, domanda `Che cosa sai di Marco?` → `Marco è alto.` | **PASS fisico comportamentale** sulla versione mostrata `v1.0.15.104156`; non prova purge definitivo del cestino né ispezione SQLite |

**Nota su build e ambito:** Test 1–3 verificati sulla beta 103962; Test 4, con nuova persona sintetica e chat origine rimossa, sulla versione installata `v1.0.15.104156` (canale beta da schermata aggiornamenti). Il dato è stato riportato dall'utente e accompagnato da screenshot; il test di cancellazione definitiva tramite `Svuota cestino` resta aperto. Report in [issue #899](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/899).

**Anomalia separata:** nel Test 1 la risposta del LLM era in inglese a
una frase italiana; i Test 2–3 hanno risposto in italiano. Non confondere
difetti di lingua e successo del retrieval.

**Requisito successivo, NON implementato nella beta:** scelta di acquisizione
LOCAL `non ricordare` / `chiedi sempre` / `approvazione automatica per
categorie ordinarie autorizzate`, con categorie separabili per preferenze
e persone nominate, deduplicazione, provenienza, possibilità di revoca,
review per ambiguità, contraddizioni e dati sensibili. Il consenso alla
memorizzazione locale non autorizza in alcun modo l'invio dei ricordi a
provider CLOUD/HYBRID; resta il gate di divulgazione distinto già previsto.

**Altri gate aperti:** modifica/correzione/forget con evidenza fisica,
cambio di modello Qwen/Phi/Nemotron, eliminazione definitiva dal cestino,
riferimenti omonimi, offline e condivisione cifrata fra dispositivi.
I quattro PASS non dimostrano un grafo identitario generale o sincronizzazione.

### 17.4 — Piano per milestone con gate di accettazione

| Milestone | Priorita | Deliverable e gate verificabile |
| --- | --- | --- |
| **ME-0: affidabilita** | P0 immediato | Salvataggio, recupero, update/forget, nuovo modello, riavvio, offline e chat cestinata/eliminata; record e chat scopes separati; CI + S24 |
| **ME-1: dialogo naturale** | P1 prodotto | IT/EN/FR/ES per presentazioni, fatti autobiografici e preferenze bounded; non servono formule; citazioni/roleplay negati, approvazione/correzione e provenance |
| **ME-2: ciclo di vita evolutivo** | P1 | Riconoscere correzioni, contraddizioni, date relative ancorate, conflitti, versioni e tombstone; nessuna resurrezione o auto-certificazione |
| **ME-3: RAG ed esperienze** | P2 | Retrieval locale multilingue con fonte, deduplica e limiti RAM/token; errori/soluzioni diventano procedure solo dopo evidenza e test |
| **ME-4: dispositivi e profili** | P2 sequenziale | Export/import cifrato e pairing S24 <-> ASUS, poi Mac/Linux; offline/reconnect, revoche e zero contaminazione fra owner |
| **ME-5: integrazione modalita** | P2 in parallelo | LOCAL senza provider Cloud; HYBRID/Cloud con consenso per contenuti personali, fonte, provider e revoca, continuita di lavoro |
| **ME-6: qualita/autonomia continua** | trasversale | Riduzione misurata di falsi ricordi, date sbagliate, latenza, duplicati e regressioni; QA fisico e automatico |

**ME-0 — operazioni immediate:**
1. Unit/integration test file-backed SQLite con due scopes:
   salvataggio USER nella chat A e memoria CONVERSAZIONE nella chat A;
   spostare A nel cestino e verificare che il ricordo USER sia leggibile
   dalla chat B, quello scoped A no; dopo reset/riapertura ripetere.
2. Provare rimozione di A dalla cronologia con il percorso reale
   dell'app e distinguere tombstone cestino da eliminazione definitiva.
   Definire e testare l'effetto previsto sulle memorie CONVERSAZIONE:
   la distruzione definitiva dei riferimenti privati non deve lasciare
   indici RAG orfani, senza eliminare automaticamente ricordi USER
   confermati e separati dalla chat.
3. Test fisico con record sintetico «STELLA73»:
   nuova chat -> «Ricorda che il codice della prova chat eliminata e STELLA73»
   -> conferma dell'app -> eliminare quella chat -> nuova chat ->
   interrogare codice. Ripetere dopo riavvio, senza reset dell'app.
4. Ripetere Qwen -> Nemotron -> Phi, logout/riavvio quando supportati,
   test con rete assente; mantenere registrazione degli esiti effettivi.

**ME-1 — prima tranche implementabile, senza cattura indiscriminata:**
- Definire un solo estrattore di *messaggi utente diretti*, con parser
  multilingue conservativo e/o classificatore locale bounded;
  supportare prima nome dichiarato e poche categorie stabili. Vietare
  output modello, citazioni, ipotesi, scherzi/roleplay, segreti,
  informazioni di terzi o importazioni come auto-verita.
- Riutilizzare store **candidate** e review esistenti: staged candidato
  con key logica stabile, lingua, fonte e proprietario; consentire
  approvazione, edit, rifiuto e disattivazione. Solo confermati nel
  retrieval ordinario. Consentire preferenze esplicite di auto-acquisizione
  per classi non sensibili; senza opt-in la normale chat non registra
  automaticamente ricordi confermati.
- Il test di accettazione usa identita **fittizie** in chat A, recupero
  da chat B/altro modello SOLO dopo conferma/consenso; una citazione
  «Paolo ha detto: mi chiamo John» non deve diventare nome dell'utente.
  IT/EN/FR/ES con variazioni e negazioni. Verificare scritture concorrenti,
  auto-revisioni e no cloud I/O.

**ME-2 — correzione e tempo:**
- Mantenere identificatori soggetto/attributo indipendenti dal testo
  superficiale per poter correggere «la mia auto» e «my car» senza
  lasciare due verita contraddittorie. Allineare scope/user e owner.
- Registrare per date relative l'istante di affermazione e il fuso
  locale: «domani» non va convertito a una data assoluta inventata.
  Esporre la frase originale e distinguere evento pianificato da
  promemoria scaduto.
- Dimenticanza atomica mirata, broad delete con conferma, refresh
  di retrieval/index, policy backup/sync e prova che chat vecchie o
  device offline non facciano ricomparire i ricordi cancellati.

**ME-3 — RAG ed esperienze:**
- Consolidare LocalDocumentIndexService, ChatFileContextService e
  CANT-RAG-1 della Libreria; provenienza recuperabile, citazioni,
  filtri owner, prompt-injection defense e bassa pressione RAM.
- Separare memoria di fatti, retrieval dei documenti e knowledge
  procedurale; trasferire a Libreria soltanto componenti con sorgente,
  licenza, hash, test e prova di integrazione. Un fix riconosciuto
  come «riuscito» va comunque validato in contesto.

**ME-4 — sincronizzazione incrementale:**
- Prima due DB sintetici e schema/export/import versionati, poi
  S24 <-> ASUS (bidirezionale), poi Mac/Linux. Pairing autenticato
  (#915), cifratura, conflitti e revoca; CRDT e MemoryFabric
  eventualmente riusati dopo verifica, non dichiarati gia attivi.
- Offline sempre possibile, nessun deposito non autorizzato su repo
  pubblico/Diagnostics; NAS/storage remoto opzionale, non prerequisito;
  tombstone e cancel propagati agli altri dispositivi abbinati.
- Multiutente reale **solo dopo** isolamento completo simulato con
  profili fittizi, inclusi cache, RAG, log e backup (#913/#914).

**ME-5 — LOCAL/HYBRID/CLOUD:**
- **LOCAL = senza provider esterni/Cloud**; accesso Web separato e
  regolato dalle proprie impostazioni, non automaticamente vietato
  dalla parola LOCAL. La memoria base funziona anche in modalita aereo.
- In HYBRID la fase LOCAL usa il proprio ricordo confermato pertinente;
  prima di inviare chat, dati personali, memoria, documenti o tool output
  al Cloud occorre una scelta consapevole, granulare per provider,
  categoria e durata; scelta negativa -> continuare senza condividere.
- «Uso provider Cloud» e «sincronizzo archivio privato» sono consensi
  distinti. Sottomenu Impostazioni -> Modalita IA -> Consensi Cloud
  consente consultazione, modifica e revoca delle decisioni.
  Lavori autonomi gia in [PR #977](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/977)
  e [#975](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/pull/975):
  non duplicare controller, policy o interfacce, e non considerarli
  attivi finche non integrati/testati.

**ME-6 — QA e miglioramento continuo:**
- Dataset sintetici per test di recall corretto/non-recall, falsi
  positivi, omissioni, negazioni, dialoghi lunghi, lingua, date,
  correzioni, segreti e cancellazioni; metriche separano retrieval
  dalla risposta del modello. Un modello che inventa «rossa» dopo
  aver dimenticato «viola» e un difetto di fedelta, non prova che il
  record cancellato sia tornato.
- Misurare S24 FE: RAM, batteria, latenza chat/TTFT, occupazione
  SQLite e finestra token. Candidatura e indexing fuori dal path
  critico quando possibile, limiti deterministici e nessun loop di
  inference superfluo. Work resta responsabile del filone qualita.

### 17.5 — Gate trasversali, privacy e collaudo

Ogni milestone e conclusa **solo** quando:
- cambiamento realmente integrato nel repository, test automatici
  relativi superati, nessun conflitto con PR parallele, nota di
  provenienza e regression suite;
- verifica su dispositivo/ambiente pertinente con transcript
  sintetico e risultato esatto; CI verde non sostituisce accettazione
  fisica, e una PR draft non equivale a funzione installata;
- la cancellazione specifica non svuota altri fatti, non cancella
  chat senza comando, non resuscita da prompt/cache/backup/sync;
- non introduce upload involontario, new data collection silenziosa
  o regressioni percettibili in performance/affidabilita;
- release Android autorizzata e aggiornabile **solo** da
  Impostazioni -> Aggiornamenti, senza sideload, reset o uninstall
  per collaudare.

**Policy dati:** fatti familiari/terzi, informazioni particolarmente
sensibili, segreti e contenuto documentale non devono essere raccolti
automaticamente come memoria personale per il solo fatto che appaiono
in chat; minimizzazione, revoca e visibilita del processo sono requisiti.
Il fatto che il modello possa usare temporaneamente il contesto NON
implica consenso alla persistenza o alla trasmissione esterna.

### 17.6 — Ownership e riferimenti; nessuna roadmap parallela

- **Issue [#899](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/899)**:
  epic acquisizione, memoria SQLite, forget e RAG locale; qui si
  registrano gli esiti di test S24 e gli incrementi ME-0/ME-1.
- **Issue [#911](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/911)**,
  PR #912/#914 e issue #915: archivio, isolamento owner, pairing
  e successiva sincronizzazione cross-device; non attivare
  trasferimenti o multiutente senza gates.
- **Issue [#973](https://github.com/pilialvu75-hue/Ai-orchestrator-riserva/issues/973)**:
  coordinamento con qualita risposte e Hybrid; PR #975/#977 in
  lavorazione separata. Condividere evidenze, non modificare in
  parallelo gli stessi file.
- **Libreria CANT-RAG-1**: piano del retrieval locale e validazione
  di componenti, senza doppiare il motore memoria dell'assistente.

**Prossima decisione operativa:** chiudere ME-0 con test riproducibili
e prova fisica chat eliminata -> ricordo USER persistente; poi
implementare il primo incremento ME-1 di acquisizione naturale
multilingue con provenance e review, senza attivare sync/Cloud o
confondere risposte inventate con ricordi attendibili.



## 18. Chat audio e stabilita dettatura — checkpoint fisico Galaxy S24 FE (7 novembre 2026)

Questa sezione aggiorna unicamente UX delle sezioni 14–15 e voce
della sezione 10, senza cambiare i contratti di Cantiere, memoria o HYBRID.
Fonti operative: issue #967 (audio/MediaSession), #1052 (crash dopo
dettatura), #1033 (Voice 2.0) e #947 (cestino).

### 18.1 — Risultati fisici e stato del sorgente: livelli diversi

- Galaxy S24 FE, Android 17, beta 1.0.15-beta+104018: Test 4
  Stop **PASS**, nuova lettura **PASS con latenza**,
  cambio rapido messaggio **FAIL**, ritorno da YouTube **FAIL UX**.
  Dopo YouTube un nuovo Play funziona ma ricomincia **dall'inizio**:
  non descrivere il difetto come blocco del tasto Play.
- Progressivo fisico #967, Test 1–4: **12 PASS, 2 FAIL, 2 NON PROVATI**
  (Bluetooth). Non estendere PASS a versioni e device non collaudati.
- PR #1034 **MERGED** su main, commit 59f98bc1 (7/11):
  preemption TTS PCM, switch rapido e recupero stato lettore dopo
  perdita focus. Il fix **non e nella beta 104018**.
- PR #1051 **in corso**, ramo ricostruito su main dopo squash #1034,
  head d6eb8507: bookmark volatile e ripresa dal punto salvato
  **solo con Play esplicito** quando e terminato il conflitto audio
  con YouTube. CI e QA obbligatorie; non attestare PASS fisici.
  Dopo AUDIOFOCUS_LOSS permanente chiudere FGS e MediaSession:
  niente riproduzione contemporanea a YouTube.
- PR #1053 **MERGED** su main, commit fbf6f652 (7/11):
  ferma il recorder STT a fine dettatura, attende stop anche per
  l'invio di risultati parziali, impedisce teardown dentro callback
  nativa Sherpa. CI Android ARM64, Flutter tests e desktop PASS;
  **crash su S24 ancora NON certificato risolto**.

### 18.2 — Crash e RAM: evidenze, limiti, priorita

- Segnalazione: dettatura → invio → stato «sta pensando» → app chiusa;
  al riavvio domanda presente ma risposta mancante.
- Diagnostics S24 FE del 7/11: cinque terminazioni Android
  ApplicationExitInfo.REASON_LOW_MEMORY **distinte per timestamp**.
  Diversi sample pressure=high, con 0,8–1,0 GiB RAM disponibili
  durante inferenza; i vecchi eventi ripubblicati dopo i riavvii
  non vanno ricontati come crash nuovi.
- **Non dimostrata** correlazione temporale tra quel crash dopo STT
  e uno specifico OOM: correlare allegati originali, timestamp,
  ASR_FINAL, INFERENCE_BEGIN, AndroidProcessExitInfo.
- Lo stop STT chiude recorder/subscription/OnlineStream;
  **non scarica il recognizer Sherpa** (il campo _recognizer resta
  residente fino a dispose). Non attribuire centinaia di MB
  recuperati a #1053 senza misurazione fisica.
- P0: profilare picco RAM/nativa/GPU con STT appena usato vs
  testo digitato; verificare pressione, modello Phi-3.5 Mini,
  memoria pre-inferenza, budget e recupero da processo terminato.
  Nessun invio implicito dei dati dell'utente al Cloud.

### 18.3 — Gate pratici della prossima beta

1. Distribuzione esclusivamente con **Impostazioni → Aggiornamenti**:
   niente APK manuali, disinstallazioni, reset o wipe.
2. Misurare tempo Play → primo suono, cambio rapido di messaggio,
   Stop/Replay senza PCM residuo o sovrapposizione.
3. YouTube prende focus → sessione AIVEXUS termina; ritorno e Play
   esplicito sullo **stesso messaggio** dal segnalibro, se presente;
   Stop manuale/fine naturale/testo differente non lo riutilizzano.
   Se il processo e stato terminato, bookmark volatile perso.
4. Tre ripetizioni dello **stesso testo digitato vs dettato** in
   LOCAL Phi-3.5 Mini; poi seconda dettatura e cambio chat.
   Annotare fine STT, inizio inferenza, esito, crash, RAM e temperatura
   senza memorizzare la trascrizione personale nei log.
5. In caso di interruzione, richiesta utente salvata e risposta
   mancante recuperabile con Riprova: **requisito da implementare
   e collaudare, non funzionalita oggi certificata**.
6. CI multipiattaforma + updater e prova fisica S24;
   non chiudere #967/#1052 in base alla sola CI.

### 18.4 — UX successiva senza dispersione

- Player compatto: Play/Pausa/Stop, seek/durata effettivi,
  controlli da notifica e lock screen; continuita durante cambio
  chat/app e schermo spento quando permesso da Android 17.
- Voce/Live: issue #1033; TTS offline-first multilingue IT/FR/EN/ES
  e prima emissione audio misurata. LOCAL/HYBRID/CLOUD restano
  indipendenti dal motore audio.
- Cestino #947: dopo P0, implementare Sposta/Ripristina, poi
  «Svuota cestino» con conferma, integrita SQLite e tutela
  memoria evolutiva. Archiviare non equivale a cestinare.
  Non distruggere dati del tester durante lo sviluppo.
- Rispettare sezione 15: non peggiorare apertura chat,
  primo token, fluidita, memoria o qualita delle risposte.

---

## 19. AIVEXUS Security Lab — protezione dell'autonomia e dei dati (8 novembre 2026)

### 19.1 — Scopo, collocazione e ordine delle priorita

Creare un **progetto di sicurezza indipendente**, con repository dedicato quando disponibile, sviluppabile in parallelo a basso impatto e in futuro integrabile per moduli in `Ai-orchestrator-riserva`. La ricerca su tentativi di comunicazione esterna da parte di agenti/modelli open-weight e uno spunto per creare test riproducibili, **non prova di una backdoor in Qwen o in qualsiasi modello installato**.

**Ordine vincolante:** prima inferenza LOCAL affidabile e stabilita (incluso S24 FE), poi Computer Use realmente autonomo; solo dopo integrazione progressiva dei controlli avanzati. La sperimentazione nel Security Lab non deve bloccare Cantiere, memoria evolutiva, HYBRID, voce o release periodiche. Il primo modulo autonomo utilizzabile resta priorita del Cantiere.

**Principio di prodotto:** la sicurezza protegge l'autonomia, non la sostituisce con un'interfaccia piena di divieti e conferme. Non introdurre Main/Reviewer obbligatori o approvazioni per ogni azione ordinaria.

### 19.2 — Confini e autorizzazioni, non divieto generalizzato

- `LOCAL` = inferenza senza provider IA esterni/Cloud; **non** equivale a modalita aereo. Rete e strumenti locali/remoti rimangono disponibili se autorizzati. `HYBRID` e `CLOUD` mantengono i consensi distinti (vedere #977 e sezione 16).
- Separare **pesi del modello**, runtime di inferenza, orchestratore, strumenti, browser/Computer Use, sistema operativo e provider Cloud: un modello senza strumenti abilitati non deve poter effettuare direttamente richieste HTTP, leggere file arbitrari o eseguire comandi. Le azioni passano attraverso broker di capacita verificabili.
- Introdurre policy granulari e persistenti per **proprietario/progetto/sessione/strumento/destinazione e tipo di dato**: ad esempio consultazione web, fetch di dipendenze, git push, API di progetto, trasferimento di file, memoria privata. Consenso revocabile, scadenza e minimo privilegio.
- **Nessuna richiesta continua di conferma**: attivita ordinarie previste dai permessi gia concessi procedono autonomamente (ricerca web, commit, build, debug, correzione, sync esplicitamente configurata). Chiedere autorizzazione solo per ampliamento reale dei privilegi, nuove destinazioni sensibili o trasmissione di segreti/dati privati non coperta.
- Mai permettere al modello di auto-concedersi permessi, ampliare una allowlist o disattivare le regole di esfiltrazione. Prompt, file recuperati, output web e log sono dati non attendibili, non istruzioni di sicurezza.
- Operazioni ad alto rischio (credenziali, chat/memoria privata, documenti personali, cancellazioni irreversibili, installazione/esecuzione arbitraria, condivisione cross-account) richiedono policy/consenso dedicato; rispettare isolamento owner (#913/#915), cifratura e revoche (#911).
- **Predefiniti proporzionati**: audit non intrusivo dove sufficiente; blocco deterministico per trasferimenti non autorizzati di dati protetti; non bloccare l'inferenza o la normale risposta per indisponibilita del componente di monitoraggio. Quando e necessaria una destinazione autorizzata ma temporaneamente irraggiungibile, usare retry/backoff e ripresa, non bloccare l'intero agente.

### 19.3 — Security Lab multipiattaforma (backlog successivo al Computer Use)

1. **Inventario superfici e mappa dei dati:** chat, memoria evolutiva, RAG, repository, tool call, file, credenziali, comunicazioni tra dispositivi; identificare quali flussi sono locali e quali possono attraversare la rete.
2. **Osservabilita prima dei blocchi:** log tecnici minimizzati di tentativi di connessione, destinazione, processo/strumento, permesso valutato e azione consentita/negata, senza registrare payload, prompt, token o segreti; integrazione Diagnostics con consenso e senza dati personali su repository pubblici.
3. **Broker strumenti + controllo uscita dati:** autorizzazioni persistenti e revocabili, dominio/endpoint quando applicabile, separazione network del runtime, redazione di segreti. Supportare l'esecuzione autonoma delle catene di strumenti gia approvate. Sandbox/OS firewall solo dove tecnicamente compatibile; non promettere isolamento equivalente su tutte le piattaforme.
4. **Test adversarial isolati:** modelli locali e Cloud in ambienti simulati con dati sintetici e endpoint controllati; prompt injection, tool-output injection, tentativi di esfiltrazione, escalation di permessi, condivisione impropria di memorie, cross-device, falsi positivi.
5. **Portabilita:** nucleo di policy condiviso su Android, Windows, macOS, Linux e Web, con adattatori specifici per le capacita del sistema operativo. Web ha limiti di sandbox/browser diversi; funzioni non disponibili vanno dichiarate, non simulate.
6. **Integrazione graduale:** prima audit-only e test CI; poi controlli deterministici sui dati protetti; infine opzioni avanzate configurabili. Nessuna attivazione silenziosa o modifica ai consensi Cloud esistenti.

### 19.4 — Gate: autonomia e prestazioni prima di tutto

- **Autonomia:** una richiesta autorizzata che usa ricerca, build, esecuzione, GitHub e self-repair deve completarsi senza prompt ripetuti; un tentativo di esfiltrazione sintetico verso destinazione non approvata deve essere fermato e spiegato.
- **Prestazioni:** confrontare baseline prima/dopo su tempo primo token, latenza strumenti, CPU, RAM, batteria, crash/LOW_MEMORY su S24 FE; nessuna regressione significativa non misurata e accettata. Il monitor deve essere leggero, disattivabile nelle parti facoltative, senza disattivare l'isolamento dei dati privati.
- **Fedelta modale:** LOCAL inferisce senza Cloud; HYBRID chiede consenso quando invia memoria privata; rifiutare non impedisce di lavorare senza invio; sincronizzazione autorizzata indipendente dal consenso per LLM Cloud.
- **Prove reali:** CI multipiattaforma + collaudi fisici mirati dopo ogni beta; PASS CI non equivale a sicurezza dimostrata su Windows/Android/macOS/Linux/Web.
- **Consegna:** roadmap e prototipi nel progetto indipendente; integrazione nel prodotto solo dopo misure, test di regressione e valutazione dell'impatto su Cantiere/Computer Use.

Riferimenti: sezioni 11, 15, 16, 17 e 18; issue #911, #913, #915. Progetto di sicurezza **pianificato, non ancora dichiarato implementato o collaudato**.
