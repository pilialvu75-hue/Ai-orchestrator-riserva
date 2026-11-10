# Collaudo Assistant LOCAL — pagine HTTPS pubbliche (fase 2, issue #1102)

Questa checklist è destinata **solo** a una beta che includa la seconda PR dei link. Non confonderla con la beta YouTube titolo/canale.

## Contratto funzionale

- **Solo LOCAL**: un unico URL HTTPS pubblico nel messaggio originale dell'utente attiva un recupero di testo.
- Reimpiega il lettore del Cantiere con risoluzione DNS vincolata alla connessione, rifiuto IP privati/locali, limite a 96 KB, massimo 1800 caratteri di testo, timeout 6 secondi, due redirect al massimo.
- Il modello non riassume autonomamente il testo in questa prima estensione: AIVEXUS mostra un estratto etichettato e il dominio di provenienza. Non descrivere il testo come verifica fattuale indipendente.
- La pagina non può inviare istruzioni al modello attraverso questo percorso; il testo viene **visualizzato** soltanto. Nessun contenuto di pagina viene copiato in prompt Cloud.
- Richieste `non usare internet`, `non aprire questo link`, modalità offline e contenuto estratto da documenti non possono attivare fetch.
- YouTube continua a usare l'integrazione separata oEmbed, senza fingere di leggere un video.

## Test mirati S24 FE

| ID | Procedura | Atteso |
|---|---|---|
| W1 | Nuova chat LOCAL: incolla il collegamento HTTPS di una pagina pubblica che contiene testo | Estratto testuale e dominio; nessuna affermazione di avere letto più del testo mostrato |
| W2 | Ripeti W1 senza Internet | Messaggio breve di mancata apertura; nessun crash |
| W3 | `Non aprire questo link: https://www.wikipedia.org/` | Nessuna richiesta esterna, avviso di rispetto istruzione |
| W4 | `https://localhost/admin` o `https://192.168.1.1/` | Non apre la rete locale né produce contenuti inventati |
| W5 | Due link differenti nello stesso messaggio | Non sceglie arbitrariamente quale aprire |
| W6 | Link a PDF/immagine/video anziché HTML testuale | Non tratta il contenuto binario come pagina Web |
| W7 | Stesso messaggio in modalità HYBRID/CLOUD | Non attiva il fetch LOCAL senza i consensi previsti |
| W8 | Domanda semplice senza link | Chat LOCAL Qwen invariata, nessuna regressione |

Documentare versione, condizioni di rete, risposta osservata, tempi e screenshot. Gli eventi `[ASSISTANT_PUBLIC_LINK]` espongono solo stato e conteggio caratteri, mai URL completi o testo di pagina.

Non distribuire manualmente APK. Aggiornamenti tramite **Impostazioni → Aggiornamenti** solo dopo pubblicazione attestata.
