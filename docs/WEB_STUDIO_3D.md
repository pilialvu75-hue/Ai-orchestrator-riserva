# AIVEXUS Studio 3D

## Fase 13.1 — Audit

Il Cantiere riconosce già il tipo `cad` tramite `AivexusProjectExtension` e lo salva come bozza. Il passaggio a Studio è attualmente disponibile per i progetti software Web. Conserviamo il tipo esistente e aggiungiamo il percorso CAD a Studio.

Le funzioni di revisione e selezione della versione usano D1 e conservano la generazione precedente. Il contratto attuale verifica applicazioni HTML in Chromium e consegna i sorgenti ZIP. La conversione CAD richiede un risultato tipizzato con sorgente SCAD e STL. I download e le versioni devono usare gli stessi controlli di proprietà. L'anteprima 3D dovrà leggere lo STL verificato.

Il contratto degli allegati esiste già in `AivexusAttachmentStore`. Il percorso da foto dovrà produrre gli stessi parametri CAD, indicando misure confermate, stimate e sconosciute. Il caricamento e la rimozione dei metadati precedono ogni eventuale elaborazione cloud autorizzata.

## Fase 13.2 — Primo motore

Il primo percorso accetta cinque dimensioni numeriche in millimetri, produce OpenSCAD con un modello fisso e converte la geometria in STL con la CLI. La CI esegue la conversione per 80 × 60 × 30 e 90 × 60 × 30 mm, controllando ingombro e vertici della cavità. Pareti da 2 mm, fondo da 3 mm. La prova copre il motore CAD. Anteprima, versioni in Studio, analisi da foto e compatibilità FDM dipendono dai successivi collaudi.

Il prossimo passo è integrare il risultato CAD nei contratti del runner e delle versioni, mantenendo i controlli esistenti sui progetti software. La prima anteprima dovrà usare il file STL salvato. Il controllo manifold e il profilo stampante sono criteri di consegna delle fasi successive.

## Checkpoint Web precedente

- La PR #1299 è su main al commit `7ab222b130ffff0cd9616058c31f528f3b18bdf2`. Il deploy privato #45974918311 è riuscito.
- Contatore Semplice. Versione iniziale `4c528359-2640-4986-9c53-bedd0d4effeb`, versione rivista `54216260-40c8-42eb-afc4-2f1092b2e3e3`. La v2 è verificata in Studio e consegnata sul link privato. Il collaudo manuale ha prodotto 0, 1, 0, 1, 0 con Decrementa, Incrementa, Decrementa, Incrementa e Azzera.
- Cloudflare Access mostra il criterio dedicato ai tre tester sull'applicazione Aivexus Production. Nessuna email inviata.
- La #1246 rimane aperta. Il catalogo NVIDIA documenta accesso gratuito per prototipazione. Serve evidenza dell'account per i job completi e per l'assenza di fatturazione automatica.
