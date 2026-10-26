# Handoff: Memoria Assistente e RAG — 26 ottobre 2026

## Obiettivo
Consegnare alla sessione Work principale (rientro previsto 1 novembre 2026) codice e test per utilizzare memoria SQLite, ricordi persistenti e RAG, con un reset sicuro da Danger Zone. Nessun intervento fisico su ASUS/S24 e nessuna cancellazione di dati utente.

## Stato nel sorgente
- PR #898: integrata in main, sette CI superate; reset Danger Zone esteso anche agli indici RAG generati, con selezione indipendente da chat, memoria durevole e memoria progetti.
- PR #900: salvataggio di fatti esplicitamente affidati dall'utente nel normale Assistente; aggiornamento con chiave stabile e comando per dimenticare. I ricordi confermati vengono caricati nel contesto tramite il sistema SQLite preesistente.
- Le scritture confermate sono serializzate e condividono un coordinatore con il reset di Danger Zone, così le operazioni in coda non dovrebbero ricreare ricordi appena azzerati.
- Sono presenti test unitari della memoria e test end-to-end con SQLite temporaneo per il sistema RAG.

## Prove funzionali da eseguire
1. In chat ordinaria: Ricorda che il budget è 420. In una nuova chat: Qual è il budget?
2. Aggiornare: Ricorda che il budget è 680. Verificare che il 420 non riappaia.
3. Dimentica il budget. Verificare che una nuova sessione non riceva quel ricordo.
4. Le domande normali, i benchmark e le richieste di agenti specializzati non devono scrivere memoria confermata.
5. Indicizzare un file di prova, cercare un frammento, reindicizzare il file modificato e cancellare soltanto i chunk RAG. Il file originale deve restare intatto.
6. Eseguire il reset globale solo su un profilo di prova; chiudere/riaprire e controllare ogni categoria.
7. Testare reset simultaneo a code di indicizzazione; nessun dato cancellato deve riapparire.
8. Ripetere su app Windows/Android autorizzate: CI verde non equivale a collaudo fisico.

## Limiti da chiudere
- La PR #900 acquisisce soltanto fatti esplicitamente dettati: non attiva ancora l'estrazione indiscriminata di ricordi da conversazioni libere. La promozione automatica di candidati richiede policy e controlli contro falsi ricordi, dati sensibili e benchmark.
- L'indicizzazione documentale può avere scritture proprie non coordinate dalla barriera delle chat: da verificare.
- La memoria vettoriale attuale usa hashing leggero. Verificare qualità del ranking e stabilità dopo riavvio reale.
- Distinguere sempre risultati nativi, test in SQLite temporaneo e prove complete nell'app.
- Conservare modelli, impostazioni, cronologia reale e progetti Cantiere.

## Continuità
Issue #899 è il riferimento canonico; PR #898 è il reset, PR #900 è la pipeline esplicita.
La chat Test per S24 è un canale di resoconti; le sessioni Work separate non si sincronizzano automaticamente.
