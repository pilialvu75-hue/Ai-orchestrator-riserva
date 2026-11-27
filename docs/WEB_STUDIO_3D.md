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

## Fasi 13.3–13.5 — Flusso in bozza

Dal dettaglio di un progetto Stampa 3D il pannello Web apre STL ASCII locali e le revisioni private del progetto. Un job CAD riceve cinque misure, usa OpenSCAD, conserva SCAD e STL con SHA-256 e rende disponibile l'anteprima dopo l'importazione del risultato. La selezione della revisione attiva è persistente. Il primo comando testuale opera sulle dimensioni della revisione scelta, con sintassi italiana limitata.

La migrazione 013 archivia le revisioni e la selezione. La 014 registra l'invio al runner e vincola il risultato al ticket. Per il collaudo privato occorrono entrambe le migrazioni, una versione di main che contenga il workflow CAD, le chiavi già usate dal runner Web e il flag Pages `AIVEXUS_WEB_CAD_RUNNER_ENABLED=true`. La bozza può essere verificata in CI senza impostare il flag.

Il collaudo privato deve partire dal pannello del Cantiere, generare 80 × 60 × 30 mm, chiedere «Allarga la scatola di 10 mm», verificare la seconda versione, ripristinare la prima e riscaricare entrambi i formati. La validazione attuale controlla dimensioni e bordi chiusi con orientamento coerente. Restano profilo stampante, verifica in slicer e percorso da fotografia.

## Collaudo del rilevatore con fotografie reali

Il collaudo locale ha decodificato i JPEG di Wikimedia Commons e ridimensionato il lato lungo a 1000 pixel, come fa il pannello foto. Il rilevatore e il controllo della cavità sono le funzioni del modulo Web. Sistema di coordinate con origine in alto a sinistra.

| Fotografia | Contorno | Cavità |
| --- | --- | --- |
| [Small box, open](https://commons.wikimedia.org/wiki/File:Small_box,_open.jpg), Meathead Movers, CC BY-SA 2.0 | Rilevato, da (92, 61) a (921, 801) su 1000 × 846 px | Non determinata. La vista obliqua e le alette non corrispondono al modello richiesto dal rilevatore. |
| [Rectangular plastic food containers](https://commons.wikimedia.org/wiki/File:Rectangular_plastic_food_containers.JPG), BrokenSphere / Wikimedia Commons, CC BY-SA 2.5 | Non rilevato su 1000 × 719 px | Contenitori impilati, senza contorno unico accettato. |
| [Shimano Deore Rear Derailleur](https://commons.wikimedia.org/wiki/File:Shimano_Deore_Rear_Derailleur.JPG), Armchair, CC BY-SA 3.0 | Non rilevato su 906 × 1000 px | Pezzo meccanico complesso fuori dal percorso parametrico della scatola. |

I campioni non includono un riferimento metrico verificato sul piano dell'oggetto. Nessuna delle tre foto ha quindi prodotto una misura in millimetri o uno STL. Il test evidenzia la differenza tra rilevare una sagoma 2D e ricostruire la geometria. Per verificare le dimensioni di una scatola servono viste dello stesso oggetto con un riferimento metrico, inclusa una vista superiore utile per le pareti.
La ripetizione del collaudo con il filtro rettangolare ha escluso la scatola ripresa in obliquo dalle stime automatiche. La sagoma occupava circa il 59% del suo rettangolo esterno. Gli altri due campioni continuano a non produrre un contorno accettato.
