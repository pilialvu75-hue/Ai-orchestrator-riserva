# Image LOCAL — prove fisiche S24 FE e prossime capacità

Data: 28 ottobre 2026. Dispositivo: Samsung Galaxy S24 FE. Modalità Chat: LOCAL.

## Collaudi fisici ricevuti

- Foto mela rossa/gialla su fondo bianco: `Food (92%), Fruit (78%), Plant (62%), Vegetable (57%)`. Riconoscitore funzionante, ma **non identifica la mela** e `Vegetable` è un falso positivo.
- Manifesto in francese con teiera e tazza: `Tableware (91%), Poster (77%), Cup (73%), Saucer (62%)`. Riconoscitore funzionante, ma **non identifica Teapot/teiera** e **non legge il testo**.
- Entrambe le prove sono state ripetute con **modalità aereo attiva** negli screenshot (12:14–12:15). La precedente prova online aveva mostrato lo stesso output per la mela. Il funzionamento categoriale **senza connessione** è confermato sulle due immagini; non è ancora una prova multimodale o un benchmark memoria.
- I file di immagini e screenshot dell'utente **non vengono aggiunti al repository** e non devono finire in Diagnostics pubblico. La versione numerica dell'APK non era visibile negli screenshot; non attribuire una versione con certezza senza controllo sul dispositivo.

## Fase OCR offline

Il nuovo `LocalImageTextBridge` host Android è un canale separato da quello del plugin `cantiere_local_image_vision` proveniente dalla Libreria. Usa ML Kit Text Recognition v2 Latin **bundled**, senza download del modello al primo utilizzo e senza Cloud.

L'OCR parte soltanto per categorie indicative di testo (poster, documento, libro, cartello, ecc.) o esplicita richiesta. Viene eseguito **dopo** la classificazione, mai in parallelo. Immagini non oltre 8 MiB, massima dimensione decodificata 1600px, `RGB_565`, blocco se Android è già in pressione RAM, massimo 1800 caratteri di testo visualizzati, timeout. Se l'OCR fallisce, il classificatore continua a funzionare. Nessuna domanda o immagine è caricata nel Cloud.

Il testo prodotto è presentato come **riconoscimento OCR probabilistico**; non è una traduzione, non è comprensione generale di scena e può contenere errori (diacritici, impaginazione, apostrofi, testo inclinato). Una foto di una mela non deve ricevere per default una falsa lettura testuale.

## Prossimi criteri di accettazione

1. Verificare CI: test Flutter e compilazione reale Android ARM64 del nuovo modello OCR.
2. Senza modifiche a dati, modelli o canali release: installare una futura release autorizzata per testare ancora la stessa foto del manifesto in modalità aereo e verificare che compaia una **trascrizione OCR** attendibile. Conservare output per confronto con testo effettivo.
3. Verificare l'integrità della cronologia chat e del modello testuale locale dopo la lettura.
4. Aggiungere successivamente riconoscimento fine-grained (es. mela e teiera, senza inferenze automatiche da etichette generiche), quindi vera VLM on-device GGUF/`libmtmd` con gestione RAM e controlli sul dispositivo.

Il Cantiere deve analizzare il codice OCR per un **possibile riuso in Libreria**, ma una sorgente o un manifest non costituiscono da soli un modulo validato: servono codice materializzato, provenienza, hash, prove CI e test d'integrazione.

## Prove fisiche aggiuntive su 1.0.15+103489 (28/10/2026)

- Manifesto francese: OCR Latin offline ha trascritto la frase principale `AVANT, J'AVAIS LA SCIENCE INFUSE, MAIS ÇA C'EST THÉIÈRE...`; rilevato anche il breve frammento spurio `fasot`. **PASS lettura di testo**; non attribuire comprensione semantica generale.
- Documento campione multilingue fornito come JPG: OCR riconosce molto testo italiano, francese, inglese, segni e numeri, ma confonde `O/0`, `I/l/|` e scompone la tabella (articoli, quantità, prezzi, codici) in gruppi non allineati. **PASS estrazione parziale / FAIL layout tabellare**. Non caricare le immagini originali in CI o Diagnostics pubblici.

## Reflow spaziale sperimentale (questa PR — non ancora provato su S24)

- Il bridge Android ML Kit ora restituisce anche rettangoli di **righe realmente riconosciute**. Il formatter Dart le raggruppa per sovrapposizione verticale, poi per coordinata orizzontale; separa i possibili campi di tabella con ` | ` e usa spaziature verticali per i paragrafi.
- Nessun post-processing semantico, correzione automatica `O/0` o interpretazione di celle vuote. La struttura è *approssimata*, specialmente con colonne multiple, rotazioni e righe sfalsate.
- Limiti: 120 righe / 3200 caratteri di payload geometrici; presentazione max 1800 caratteri; se le coordinate sono assenti o non valide resta la trascrizione ML Kit esistente. Classificatore e OCR rimangono sequenziali.
- Criteri di accettazione: test sintetici per righe fuori ordine, righe tabellari, accentazione e fallback; CI Android; **collaudo fisico con lo stesso JPG di prova** prima di dichiarare il layout risolto.

## Limite PDF separato da Image

`+ > File` permette di selezionare un PDF ma `ChatFileContextService` lo rifiuta esplicitamente: non c'è parsing PDF affidabile per Chat. Il parser legacy `LocalDocumentIndexService._extractPdfText` estrae solo frammenti stampabili dai byte e **non è un parser PDF**: non riutilizzarlo come se fornisse testo verificato. Il PDF campione è già disponibile per il futuro test, ma per ora usa il JPG via `+ > Image`. L'integrazione PDF (testo nativo + eventuali pagine scannerizzate) richiede un lavoro a sé, con limiti di pagine/dimensioni, parsing locale sicuro e test su Android.
