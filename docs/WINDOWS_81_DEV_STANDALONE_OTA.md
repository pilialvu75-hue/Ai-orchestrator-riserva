# Windows 8.1 Dev — rilascio solo Windows, con recupero

Questo percorso evita il rilascio contemporaneo di un'anteprima Android.
**Non si avvia automaticamente**: richiede GitHub Actions, ramo `main`,
attore `pilialvu75-hue`, scelta di pubblicazione e frase di conferma.

## Utilizzo autorizzato

Aprire **Actions → AIVEXUS Windows 8.1 Dev only (manual)**.

1. Scegliere **Run workflow**, ramo **main**, azione **build_only**
   (predefinita). Nessuna release è pubblicata. Il workflow prova il
   backup/ripristino nativo, costruisce il bundle Windows e un setup
   ristretto a Windows 8.1, e conserva per sette giorni lo ZIP
   diagnostico negli artefatti di GitHub Actions.
2. Controllare che l'esecuzione sia interamente **PASS**, che il
   `AI-Orchestrator-Setup-x64.exe` sia presente, e che la firma
   SHA-256 sia calcolata. Questo **non** prova che l'app Flutter moderna
   possa avviarsi su un Windows 8.1 fisico.
3. Solo dopo decisione esplicita del proprietario, eseguire di nuovo
   il workflow scegliendo **publish_win81_dev** e scrivendo esattamente
   `PUBLISH_WIN81_RECOVERY_DEV` nel campo `confirmation`. La pipeline
   produce una nuova versione `v1.0.15-dev+<build>` dalla stessa
   applicazione AIVEXUS in `main`, carica setup e SHA in una *draft*
   release, verifica i due asset e poi rende pubblica la release.
4. La `v1.0.12.2` sul Lenovo può individuare tale release se
   ha selezionato **Dev**, via GitHub Releases e validazione SHA-256
   dell'installer. L'utente ha confermato che l'opzione Dev compare,
   ma il funzionamento del vecchio updater nel dispositivo va
   ancora testato. **Non installare la 104238** come versione recuperabile.

## Limiti e rischi

- Si tratta di un setup **unsigned**, accettato come eccezione soltanto
  per il laboratorio Windows 8.1. Le definizioni Inno impongono
  `MinVersion=6.3`, `OnlyBelowVersion=10.0` e
  `AivexusRecoveryHelper`. Su Windows 10/11 è rifiutato
  dall'installer; le protezioni Windows 11 restano invariate.
- Il backup comprende installazione, dati Local e preferenze Roaming
  configurati dall'installer. Prima del primo aggiornamento il
  proprietario deve verificare che corrispondano **agli effettivi
  percorsi di 1.0.12.2**, in particolare se UAC usa credenziali di
  un amministratore diverso. Un ripristino dell'app non copre
  necessariamente modelli GGUF e dati salvati altrove.
- Il Flutter 3.47.5 impiegato nella CI non supporta ufficialmente
  Windows 8.1. Un risultato PASS su Windows 2022 non equivale alla
  prova reale di avvio o inferenza LOCAL su Lenovo.
- La build usa intenzionalmente la versione Windows 1.0.15+<build> soltanto nel job Win8.1, senza abbassare la versione 1.0.16 del sorgente su main.\n- La release Dev, una volta pubblicata, è **pubblicamente visibile
  agli utenti che selezionano Dev**, benché l'installer sia limitato
  a Windows 8.1. Non è un canale privato a un singolo tester.
- Il codice e gli artefatti restano parte dell'**unica AIVEXUS**.
  Non vengono pubblicati APK Android e non viene modificata la
  release ordinaria per Windows 11.
