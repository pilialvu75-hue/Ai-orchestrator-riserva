# AI Orchestrator — Guida Utente (Italiano)

> Versione: 1.0.0 · Lingua: Italiano

---

## Indice

1. [Introduzione](#1-introduzione)
2. [Requisiti di sistema](#2-requisiti-di-sistema)
3. [Installazione](#3-installazione)
   - [Android (APK)](#android-apk)
   - [Windows (EXE)](#windows-exe)
4. [Configurazione iniziale](#4-configurazione-iniziale)
5. [Funzionalità principali](#5-funzionalità-principali)
6. [Provider AI supportati](#6-provider-ai-supportati)
7. [Memoria di progetto](#7-memoria-di-progetto)
8. [Cronologia chat](#8-cronologia-chat)
9. [Impostazioni e preferenze](#9-impostazioni-e-preferenze)
10. [Risoluzione dei problemi](#10-risoluzione-dei-problemi)
11. [Privacy e sicurezza](#11-privacy-e-sicurezza)
12. [Flusso decisionale](#12-flusso-decisionale)
13. [Architettura agenti](#13-architettura-agenti)
14. [Priorità di esecuzione](#14-priorità-di-esecuzione)
15. [Gestione offline/online reale](#15-gestione-offlineonline-reale)
16. [Licenza](#16-licenza)

---

## 1. Introduzione

**AI Orchestrator** è un'applicazione Flutter multi-piattaforma (Android e Windows) pensata per
sviluppatori e team che vogliono gestire la memoria di progetto, interagire con diversi modelli di
intelligenza artificiale e mantenere uno storico contestuale delle conversazioni — tutto in un'unica
interfaccia.

L'architettura segue il pattern **Clean Architecture** con BLoC per la gestione dello stato, garantendo
un'app robusta, testabile e facilmente estendibile.

---

## 2. Requisiti di sistema

| Piattaforma | Requisiti minimi |
|-------------|-----------------|
| **Android** | Android 6.0 (API 23) o superiore, 100 MB di spazio libero |
| **Windows** | Windows 10 (64-bit) o superiore, .NET runtime incluso nel pacchetto |

---

## 3. Installazione

### Android (APK)

1. Scarica il file `ai-orchestrator-<versione>.apk` dalla sezione **Releases** di GitHub.
2. Sul dispositivo Android, vai in **Impostazioni → Sicurezza → Origini sconosciute** e abilita
   l'installazione da fonti esterne (necessario solo la prima volta).
3. Apri il file APK scaricato e segui le istruzioni a schermo per completare l'installazione.
4. Al primo avvio, l'app richiede le autorizzazioni necessarie (storage per il database locale).

### Windows (EXE)

1. Scarica il file `ai-orchestrator-windows-<versione>.zip` dalla sezione **Releases** di GitHub.
2. Estrai il contenuto dello ZIP in una cartella a tua scelta (es. `C:\Programmi\AI-Orchestrator`).
3. Avvia `ai_orchestrator.exe` contenuto nella cartella estratta.
4. Non è richiesta alcuna installazione aggiuntiva: tutte le dipendenze sono incluse nel pacchetto.

> **Nota per Windows Defender:** al primo avvio potrebbe comparire un avviso di SmartScreen.
> Clicca su **Altre informazioni → Esegui comunque** per procedere.

---

## 4. Configurazione iniziale

Al primo avvio, AI Orchestrator mostra un **onboarding in tre passi**:

| Passo | Descrizione |
|-------|-------------|
| 1 | Benvenuto e presentazione delle funzionalità |
| 2 | Selezione del provider AI predefinito |
| 3 | Verifica aggiornamenti dei modelli disponibili |

Al termine dell'onboarding puoi inserire le **chiavi API** per i provider che intendi usare
(vedi sezione [Provider AI supportati](#6-provider-ai-supportati)).

---

## 5. Funzionalità principali

### 💬 Chat AI
Interfaccia conversazionale ispirata a Gemini con supporto multi-turno. Ogni sessione viene
salvata nel database locale SQLite, permettendo di riprendere le conversazioni in qualsiasi momento.

### 🧠 Memoria di progetto
Salva e recupera il contesto del progetto corrente:
- **Obiettivo principale** (`master_goal`): la descrizione ad alto livello del progetto.
- **Contesto corrente** (`current_context`): dettagli sulla fase attuale di sviluppo.
- **Ultimo snippet di codice** (`last_code_snippet`): il frammento di codice più recente condiviso.

### 🔄 Multi-provider AI
Passa da un provider all'altro senza perdere la cronologia della sessione.

### 📋 Cronologia sessioni
Tutte le sessioni di chat sono indicizzate per `session_id`, `provider` e `timestamp`, così puoi
filtrare e recuperare conversazioni precedenti.

---

## 6. Provider AI supportati

| Provider | Chiave API richiesta | Modalità offline |
|----------|---------------------|-----------------|
| OpenAI (GPT-4 / GPT-3.5) | `OPENAI_API_KEY` | ✗ |
| Google Gemini | `GEMINI_API_KEY` | ✗ |
| xAI Grok | `GROK_API_KEY` | ✗ |
| GitHub Copilot | `COPILOT_API_KEY` | ✗ |
| Modello locale | — | ✓ |

Le chiavi API possono essere inserite nelle impostazioni dell'app; vengono memorizzate in modo
sicuro nella tabella `user_preferences` del database locale e non vengono mai trasmesse a server
di terze parti diversi dal provider selezionato.

---

## 7. Memoria di progetto

La memoria di progetto è il cuore di AI Orchestrator. Permette all'assistente AI di mantenere
il contesto anche tra sessioni diverse.

### Come aggiornare la memoria

1. Apri la sezione **Memoria di Progetto** dalla barra di navigazione principale.
2. Modifica i campi **Obiettivo**, **Contesto** e **Ultimo Snippet**.
3. Premi **Salva** — i dati vengono persistiti immediatamente nel database SQLite locale.

### Come viene usata nelle risposte AI

Ad ogni messaggio inviato all'AI, la memoria di progetto viene allegata automaticamente al prompt
di sistema, garantendo risposte coerenti con il lavoro in corso.

---

## 8. Cronologia chat

- Ogni conversazione è identificata da un `session_id` univoco (UUID v4).
- Le sessioni vengono elencate in ordine cronologico inverso.
- Per avviare una nuova sessione: tocca l'icona **+** nella schermata Chat.
- Per cancellare una sessione: tieni premuto sulla voce nell'elenco e seleziona **Elimina**.

---

## 9. Impostazioni e preferenze

| Impostazione | Descrizione |
|---|---|
| Provider AI predefinito | Il provider selezionato all'avvio di ogni nuova sessione |
| Chiavi API | Inserimento e modifica delle chiavi per i provider cloud |
| Lingua dell'interfaccia | Italiano / English (in sviluppo) |
| Tema | Scuro (predefinito) / Chiaro |
| Cancella dati locali | Elimina tutta la cronologia e la memoria di progetto |

---

## 10. Risoluzione dei problemi

### L'app non risponde ai messaggi
- Verifica che la chiave API del provider selezionato sia corretta e non scaduta.
- Controlla la connessione a Internet (necessaria per i provider cloud).
- Se usi il modello locale, assicurati che il modello sia stato scaricato completamente.

### Il database risulta corrotto
1. Vai in **Impostazioni → Cancella dati locali**.
2. Riavvia l'app — il database verrà ricreato automaticamente.

### L'APK non si installa su Android
- Assicurati di aver abilitato l'installazione da **Origini sconosciute**.
- Verifica che la versione di Android sia 6.0 o superiore.

### L'EXE non si avvia su Windows
- Estrai tutti i file dallo ZIP prima di avviare l'eseguibile.
- Non spostare solo il file `.exe` fuori dalla cartella: richiede le DLL incluse nel pacchetto.

---

## 11. Privacy e sicurezza

- Tutti i dati (memoria di progetto, cronologia chat, preferenze) sono salvati **esclusivamente
  sul dispositivo** in un database SQLite locale.
- Le chiavi API vengono inviate **solo** al provider AI corrispondente per elaborare le richieste.
- L'app **non** raccoglie telemetria, analytics o dati personali.
- Il codice sorgente è aperto e disponibile su [GitHub](https://github.com/pilialvu75-hue/AI-Orchestrator-Core).

---

## 12. Flusso decisionale

Ogni volta che l'utente invia un messaggio, AI Orchestrator esegue la seguente sequenza di operazioni:

```
Utente invia messaggio
        │
        ▼
ChatBloc riceve l'evento SendChatMessageEvent
        │
        ▼
ContextWindowManager recupera la finestra di contesto
(ultimi N messaggi dalla sessione attiva)
        │
        ▼
ProjectMemoryRepository carica la memoria di progetto
(master_goal, current_context, last_code_snippet)
        │
        ▼
CacheManager verifica se esiste una risposta in cache
        │
   ┌────┴────┐
   ▼         ▼
HIT cache  MISS cache
   │         │
Risposta     ▼
immediata  Provider selezionato?
           ┌────────────┬──────────────────┐
           ▼            ▼
    Cloud (online) Locale (offline)
           ▼            ▼
     CloudRuntimeProvider  LocalRuntimeProvider
        (online)              (offline GGUF)
           │            │
           └─────┬──────┘
                 ▼
         Risposta salvata in SQLite
         (chat_history + aggiornamento cache)
                 │
                 ▼
         ChatBloc emette ChatLoaded
         → UI aggiornata
```

In caso di errore di rete con provider cloud, il BLoC emette uno stato `ChatError` con il messaggio originale della `Failure`, consentendo all'utente di ritentare o passare al modello locale.

---

## 13. Architettura agenti

AI Orchestrator è strutturato attorno a quattro **agenti BLoC** principali, ognuno con responsabilità ben definite:

| Agente (BLoC) | Responsabilità | Dipendenze chiave |
|---|---|---|
| **ProjectMemoryBloc** | CRUD sulla memoria di progetto (obiettivo, contesto, snippet) | `ProjectMemoryRepository` → SQLite |
| **ChatBloc** | Gestione del ciclo di vita della chat: invio messaggi, caricamento storico, pruning | `ChatRepository`, `AiRepository`, `ContextWindowManager` |
| **OnboardingBloc** | Guida al primo avvio, selezione provider, verifica aggiornamenti modelli | `ModelRegistryDataSource` |
| **ModelDownloadBloc** | Download, selezione e aggiornamento dei modelli GGUF locali | `LocalAiRepository`, `ModelDownloadService` |

### Runtime di inferenza unificato (`InferenceService`)

L’inferenza è instradata da `InferenceService`, che usa:

| Componente | Endpoint/Sorgente | Modalità |
|---|---|---|
| `CloudRuntimeProvider` | repository cloud (`OpenAiDataSource`, `GeminiDataSource`, `GrokDataSource`, `CopilotDataSource`) | online |
| `LocalRuntimeProvider` | file system locale + modello GGUF validato | offline |

Entrambi convergono sullo stesso contratto di risposta (`InferenceResponse`) in modalità streaming/tokenizzata, con fallback automatico cloud quando il runtime locale fallisce prima di produrre output.

### Servizi di supporto

| Servizio | Funzione |
|---|---|
| `ContextWindowManager` | Mantiene la finestra di contesto in memoria (short-term) e la persiste su SQLite (long-term) |
| `CacheManager` | Cache in memoria per risposte frequenti, riduce le chiamate API ridondanti |
| `BixbyHandler` | Gestione comandi vocali tramite Bixby (Samsung) |
| `AndroidIntentHandler` | Ricezione di intent Android esterni (es. condivisione testo da altre app) |
| `SpeechService` | STT (Speech-to-Text) e TTS (Text-to-Speech) per l'input/output vocale |
| `ImageService` | Acquisizione e preprocessing di immagini per il modulo multimodale |

---

## 14. Priorità di esecuzione

Quando più richieste concorrenti vengono generate (es. messaggio in arrivo + aggiornamento memoria + download modello), AI Orchestrator applica le seguenti priorità:

| Priorità | Operazione | Motivo |
|:---:|---|---|
| 1 (Alta) | Risposta al messaggio utente (`ChatBloc`) | Esperienza utente in tempo reale |
| 2 | Salvataggio memoria di progetto (`ProjectMemoryBloc`) | Consistenza del contesto per le risposte successive |
| 3 | Pruning della cronologia chat (`PruneChatHistory`) | Ottimizzazione storage, non bloccante |
| 4 (Bassa) | Download modello locale (`ModelDownloadBloc`) | Operazione in background, non interrompe la chat |

### Regole di concorrenza

- **Chat e memoria** operano su `Isolates` separati tramite il layer `sqflite`, evitando blocchi sulla UI.
- Il **download del modello** avviene in background; lo stato di avanzamento è esposto tramite `Stream<double>` nel `ModelDownloadBloc`.
- Il **pruning** viene eseguito solo quando il numero di messaggi in una sessione supera la soglia definita in `AppConstants.chatHistoryMaxMessages`, per non rallentare le operazioni principali.
- La **cache** (`CacheManager`) viene consultata prima di qualsiasi chiamata al provider, abbattendo la latenza percepita dall'utente.

---

## 15. Gestione offline/online reale

AI Orchestrator supporta un funzionamento ibrido: può operare sia con provider cloud (online) sia con modelli locali GGUF (offline), senza richiedere modifiche alla configurazione tra una sessione e l'altra.

### Modalità online (provider cloud)

| Aspetto | Dettaglio |
|---|---|
| **Connessione richiesta** | Sì — connessione Internet attiva |
| **Latenza** | Variabile (dipende dal provider e dalla rete) |
| **Limite token** | Definito dal contratto API del provider |
| **Streaming** | Supportato via `streamComplete()` |
| **Gestione errori** | `NetworkFailure` o `ServerFailure` emessi dal repository; il BLoC espone lo stato `ChatError` con messaggio leggibile |

### Modalità offline (modello locale GGUF)

| Aspetto | Dettaglio |
|---|---|
| **Connessione richiesta** | No — completamente offline dopo il download |
| **Download modello** | Gestito da `ModelDownloadBloc` con progresso in tempo reale |
| **Selezione modello** | Tramite `SelectModel` use case; la scelta è persistita in `user_preferences` |
| **Inferenza** | Eseguita localmente tramite `LocalAiRepository` → `ModelDownloadService` |
| **Aggiornamenti** | Verificati da `CheckForUpdates`; il download del nuovo modello avviene in background |

### Passaggio tra modalità

1. Vai in **Impostazioni → Provider AI predefinito**.
2. Seleziona un provider cloud (OpenAI, Gemini, Grok, Copilot) oppure **Modello locale**.
3. La preferenza viene salvata in `user_preferences` e applicata immediatamente alla sessione corrente.
4. Il `ChatBloc` instrada automaticamente ogni nuovo messaggio al provider attivo, senza perdere la cronologia della sessione.

> **Suggerimento:** se la connessione è assente e viene selezionato un provider cloud, il `ChatBloc` emette immediatamente `ChatError` con indicazione di `NetworkFailure`, permettendo all'utente di passare al modello locale prima di riprovare.

---

## 16. Licenza

Questo progetto è distribuito sotto licenza **MIT**.
Consulta il file `LICENSE` nel repository per i dettagli completi.

---

*Guida generata automaticamente durante il processo di build CI/CD.*
