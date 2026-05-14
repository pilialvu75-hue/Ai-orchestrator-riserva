# Roadmap evolutiva

Questo documento descrive la direzione di lungo periodo di AI-Orchestrator come piattaforma e chiarisce il rapporto tra **AI-Orchestrator-Core** e la traiettoria **MobileIDE**.

## 1. Visione di lungo periodo

AI-Orchestrator deve evolvere verso una piattaforma capace di orchestrare:

- contesto e memoria locale
- inferenza ibrida locale/cloud
- retrieval documentale embedded
- voce offline
- sincronizzazione local-first
- automazioni modulari
- agenti specializzati
- task di sviluppo e manutenzione software

La visione non è “una chat migliore”, ma un **substrato operativo cognitivo** per flussi di lavoro complessi.

## 2. AI-Orchestrator-Core

Il nucleo stabile deve continuare a consolidare:

- confini modulari chiari
- contratti di runtime stabili
- persistenza locale affidabile
- orchestrazione dei task
- plugin registry e agent contracts
- build Android valida e installabile
- compatibilità con futuri adapter desktop

In questa ottica, Core è la base che deve rimanere leggibile, testabile e difendibile nel tempo.

## 3. MobileIDE: direzione evolutiva

La direzione MobileIDE rappresenta l'espansione naturale del progetto verso scenari di lavoro più attivi.

### Obiettivi plausibili
- pianificazione multi-step sul dispositivo
- retrieval locale di codice e documentazione
- gestione del contesto per task di sviluppo
- agenti specializzati per coding, ricerca, manutenzione e automazione
- orchestrazione di tool e workflow da mobile

### Implicazione architetturale
MobileIDE non dovrebbe nascere come fork caotico del codice esistente, ma come crescita coerente sopra i contratti già presenti in `core/`.

## 4. Orizzonti evolutivi

### Fase 1 — solidificazione locale
Focus:

- affidabilità runtime Android
- packaging `.so` corretto
- GGUF locale robusto
- memoria di progetto stabile
- retrieval documentale locale utilizzabile
- sincronizzazione locale affidabile

### Fase 2 — runtime cognitivo più ricco
Focus:

- retrieval contestuale migliore
- integrazione più forte tra memoria, documenti e orchestrazione
- miglioramento della pipeline vocale
- diagnostica runtime più esplicita
- primi workflow avanzati e task agent-based

### Fase 3 — ecosistema modulare
Focus:

- plugin di dominio
- tool registry più ricco
- agenti specializzati coordinati
- task planner più sofisticato
- interazione più stretta con flussi di sviluppo e manutenzione

### Fase 4 — MobileIDE / desktop convergence
Focus:

- Windows/Linux/macOS come runtime di pari dignità
- esperienza di orchestrazione coerente tra mobile e desktop
- strumenti orientati a coding, project ops e maintenance
- federazione di agenti e workflow riusabili

## 5. Evoluzione del runtime locale

Nel tempo il runtime locale dovrebbe evolvere lungo queste direttrici:

- maggiore robustezza dei modelli supportati
- migliori diagnosi di compatibilità runtime/modello
- accelerazione opzionale tramite MLC o backend futuri
- integrazione più forte con retrieval e memoria
- miglior bilanciamento tra qualità, latenza e consumo risorse

## 6. Evoluzione della memoria

La memoria deve crescere da semplice persistenza locale a sistema cognitivo locale strutturato.

### Oggi
- chat history
- project memory
- preferences
- sync records
- document chunks con vettori hash

### Domani
- memoria semantica più ricca
- ranking contestuale più evoluto
- relazioni tra progetto, documenti, task e output AI
- sincronizzazione più intelligente tra dispositivi

## 7. Evoluzione della sincronizzazione

La sincronizzazione non dovrebbe partire da un modello cloud-centrico obbligatorio.

### Direzione desiderata
- peer-to-peer quando possibile
- esportazione/importazione robusta di changeset
- policy di merge più raffinate dove serve
- maggiore visibilità operativa sullo stato sync

## 8. Evoluzione della voce

La voce deve restare un sottosistema separato ma strategico.

### Direzione desiderata
- ASR offline più stabile
- TTS offline più naturale
- gestione migliore di comandi e dictation
- integrazione più forte con orchestrazione task-oriented

## 9. Sicurezza e privacy nel tempo

L'evoluzione del progetto non deve compromettere il principio base:

> locale per default, remoto per scelta esplicita.

Questo implica che anche in futuro:

- memoria e documenti devono poter vivere localmente
- sync non deve richiedere dipendenze cloud obbligatorie
- i provider cloud devono restare adapter sostituibili
- telemetria e remote config non devono diventare assunzioni architetturali rigide

## 10. Criteri di successo

La roadmap deve produrre un sistema che sia:

- comprensibile per maintainer umani
- interpretabile da agenti AI
- affidabile offline
- estendibile modulo per modulo
- sicuro nella gestione dei dati locali
- pronto per scenari MobileIDE e desktop nel medio periodo

## 11. Sintesi finale

La direzione corretta non è ridurre AI-Orchestrator a interfaccia di chat, ma farlo maturare come:

- kernel di orchestrazione cognitiva
- runtime locale estendibile
- piattaforma modulare offline-first
- base per l'evoluzione di AI-Orchestrator-Core e MobileIDE
