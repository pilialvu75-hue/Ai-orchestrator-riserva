# Cantiere Web — W4 Cloud/AUTO broker

W4 adds a browser-safe inference path for the four Cantiere roles without
putting provider credentials or upstream routing policy in the Flutter bundle.

## Browser contract

The browser sends only a logical capability:

- `orchestration`
- `architecture_reasoning`
- `coding`
- `review`

`WorkshopWebCloudRolePolicy` maps the existing Cantiere roles to those
capabilities. `WorkshopWebCloudRuntimeProvider` implements the existing
`RuntimeInferenceProvider` contract, so the normal
`WorkshopInferenceGateway -> WorkshopStageRoleInference` stack can be reused.

The browser does **not** send a provider id, API key, upstream URL or concrete
model. Explicit offline requests fail closed before network access.

## Server-side AUTO routing

The same-origin Cloudflare Pages Function reads
`CANTIERE_CLOUD_ROUTES_JSON`. Each capability contains an ordered list of
OpenAI-compatible routes, for example:

```json
{
  "coding": [
    {
      "id": "coding-primary",
      "endpoint": "https://example-provider.invalid/v1/chat/completions",
      "model": "provider-model-name",
      "apiKeySecret": "CANTIERE_CODING_API_KEY"
    }
  ]
}
```

This JSON is server-side configuration, not a Flutter asset. The named key
itself must be stored as a Cloudflare Pages secret. Multiple rows provide AUTO
fallback without changing browser code.

The broker accepts HTTPS routes only, validates a fixed capability allow-list,
bounds message count/size and generation parameters, uses an 80-second upstream
abort window, and never returns raw upstream error bodies.

## Health

`GET /api/cantiere/capabilities` returns only the configured capability names.
The Web shell marks Cloud/AUTO available only when all four Cantiere
capabilities are configured. No endpoint, model routing table or secret is
returned by the health endpoint.

## Self-Test Cloud sintetico (solo su richiesta)

La scheda Web **Stato → Cloud / AUTO** propone il pulsante
**Esegui Self-Test Cloud**. Esegue una vera inferenza tramite
`POST /api/cantiere/inference`, ma senza modificare progetti o conversazioni.
Il browser invia esclusivamente
`{"version":1,"capability":"orchestration","selfTest":true}`.

La Pages Function sostituisce il prompt con un testo sintetico e fisso,
usa un budget massimo di 512 token e verifica che un provider risponda.
La risposta espone lo stato HTTP, il tempo osservato, il provider dedotto
dall'hostname della rotta, il modello configurato, il modello dichiarato
dall'upstream e l'identificativo della rotta. Il test risulta **Passed**
solo quando il testo finale corrisponde al marcatore richiesto ed è
possibile attribuire provider, modello dichiarato e rotta. L'indicazione
Cloud/AUTO Available resta una semplice verifica dei binding, non un
collaudo dell'inferenza.

**Protezione dei costi:** nessuna rotta esistente è eleggibile di default.
Il responsabile Web deve prima accertare indipendentemente che una rotta sia
autorizzata a costo monetario zero e impostare su quella sola rotta
`"selfTestFree": true` in `CANTIERE_CLOUD_ROUTES_JSON`, lato Cloudflare.
Non utilizzare rotte con crediti a consumo, modelli dal costo sconosciuto
o API non verificate. Il repository non contiene credenziali. Se manca
una rotta marcata, l'endpoint risponde
`503 self_test_not_configured` **senza contattare alcun provider**.
La modifica in produzione richiede approvazione separata, non viene
effettuata dalla PR. Il flag è una dichiarazione di configurazione
dell'operatore, non una garanzia automatica di gratuità del provider.

La rotta di test è limitata alla capacità `orchestration`; questa è la
prima capacità utilizzata nella preparazione delle proposte. Non sono
consentiti prompt arbitrari, invii di dati personali, cambi del provider
dal browser o avvio automatico del test. Le rotte non marcate restano
disponibili per il funzionamento ordinario del Cantiere, ma non per il test.

## Generazione sorgenti Web

La Pages Function `POST /api/cantiere/proposals/generate` applica il gate
Access/D1 del Cantiere. Accetta `generationId` (UUID v4) e `prompt`. Il retry
dello stesso identificativo con lo stesso prompt restituisce lo stato o la
ricevuta precedente. `GET` sullo stesso percorso con `generationId` restituisce
la ricevuta del proprietario senza richiedere di nuovo il prompt. Il browser
conserva l'identificativo dell'ultima richiesta nelle preferenze Web. L'identità
è ricavata dall'asserzione Access e D1 conserva
spec, sorgenti, digest e provenienza del modello sotto quella identità. Una
generazione interrotta resta identificabile senza avviare un secondo job.

Per abilitare nuove generazioni serve la migrazione `006`, il piano Workers Free
verificato dall'operatore, `AIVEXUS_WEB_BUILDER_FREE_ENABLED=true` e il binding
Pages Workers AI `AIVEXUS_WEB_BUILDER_AI`. Il generatore richiama il modello
`@cf/google/gemma-4-26b-a4b-it` tramite il binding. D1 ammette sei tentativi per
identità e 24 complessivi in 24 ore, inclusi gli esiti falliti. AUTO e il
catalogo diagnostico continuano a usare le proprie configurazioni.
Lo stato `generated` conferma il salvataggio dei sorgenti. Test, anteprima ed
esportazione appartengono ai passaggi successivi.

## Collaudo isolato dei sorgenti

Il coordinatore Node `runWebApplicationVerification` riceve il sorgente e un
piano di verifica attendibile con azioni `click`, `fill` e `text`. Il piano
resta invariato durante la riparazione. Chromium usa un profilo temporaneo,
il sandbox del browser e una policy che permette soltanto le risorse del
progetto servite via DevTools. Il processo del browser riceve un ambiente
ristretto, senza i segreti del broker. Le prove verificano gli errori JavaScript
e il comportamento reale del DOM.

Un errore del codice permette al massimo tre correzioni attraverso la rotta
dedicata del broker. Un guasto d’infrastruttura interrompe il ciclo. Dopo una
prova riuscita, lo ZIP viene riaperto e ogni file viene verificato prima della
consegna al chiamante. Il coordinatore è un modulo Node. La Pages Function
salva la generazione e la ricevuta, mentre il collegamento al runner isolato
richiede il trasporto autenticato del progetto e del risultato.

Per abilitare la riparazione nel runner occorrono il flag gratuito, l’ID account
`CLOUDFLARE_ACCOUNT_ID` già usato dal deploy privato e il segreto Actions
`AIVEXUS_BUILDER_WORKERS_AI_TOKEN`, limitato a Workers AI sullo stesso account
Free. Il coordinatore invia le richieste al solo endpoint Cloudflare di
quell’account, con lo stesso modello della generazione. Chromium riceve soltanto
il sorgente e i controlli da eseguire. Pages può riusare il token GitHub del
contatore per il dispatch, con gli stessi permessi Actions sul medesimo repository.

Il workflow `web-application-runner.yml` è riservato al primo tentativo su
`main` e all'attore GitHub configurato dall'operatore. Riceve un ticket e un
pacchetto cifrato e autenticato. La chiave privata del runner apre il job. Una
seconda coppia di chiavi consente solo a Pages di aprire il risultato. L'HMAC
distingue job e risultati. La risposta include il digest del job originale.
Il job scade dopo 15 minuti e il campo cifrato è limitato a 61.000 caratteri.
Un sorgente che supera i limiti della compressione deve essere rifiutato prima
del dispatch. L'artefatto GitHub contiene soltanto `application.aivexus`
cifrato e scade dopo un giorno.

Il client accetta l'artefatto solo dopo aver verificato repository, workflow,
commit, tentativo e digest. Il ticket e gli ID GitHub sono interni. La
migrazione `007` registra un solo dispatch per generazione e proprietario.
`POST /api/cantiere/proposals/verify` avvia la verifica o recupera un risultato
concluso. `GET` sullo stesso percorso è in sola lettura. Le generazioni più
vecchie senza controlli propongono lo stato `checks_missing`.

Pages conserva ricevuta, sorgente verificato e ZIP nel D1 del prodotto con
un’unica scrittura. `GET /api/cantiere/proposals/download?generationId=…`
verifica di nuovo il digest dello ZIP e serve il file solo al proprietario.
I binding di produzione del runner e le chiavi richiedono la configurazione
autorizzata. Il codice di un progetto viene eseguito in Chromium, nel runner.

## Sorgenti e anteprima

`GET /api/cantiere/proposals/source` e `GET /api/cantiere/proposals/preview`
accettano `generationId` e leggono lo snapshot verificato del proprietario. Il
server confronta il digest dello snapshot con la ricevuta a ogni lettura. La
schermata Flutter visualizza i file come testo. L’anteprima usa un iframe con
origine opaca, `sandbox allow-scripts` e una CSP senza accesso a fetch, form o
frame esterni. JavaScript e CSS locali referenziati dall’entry point sono
incorporati nel documento. Gli import relativi all’interno di un modulo
JavaScript, i percorsi verso altre pagine e le risorse esterne restano fuori
dal percorso di anteprima. Lo ZIP conserva tutti i file verificati.

## Modifiche e versioni

La migrazione `008` associa le revisioni allo stesso progetto e conserva
la versione scelta dal proprietario. Le generazioni esistenti restano radici
di progetto valide. `POST /api/cantiere/proposals/revisions` riceve un nuovo
`generationId`, la versione verificata `baseGenerationId` e `instruction`.
L’operazione applica solo i file cambiati o rimossi che il modello dichiara,
mantiene i controlli di base e può aggiungere nuovi controlli. La nuova
versione usa il percorso di verifica e ZIP delle altre generazioni.

`GET /api/cantiere/proposals/revisions?generationId=…` restituisce la
cronologia dello stesso progetto. `POST /api/cantiere/proposals/select-revision`
con `generationId` seleziona una versione già verificata senza sovrascrivere i
file di alcuna versione. I controlli di proprietà valgono su cronologia,
modifiche e ripristino. Lo storico conserva il testo delle modifiche.

## Security and sequencing

Cloudflare Access from W2 remains the outer authentication boundary. W4 does
not introduce a general Assistant surface, browser-held provider key, native
local runtime, PWA behavior, Library/Researcher transport or Diagnostics
transport.

The first W4 implementation is non-streaming at the broker boundary: the
existing runtime stream emits one final successful chunk. Streaming/abort
hardening can be added later without changing the role/capability contract.
