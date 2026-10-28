# Chat PDF offline — Android S24 FE (proposta isolata)

## Campo di applicazione

Quando l'utente seleziona esplicitamente **Chat > + > File > PDF** in modalità LOCAL, il reader Android `com.aiorchestrator/local_pdf_text` legge il file localmente. Il testo estratto è indicizzato nell'indice RAG *della sessione attiva*, con provenienza, titolo e percorso del PDF originale. Non va inviato nei Diagnostics pubblici.

## Due percorsi

- PDF digitali su Android API 35+: `PdfRenderer.Page.getTextContents()` per testo estraibile realmente presente; nessuna decodifica grezza di byte.
- PDF scannerizzati o pagine prive di testo selezionabile: `PdfRenderer.Page.render()` a bitmap massimo 1500 px, poi **ML Kit OCR Latin incorporato**, una pagina per volta, senza Internet.
- Android 21–34: solo rasterizzazione + OCR; su Windows/Linux/macOS/Web il menu File non deve fingere che PDF sia supportato. Rimane possibile usare TXT.
- Il testo passa al normale contesto locale Chat; **se l'utente sceglie esplicitamente Cloud**, il normale flusso prompt/documenti può inviare i relativi estratti al provider scelto, come già accade per TXT. Il reader PDF non compie upload autonomi.

## Limiti di sicurezza

- Solo PDF con intestazione `%PDF-`, dimensione massima 8 MiB, **1–6 pagine** e massimo 16.000 caratteri; un PDF maggiore viene rifiutato, mai letto a metà senza segnalazione.
- Controllo della RAM libera (384 MiB), bitmap ARGB_8888 contenuta, OCR seriale con timeout nativo per pagina e timeout Dart complessivo.
- PDF corrotti, protetti, vuoti, senza testo, troppo grandi e pagine fuori limite producono errori leggibili e **nessuna scrittura nell'indice**.
- Nessuna migrazione SQLite, eliminazione conversazioni, download di modelli, modifica dell'OCR Image e nessuna pubblicazione automatica.

## Acceptance fisica prima della promozione

1. Sul S24 FE, modalità aereo + LOCAL + `+ > File`, allegare il PDF campione `Test_OCR_offline_Aivexus.pdf` da una chat di prova.
2. Chiedere: `Qual è il prezzo della teiera rossa e qual è il suo codice?` Confrontare con `24,00 €` e `TR-07` del documento. Verificare che la risposta citi il nome del PDF.
3. Verificare un PDF scannerizzato di una pagina, quindi una seconda domanda nella stessa conversazione senza allegato.
4. Verificare che il testo non compaia in un'altra chat e che cronologia/modelli/impostazioni non siano alterati.
5. Su macOS/Windows/Linux/Web, l'assenza del bridge Android deve produrre il limite esplicito; non mascherarlo con un upload.

La lettura delle tabelle nei PDF tramite OCR resta **probabilistica**, come per le immagini; il testo nativo può anche non rispettare perfettamente l'impaginazione. I test sintetici non sono prova fisica.
