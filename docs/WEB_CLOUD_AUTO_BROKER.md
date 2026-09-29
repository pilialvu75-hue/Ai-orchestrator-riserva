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

## Security and sequencing

Cloudflare Access from W2 remains the outer authentication boundary. W4 does
not introduce a general Assistant surface, browser-held provider key, native
local runtime, PWA behavior, Library/Researcher transport or Diagnostics
transport.

The first W4 implementation is non-streaming at the broker boundary: the
existing runtime stream emits one final successful chunk. Streaming/abort
hardening can be added later without changing the role/capability contract.
