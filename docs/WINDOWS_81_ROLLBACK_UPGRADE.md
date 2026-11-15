# AIVEXUS Windows 8.1 — aggiornamento con recupero obbligatorio

Questa guida riguarda **solo la futura release** che incorpora il commit
della pipeline con `AivexusRecoveryHelper`. La vecchia release
`v1.0.15-beta+104238` **non include il recupero** e non deve essere
considerata equivalente.

## Protezione prima dell'installazione

- L'installer aggiorna la **stessa AI Orchestrator**: stesso AppId,
  nessuna disinstallazione richiesta.
- Prima del primo file del programma, l'installer chiede di chiudere
  AIVEXUS e usa un helper esterno, compatibile con .NET Framework 4,
  per creare uno snapshot SHA-256 verificato.
- Lo snapshot include la directory di installazione, il profilo locale
  `%LOCALAPPDATA%\AI Orchestrator` (database e relativi file SQLite)
  e le preferenze supportate nel percorso
  `%APPDATA%\com.aiorchestrator\AI Orchestrator`. La presenza o
  assenza originale delle directory è registrata. Database e
  preferenze non devono essere in uso durante la copia.
- Se la copia fallisce (es. spazio esaurito, file bloccato, hash
  non valido o vecchio checkpoint ancora pendente), l'upgrade deve
  fermarsi **senza sovrascrivere l'installazione**.
- Lo snapshot è locale in
  `%PROGRAMDATA%\AI Orchestrator\Recovery\Snapshots`, con accesso
  ristretto; non va su GitHub o Diagnostics.

## Dopo l'installazione

1. Aprire AIVEXUS e provare avvio, inferenza LOCAL, cronologia, modelli
   e impostazioni; non dichiarare riuscita una sola apertura della UI.
2. Se la nuova versione funziona, **chiudere AIVEXUS**. Nel menu Start
   selezionare **AI Orchestrator - Conferma aggiornamento funzionante**.
   La conferma esplicita conserva lo snapshot storico ma libera il
   blocco di sicurezza necessario per aggiornamenti futuri.
3. Se la nuova versione non parte o regredisce, chiuderla e usare
   **AI Orchestrator - Recupera versione precedente** dal menu Start.
   Il recupero richiede conferma, verifica gli hash e ripristina
   programma, dati locali e preferenze archiviate. Il sistema salva
   separatamente anche lo stato nuovo prima di sostituirlo.

## Cosa non è ancora garantito

- **Windows 8.1 non è supportato ufficialmente da Flutter 3.47**.
  Per garantire compatibilità reale servono prova sul Lenovo Flex 2,
  inferenza LOCAL e test di ripristino fisico. Una build PASS su
  Windows 2022 non equivale a un test Windows 8.1.
- Il vecchio `1.0.12.2` potrebbe avere percorsi di preferenze
  diversi dai nuovi metadata Windows: il profilo effettivo va
  verificato prima di chiamare il ripristino 'completo'.
- Il recupero copre i percorsi sopra elencati e non necessariamente
  modelli GGUF memorizzati su unità esterne, Credential Manager,
  registrazioni del sistema o file in altre directory personalizzate.
- La pipeline ordinaria Windows non garantisce ancora una firma
  Authenticode attendibile su Windows 11. L'assenza del blocco di
  Smart App Control su Windows 8.1 non è una prova di sicurezza.
- Il recupero è un **meccanismo locale**. Non sostituisce un backup
  separato prima di un test su una versione del sistema operativo
  fuori supporto.

## Gate di rilascio

Distribuire solo dopo merge su `main`, test specifici e generali verdi,
verifica asset reale e checksum, nuova versione che l'aggiornamento
interno riconosce. Non riutilizzare il tag e il setup `104238`
riscrivendone i contenuti. L'abilitazione di Computer Use è un
collaudo separato.
