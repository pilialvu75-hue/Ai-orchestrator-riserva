# AIVEXUS Computer Use — anteprima portatile interna (Windows 11)

Questa è una **prova interna e reversibile**, NON una release, NON un
aggiornamento dell'installazione esistente, NON una procedura per aggirare
Smart App Control. Mantiene il codice di AIVEXUS esistente, con il solo
flag di laboratorio `AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true`.

L'artefatto viene generato dal workflow
`.github/workflows/computer-use-qa.yml` e conservato in GitHub Actions
per 7 giorni. La release ufficiale Windows è un percorso separato, che
richiede la firma attendibile (#1132, #1139).

## Requisiti di sicurezza per test reali

1. **Usare un account Windows di prova distinto**. Una app 'portatile'
   può comunque scrivere in %LOCALAPPDATA%, %APPDATA%, preferenze, memoria
   e cartelle modelli dell'account corrente. Spostare l'eseguibile fuori
   da Program Files NON crea isolamento. Non usare il profilo AIVEXUS
   personale per testare un binario sperimentale.
2. Non disinstallare o aggiornare l'AIVEXUS già funzionante, né cambiare
   il percorso di installazione, il registro o i modelli GGUF principali.
3. Lasciare attivi Smart App Control, Defender e tutte le policy.
   Se Windows blocca il binario portatile, **interrompere la prova**:
   questo percorso non garantisce che gli eseguibili unsigned siano
   accettati.
4. Scaricare solamente l'artefatto relativo al commit GitHub verificato
   dalla CI, controllare checksum SHA-256 e cartella completa del
   programma; il file `.exe` non deve essere separato dai DLL e da `data`.
   Non è un installer e non si registra nel sistema.
5. Non usare la modalità portatile per operazioni reali su account,
   browser, servizi esterni o file personali. La prova iniziale è
   solo il **gioco 2048 offline QA** integrato.
6. Autorizzare esplicitamente ogni sessione Computer Use, osservare il
   modello LOCAL che decide le mosse su una griglia reale, verificare
   STOP e durata limitata. La presenza del pulsante non costituisce un
   collaudo riuscito.

## Distinzione Windows 8.1

Il gioco QA usa WinForms e UI Automation, ma **le build Flutter Desktop
attuali non supportano ufficialmente Windows 8.1**. Non proporre
l'anteprima portatile come una release Windows 8.1 certificata.

Sul Windows 8.1 dell'utente funziona ancora `v1.0.12.2`: preservarla.
La PR #1143 introduce un prototipo di recupero indipendente da Flutter;
prima di aggiornare l'app esistente servono un backup completo, test
reali su Windows 8.1, percorso di ritorno dall'esterno della nuova app
e una release approvata.

## Tracciamento delle prove

Per ogni sessione riportare **senza dati personali**:

- sistema operativo e versione (Windows 11 o Windows 8.1);
- build/tag e SHA sorgente effettivo dell'anteprima;
- se il processo parte e se il runtime LOCAL funziona;
- permesso sessione, finestra selezionata e lettura griglia 2048;
- modello LOCAL, mosse effettivamente decise dal modello e casella
  massima letta via UI Automation;
- STOP e riavvio, errori CodeIntegrity, eventuali crash.

### Criteri per promuovere nel prodotto

Il successo di questa anteprima, da solo, **non autorizza** un rilascio
stable né sostituisce la firma dell'installer. La funzionalità viene
promossa nella build ordinaria dal solo `main` dopo prova fisica,
rollout sicuro e rollback verificato (#1140, #1141, PR #1142).
