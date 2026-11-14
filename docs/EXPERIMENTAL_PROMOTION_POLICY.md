# AIVEXUS — convergenza obbligatoria da sperimentale a ordinario

Decisione prodotto del 14 novembre 2026. Tracciamento: issue #1141.

## Principio: una sola AIVEXUS

Il ramo `main` contiene l'unica implementazione autorevole. Le versioni
`beta`, `nightly` e `stable` sono canali di **rilascio della stessa
applicazione**, non linee di prodotto o branch permanenti che evolvono
indipendentemente.

La funzionalità sperimentale può esistere inizialmente dietro un flag
esplicito, ma **non deve restare una seconda implementazione permanente**.
Appena un collaudo reale dimostra che la funzionalità raggiunge i criteri
di accettazione nel perimetro dichiarato, preparare **subito** la PR di
promozione sulla HEAD corrente di `main`. Non attendere di creare nuovi
rami funzionali concorrenti.

## Stati e passi obbligatori

1. **Sperimentale**: branch temporaneo + PR su `main`, test riproducibili,
   flag QA esplicito, rischio e piattaforme documentati. Le build QA partono
   da commit di `main` verificati, con identificazione di tag/SHA.
2. **Integrato, non ancora validato**: codice già in `main`, ma flag
   disabilitato nelle release ordinarie; CI verde non significa hardware
   collaudato. Esempio: Computer Use Windows + 2048 in QA.
3. **Validato sul dispositivo**: annotare release/tag, commit, macchina/OS,
   scenario e risultati osservati, fallimenti e diagnostica; verificare
   regressioni, autorizzazioni, persistenza e rollback. Se il test è
   circoscritto a Windows, la validazione **non si estende automaticamente**
   a macOS/Android/Linux.
4. **Promozione**: aprire PR breve su `main` per rendere disponibile la
   funzione nelle build ordinarie **per le piattaforme validate**.
   Riconciliare eventuali commit concorrenti; usare l'implementazione
   esistente, eliminare codice duplicato, test o flag QA ormai inutili.
   Una funzione rischiosa può richiedere consenso per ogni sessione:
   *promuovere* non significa togliere i permessi o avviare azioni autonome
   senza approvazione.
5. **Definitiva per il perimetro validato**: review, CI, test di regressione,
   successivo rilascio ordinario autorizzato, aggiornamento interno e
   prova di installazione reali. Registrare issue/PR/SHA/versione.
   Nessuna dichiarazione `stable` basata solo su compilazione o simulazioni.
6. **Pulizia**: verificare che il branch sperimentale non contenga commit
   esclusivi ancora necessari; chiudere PR superate e rimuovere i soli
   branch temporanei già riconciliati. Tag e release storici restano
   tracciabili e non si riscrivono. Non cancellare indiscriminatamente
   vecchi branch o lavori di altri cantieri.

## Gate per la promozione

- Test funzionale **reale**, non solo CI o mock, sui sistemi dichiarati
  compatibili; il modello IA deve compiere le azioni realmente, non seguire
  uno script di mosse predefinite.
- Sicurezza e privacy: consenso esplicito per cattura/input desktop;
  STOP efficace; limiti di sessione; nessun trasferimento di dati
  personali non approvato.
- Nessuna regressione critica delle funzionalità esistenti; test di
  installazione/aggiornamento e diagnostica verificabili.
- **Rollback e preservazione dei dati** collaudati prima di promuovere
  aggiornamenti che potrebbero rendere inutilizzabile un'installazione
  precedente. Un semplice pulsante nella nuova app non basta se questa
  non si avvia. Riferimento: #1140.
- Firma digitale Authenticode attendibile per la release Windows che la
  richiede; nessun aggiramento di Smart App Control/Defender: #1132, #1139.
- Una piattaforma legacy non supportata ufficialmente (es. Windows 8.1)
  resta `sperimentale/compatibilità non garantita` finché non esiste
  un test fisico specifico. Una promozione Windows 10/11 non cambia
  automaticamente tale stato.
- Pubblicazione delle release secondo i gate e le autorizzazioni già
  previste: questa policy non autorizza spese, account, distribuzioni
  commerciali né nuove release da sola.

## Come prevenire divergenze

- Prima di ogni modifica, recuperare HEAD di `main`, PR in corso,
  branch che toccano gli stessi file e test applicabili.
- Nessun fork permanente `stable` vs `experimental` della stessa
  feature. I flag differenziano temporaneamente il comportamento di
  **un'unica base sorgente**, non due codici che crescono separatamente.
- Se una beta supera il collaudo, la **promozione ha priorità su nuove
  sperimentazioni sovrapposte**. Se fallisce, creare una correzione su
  `main` e ripetere il collaudo; non lasciarne due versioni parallele.
- Lo stato `integrato`, `validato`, `promosso`, `rilasciato`
  deve rimanere distinto nell'issue; una PR MERGED non equivale
  automaticamente a una funzione attiva nel prodotto installato.

## Applicazione immediata

| Area | Stato reale | Condizione per diventare ordinaria |
| --- | --- | --- |
| Computer Use/2048 Windows | Codice in `main`, build QA con flag `AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA` | Firma installer, prova fisica con vero LOCAL che osserva/decide, STOP e rollback; poi PR di attivazione nella build ordinaria Windows |
| Firma Windows (#1139) | Protezione della pipeline già integrata | Credenziale attendibile, release firmata e installazione ASUS con protezioni attive |
| Rollback Windows (#1140) | Richiesto, non implementato né collaudato | Ripristino accessibile fuori dall'app e backup precedente verificato; test fisico, inclusi dati |
| HYBRID | Feature QA controllata per piattaforme | Consenso effettivo e continuità dei dati con prove fisiche per ciascuna piattaforma dichiarata |

Per ciascuna promozione usare il modello issue
`.github/ISSUE_TEMPLATE/experimental-promotion.md`.
