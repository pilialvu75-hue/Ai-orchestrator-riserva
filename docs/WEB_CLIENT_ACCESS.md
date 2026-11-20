# AIVEXUS Studio — clienti invitati, proprietario già esistente

## Obiettivo
L'owner continua a usare il proprio Cloudflare Access già attivo. Non viene creato un secondo amministratore. L'accesso clienti è differente da Beta Access (attualmente pilota WEmulDroid) e usa solo le API AIVEXUS Web.

## Flusso implementato nel codice
1. L'owner autenticato apre `☰ → Accessi clienti`.
2. Inserisce l'email del destinatario e una validità da 1 a 30 giorni. Il server crea in D1 un invito `pending` con ID UUID, owner subject e scadenza. Al massimo 100 inviti attivi per owner; l'email non può avere due inviti validi simultanei.
3. L'owner copia un link HTTPS del tipo `https://aivexus.pages.dev/?invite=<id>` e lo condivide manualmente. Non c'è invio email automatizzato.
4. **Separatamente**, l'amministratore Cloudflare Access autorizza *solo quella email* nella policy privata del sito. Non bisogna disattivare Access, consentire tutti gli utenti o inserire i clienti nel gruppo owner.
5. Il cliente raggiunge il link, supera Cloudflare Access con **la stessa email** e preme `Accetta invito`. Il server verifica firma/issuer/audience/exp del JWT e confronta la claim email con quella dell'invito. Il solo link non autorizza nulla.
6. L'accettazione è atomica e una sola volta: l'ID Access firmato viene legato all'invito. Il cliente ottiene esclusivamente il ruolo `client` e può creare, verificare e scaricare **i propri** progetti secondo le quote standard, **solo dopo l'attivazione della modalità clienti**.
7. L'owner può revocare l'invito anche dopo accettazione. Le operazioni protette controllano la validità a ogni nuova richiesta. Scadenza e revoca negano la successiva richiesta.

## Controlli di disponibilità e sicurezza
- **La nuova migrazione `008_web_client_invitations.sql` è obbligatoria nel D1 di produzione.** Testarla prima su D1 locale/isolato, verificare schema e backup, poi applicarla in modo mirato. Il test automatico di CI non equivale a una migrazione già applicata sul D1 online.
- Variabile lato Pages Production: `AIVEXUS_WEB_CLIENT_ACCESS_ENABLED=true` **solo dopo** D1 008, verifica proprietario, policy Cloudflare Access privata e collaudi end-to-end del primo cliente; è **OFF per default**.
- Quando il flag è attivo, gli endpoint di progetto/approvazione/generazione/preview/download richiedono owner o grant cliente D1 ancora valido. Nessuna operazione legge dati di un altro subject.
- Il broker inferenza non è aperto ai clienti: niente utilizzo diretto dei provider, dei crediti NVIDIA NIM 500B+ o dei trial. La creazione app tramite l'endpoint generatore conserva quota utente ordinaria 10/24h e tetto globale 72/24h.
- Il catalogo di modelli può restare leggibile ma non conferisce permessi all'upstream. I modelli di prova NVIDIA sono solo per sviluppo interno dell'owner nei limiti dei termini/credito gratuito verificato.
- Invito `pending` e `accepted` sono stati client-side/server-side **preparati**, non significa che Access policy sia già configurata.
- La policy esterna deve rimanere fail-closed anche se un utente copia il link. Le email degli inviti sono PII salvata nel D1 e vanno trattate con accessi minimizzati, senza log o esposizione pubblica.
- **Non** attivare il flag clienti prima di avere configurato l'owner: un owner non riconosciuto potrebbe essere bloccato, mentre aprire prima la policy Cloudflare potrebbe dare Access a utenti senza grant.

## Limiti iniziali espliciti
- Solo inviti per email verificata da Cloudflare Access, nessun autosignup pubblico, OTP separato, abbonamento, fatturazione o automazione email.
- Chat di inferenza diretta del Cantiere non inclusa nei permessi clienti per ora: prima definire un contatore/budget persistente separato.
- Le policy Cloudflare Access e i token non vengono modificati dal codice; nessun invito cambia Cloudflare autonomamente.
- Beta Access non è automaticamente connesso al login AIVEXUS Studio; riusare concetti e controlli, non i privilegi di amministrazione.
- Prima dell'apertura reale occorre collaudare un invito a un account distinto, il rifiuto di un'email diversa, la scadenza, la revoca e l'isolamento progetti sul sito online.

## Test già automatizzati
- Node SQLite/D1: create/list/claim/revoke con Access JWT firmato, email falsificata, 404 su replay, owner non falsificabile, scadenza e revoca bloccano il successivo `GET quota`.
- Flutter: gestione pannello owner, creazione/revoca invito, accettazione client senza attivazione pubblica.
- GitHub `Aivexus Web Authenticated D1 Operation Gate`: nuova migrazione #008 e quattro route Pages Access; build Web/Chrome isolato.

**Questa release è una base di onboarding privato**; il primo collaudo cliente online e la migrazione D1 Production sono passaggi espliciti successivi.