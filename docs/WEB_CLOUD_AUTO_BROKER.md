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

## Security and sequencing

Cloudflare Access from W2 remains the outer authentication boundary. W4 does
not introduce a general Assistant surface, browser-held provider key, native
local runtime, PWA behavior, Library/Researcher transport or Diagnostics
transport.

The first W4 implementation is non-streaming at the broker boundary: the
existing runtime stream emits one final successful chunk. Streaming/abort
hardening can be added later without changing the role/capability contract.
