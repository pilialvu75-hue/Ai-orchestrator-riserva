# AIVEXUS Web — fase privata: unico amministratore (20 novembre 2026)

## Decisione del proprietario

Il servizio clienti è accantonato. AIVEXUS Studio rimane **privato e riservato all'identità proprietaria già esistente in Cloudflare Access**. Nessun secondo amministratore, registrazione clienti, approvazione di nuovi tester o invito sono richiesti.

Il riconoscimento dell'owner continua a richiedere un JWT Cloudflare Access con firma, audience, issuer e validità verificati; `AIVEXUS_WEB_OWNER_EMAIL` e, in assenza di quest'ultimo, `AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT` sono configurazioni *private del server*. Non attribuire diritti amministrativi in base a email/ruolo inviato via browser.

## Privilegi attivi nel codice

- Owner unico: generazione applicazioni, Cantiere, verifica, anteprima, download ZIP, accesso ai progetti propri, approvazione/revoca, esecuzioni e inferenza Cloud configurata.
- Quota personale admin: **72 tentativi generazione / 24 ore**, pari all'intero tetto globale attuale di 72; prima erano 64. Non viene simulata capacità di calcolo aggiuntiva. Una chiamata AI può comunque essere respinta per esaurimento dei Neurons Workers Free e il tetto generale continua a tutelare da costi e abusi.
- I modelli NVIDIA NIM >500B sono utilizzabili solo dopo le verifiche separate di credito realmente gratuito, termini applicabili alla sperimentazione privata, binding dei segreti e i doppi flag di approvazione server. **La qualifica di amministratore da sola non dà crediti NVIDIA** e non legittima uso commerciale dei trial.
- Il broker IA richiede il login owner verificato PRIMA di trasmettere prompt a provider. Le altre API D1 Web passano `ownerOnly: true` al gate e rifiutano identità non proprietarie indipendentemente dal vecchio flag clienti.

## Servizio clienti sospeso

- Le API di creazione, accettazione, revoca e lista inviti rispondono `403 client_service_paused` dopo verifica Access. `/api/cantiere/access/status` resta read-only per indicare al proprietario la sessione owner e `customerService: paused`, senza consultare il database inviti.
- Il menu **Accessi clienti** e l'apertura automatica dei vecchi link `?invite=` vengono nascosti dal Web; i dati D1 non vengono eliminati, così non si perde il lavoro fatto.
- Il precedente `AIVEXUS_WEB_CLIENT_ACCESS_ENABLED` non può riattivare gli endpoint del Cantiere: le funzioni Pages impongono `ownerOnly: true` e `clientAccessEnabled: false`. Per tornare ai clienti servirà una decisione esplicita, modifica revisionata e un collaudo dell'accesso.
- Cloudflare Access esterno deve continuare a proteggere tutti gli hostname di produzione e preview. Non disattivare Access, non condividere il JWT, non creare un nuovo owner e non pubblicare le chiavi.

## Verifiche operative e rilascio

La CI GitHub valida i privilegi simulati e i contratti. **Un merge in main non dimostra che Cloudflare Pages sia aggiornato**; il deploy privato e la corrispondenza fra l'account proprietario e i binding Access devono essere verificati separatamente. Se il binding owner manca, il codice deve rifiutare l'accesso, non regalare permessi a chiunque.

Per zero costi: niente piani a pagamento, automatismi di acquisto, billing upgrade o fallback verso provider paganti. L'amministratore ha tutte le *funzioni applicative attualmente disponibili*; quote reali, licenze e limiti di sicurezza non sono privilegi aggirabili.
