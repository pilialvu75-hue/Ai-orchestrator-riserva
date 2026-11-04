# Aivexus Web — Cloud tools menu (P0)

The private Web header exposes a hamburger menu with **Status**, **Workshop**,
**Self-Test Cloud**, **Model selection** and **Diagnostics**, localized in
Italian, French, English and Spanish. This is a feature of the standalone Web
application, independent of AI Orchestrator's runtime and configuration.

## Why the 503 on 4 November is useful

The initial Self-Test returned HTTP 503 in 47 ms with
`self_test_not_configured`. The Pages Function rejects the probe before any
provider call because **no route is explicitly marked `selfTestFree: true`**.
This is not a Nemotron inference failure and does not prove a credential is
accepted or rejected. Cloud/AUTO Available still checks configured bindings
only.

## Server-side diagnostic model list

The new authenticated `GET /api/cantiere/models` returns a bounded,
sanitized view of the **orchestration** routes already defined in the
Cloudflare runtime variable `CANTIERE_CLOUD_ROUTES_JSON`: route alias,
provider label, model name, presence of the binding, explicit zero-cost test
approval and eligibility for manual selection.

The endpoint never returns endpoint URLs, secret names, tokens, cookies,
authorization headers or secret values. The server may list a configured
model even when no binding exists; that **does not** mean the credential is
valid or that the model can answer.

## AUTO and manual choice

- AUTO remains the default and retains the existing server-side fallback
  for ordinary project requests.
- Manual choice stores only the **route alias** in browser preferences,
  not the model name or credential. The server checks the alias against its
  actual configured routes **on every request**.
- Manual choice is enabled only for a route with a present binding and
  explicit `selfTestFree: true`. Unknown routes and unapproved routes are
  rejected; there is no automatic fallback from a manually selected route
  to a different or paid route.
- The Self-Test uses a fixed synthetic prompt and the same eligible route
  rules. No user project data is sent.
- Selecting a route does not update provider configurations or secrets.

## Production prerequisites

This PR intentionally does **not** change Cloudflare Access, provider
configuration, environment bindings or production deployment. A designated
operator must first verify through an authorized provider channel that a
specific route can be tested with **zero monetary cost**, then request
approval before adding `"selfTestFree": true` to that one route's
`orchestration` configuration. Do not paste the route JSON or secrets in a
chat. Roll back the configuration field if the approved test is not free.

## Acceptance tests

1. Anonymous access is still rejected by Cloudflare Access.
2. The hamburger opens on mobile/desktop; all four languages show labels.
3. The model list reflects only configured routes, including binding and
   free-test eligibility.
4. Without a free route, Self-Test stays unavailable with an explicit
   configuration explanation and performs no inference.
5. When an approved free route is configured, test and manual selection
   return provider/model/route attribution, HTTP and elapsed time.
6. Returning to AUTO restores normal server-owned fallback.
7. Existing projects remain preserved and independent from AI Orchestrator.
