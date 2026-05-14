# Guida generale di AI-Orchestrator

AI-Orchestrator è una **piattaforma modulare offline-first di orchestrazione cognitiva**.
Non va interpretata come una semplice app di chat AI: il suo scopo è coordinare memoria, inferenza, documenti, voce, sincronizzazione e automazione in un runtime locale estendibile.

## 1. Obiettivo del progetto

Il progetto nasce per offrire un ambiente in cui l'utente possa:

- conservare il contesto di lavoro sul dispositivo
- usare modelli locali quando possibile
- passare ai provider cloud solo quando necessario
- indicizzare documenti in locale
- integrare input/output vocale offline
- sincronizzare dati e stato in ottica local-first
- evolvere verso scenari di sviluppo assistito e MobileIDE

In termini architetturali, il repository rappresenta la base di **AI-Orchestrator-Core** con una direzione evolutiva verso un ecosistema più ampio.

## 2. Visione offline-first

La filosofia del progetto è semplice:

> i dati dell'utente devono rimanere utili e accessibili anche senza rete.

Per questo motivo il repository privilegia:

- persistenza locale tramite SQLite
- memoria contestuale locale
- indicizzazione documentale locale
- sincronizzazione basata su cambi locali
- runtime Android on-device tramite FFI
- servizi cloud opzionali e non centrali

Quando la rete non è disponibile, l'applicazione deve degradare in modo controllato, non collassare.

## 3. Come è organizzato il sistema

### `lib/core/`
Contiene i contratti stabili e i servizi trasversali:

- orchestrazione
- runtime di inferenza
- memoria contestuale
- sincronizzazione CRDT
- servizi vocali
- configurazione
- plugin registry
- servizi di update

### `lib/features/`
Contiene i moduli applicativi in stile Clean Architecture:

- `chat`
- `projects`
- `local_ai`
- `cloud_ai`
- `voice`
- `document_intelligence`
- `coding_assistant`
- `settings`
- `onboarding`
- `multimodal`

### `lib/native/` e `native/`
Contengono il ponte con il mondo piattaforma/runtime:

- esecuzione Android
- intent Android
- integrazione Bixby
- bridge `llama.cpp`
- hook futuri per runtime MLC

## 4. Runtime locale vs cloud

AI-Orchestrator supporta tre modalità concettuali.

### Modalità locale
Usa un modello scaricato e validato in locale.
Su Android il percorso attuale passa da:

- `AndroidFfiRuntimeProvider`
- `libllama_bridge.so`
- `llama.cpp`
- file GGUF nel filesystem dell'app

### Modalità cloud
Usa provider remoti tramite il layer `cloud_ai`.
Il repository include data source per:

- OpenAI
- Gemini
- Claude
- Grok
- Copilot

### Modalità ibrida
`InferenceService` decide il routing e può:

- provare il locale per primo
- usare il cloud come fallback
- ripiegare sul locale se il cloud non è disponibile e c'è un modello valido

Questa separazione è fondamentale perché evita che l'app sia vincolata a un singolo backend.

## 5. Memoria di progetto e contesto

La memoria è uno dei pilastri del sistema.

### Memoria breve
`ContextWindowManager` gestisce la finestra di contesto utile alla sessione attiva.

### Memoria persistente
Le informazioni principali vengono salvate in SQLite:

- cronologia chat
- memoria di progetto
- preferenze utente
- chunk documentali indicizzati
- record di sincronizzazione

### Perché è importante
Questo approccio permette di mantenere continuità tra sessioni, ridurre dipendenze dal cloud e preparare il terreno a futuri agenti specializzati.

## 6. Sistema documentale e memoria vettoriale

Il modulo `document_intelligence` implementa una pipeline locale di indicizzazione.

### Pipeline attuale
1. lettura del file
2. estrazione del testo
3. suddivisione in chunk sovrapposti
4. generazione di vettori hash compatti
5. salvataggio in SQLite
6. ricerca per similarità coseno

### Cosa significa davvero
Non esiste ancora un database vettoriale esterno completo. La memoria vettoriale attuale è una base embedded, locale, leggera e sufficiente per retrieval offline e futura evoluzione architetturale.

## 7. Pipeline vocale

Il sottosistema voce è modulare e separato dal runtime di inferenza GGUF.

### Componenti principali
- `SherpaOnnxAdapter`
- `VoiceInputService`
- `VoiceOutputService`
- `VoiceTextNormalizer`

### Funzioni
- ASR offline
- TTS offline
- normalizzazione del testo
- integrazione controllata con il flusso di orchestrazione

La voce non deve contaminare il layer di orchestrazione principale: produce testo in ingresso e consuma testo in uscita.

## 8. Integrazione ONNX

L'integrazione ONNX è presente soprattutto nella pipeline vocale tramite Sherpa-ONNX.
Questo consente di mantenere separati:

- runtime conversazionale GGUF / llama.cpp
- pipeline ASR/TTS offline basata su ONNX

Il vantaggio è architetturale: i due mondi possono evolvere in modo indipendente.

## 9. Accelerazione MLC

Nel runtime Android esiste una superficie di integrazione MLC (`mlc_native_bridge`), ma allo stato attuale non è il percorso abilitato di default.

In pratica:

- l'app ha un punto di aggancio per future accelerazioni MLC
- la build Android attuale usa `AI_ANDROID_ENABLE_MLC=OFF`
- `ANDROID_NATIVE_MLC_ENABLED` è disabilitato

Quindi l'accelerazione MLC è una direzione evolutiva concreta, non ancora il backend primario attivo in produzione.

## 10. Logica di orchestrazione dei task

`Orchestrator` classifica l'input tramite `IntentAnalyzer` e instrada verso:

- `ExecutionEngine` per comandi o azioni di sistema
- `PlannerService` per decomposizione di task e coding/planning
- `InferenceService` per chat, reasoning e generazione

Questo rende l'architettura più simile a una piattaforma di orchestrazione che a un semplice client AI.

## 11. Sincronizzazione local-first

`SyncManager` mantiene record CRDT con persistenza SQLite.

### Proprietà importanti
- la scrittura locale avviene sempre per prima
- i cambi vengono esportati/importati come changeset
- i conflitti vengono risolti con logica last-write-wins
- la rete è opzionale, non strutturale

Questo prepara l'espansione futura verso sincronizzazione peer-to-peer o multi-device.

## 12. Vincoli Android

Android è oggi la piattaforma più delicata perché combina:

- Flutter engine
- librerie native `.so`
- firma APK
- ABI supportate
- toolchain Gradle / Kotlin / NDK

I punti chiave attuali sono:

- target ARM64 (`arm64-v8a`)
- packaging corretto di `libflutter.so` e `libapp.so`
- build release senza minify e senza resource shrinking
- `GGML_OPENMP=OFF` per evitare l'inclusione di `libomp.so`

## 13. Sicurezza e privacy

Il modello di sicurezza del progetto è prudente.

### Principi
- dati locali per default
- cloud solo se selezionato esplicitamente
- niente dipendenza architetturale dalla telemetria
- separazione chiara tra runtime locale e provider remoti

### Conseguenze pratiche
- conversazioni e memoria di progetto restano sul dispositivo
- i documenti indicizzati restano sul dispositivo
- i record di sync restano sul dispositivo finché non vengono condivisi
- le richieste cloud passano solo verso il provider scelto

## 14. Espansione futura desktop

L'architettura è già predisposta a un'estensione futura verso:

- Windows
- Linux
- macOS

Il principio è aggiungere nuovi adapter di runtime e nuove implementazioni native senza rompere i contratti di `core/`.

## 15. Direzione MobileIDE

La traiettoria evolutiva del progetto non è solo “assistant mobile”, ma una forma di **MobileIDE cognitiva offline-first**.

Questo significa che in prospettiva AI-Orchestrator potrà coordinare:

- pianificazione di attività
- memoria di progetto strutturata
- retrieval documentale locale
- automazioni modulari
- agenti specializzati
- assistenza al coding e alla manutenzione

## 16. A chi serve questa repository

Questa documentazione è pensata per:

- utenti finali che vogliono capire il comportamento dell'app
- contributor che devono individuare i moduli corretti
- maintainer futuri che devono preservare i confini architetturali
- agenti AI che devono ragionare sul codice senza trattare il progetto come una chat app generica

## 17. Documenti collegati

- [MODULAR_ARCHITECTURE.md](MODULAR_ARCHITECTURE.md)
- [OFFLINE_RUNTIME.md](OFFLINE_RUNTIME.md)
- [ANDROID_BUILD.md](ANDROID_BUILD.md)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- [ROADMAP_EVOLUTIVA.md](ROADMAP_EVOLUTIVA.md)
