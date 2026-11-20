# P0 — NVIDIA large models for Aivexus Web and AI Orchestrator Hybrid

Date: 2026-11-05

**Models:**
- `moonshotai/kimi-k2.6` — 1T total / 32B active, NVIDIA trial endpoint
- `deepseek-ai/deepseek-v4.1-flash` — 552B total / 8B prefill and 16B decode active, NVIDIA trial endpoint

Sources:
- https://docs.api.nvidia.com/nim/reference/moonshotai-kimi-k2-6
- https://docs.api.nvidia.com/nim/reference/nvidia-deepseek-v4_1-flash
- https://build.nvidia.com/deepseek-ai/deepseek-v4.1-flash

**Important:** The paid direct DeepSeek API (`deepseek-flash`) is not
used here. Both routes use NVIDIA's `integrate.api.nvidia.com`
prototype service; this trial is subject to quota/account entitlement
and **not a guarantee of permanent free production inference**.

## AI Orchestrator / Hybrid

- `NvidiaNimLargeModels` provides the IDs for both models.
- Both are optional Cloud Workshop descriptors, with NVIDIA NIM as provider.
- The Cloud/Hybrid settings page offers direct model selection under NVIDIA NIM.
  It saves the chosen model for the existing `nvidiaNim` provider.
- NVIDIA NIM retains the existing encrypted key and provider-specific
  spending/consent checks. Hybrid's personal-memory consent safeguards stay
  unchanged. No new automatic provider activation or Cloud permission occurs.
- The local runtime must not attempt to download or load these 500B+ models.
  Hybrid can still fall back to an installed local model when connectivity
  or provider access fails.
- Both models are selectable, but no multi-model parallel team is activated
  by this metadata integration alone.

## Aivexus Web — separate Cloudflare runtime

Aivexus Web has its own Cloudflare Pages configuration and credentials;
**it must not read AI Orchestrator's private settings or runtime**.

The P0 config workflow can append two routes only to the *Web* orchestration
capability. They share the already-present NVIDIA NIM secret binding and
are marked `manualOnly: true` and `selfTestFree: true`. They will appear
in **☰ → Scelta modello**, and can be tested one at a time with a fixed
synthetic prompt. `AUTO` and the fallback order remain unchanged.

**Protected GitOps sequence** (separate from code merge):
1. Merge a green PR including
   `.github/workflows/web-p0-enroll-large-nim.yml`.
2. Commit
   `.airlab/deploy/large-nim-models-request.json`
   with `operation: read_only`, correct owner confirmation, and both
   exact model IDs.
3. Check the *sanitized* preflight result. It must verify the existing
   encrypted NVIDIA binding, expected endpoint, and absence of conflicting
   routes.
4. If PASS, change the same file to `operation: enable_manual` to append
   two manual-only routes, without touching Nemotron or any secret.
5. Trigger normal **Web Private Deploy**, verify Cloudflare Access remains
   fail-closed, then perform **one user-initiated synthetic test per model**.
6. Record HTTP, routeId, model returned by NVIDIA, elapsed time and result.
   A listed route or an HTTP 200 alone is not a verified usable model.
7. If either route is inaccessible/quota-limited, disable its
   `selfTestFree` flag or revert the added route. Do not switch on automatic
   usage or paid fallback.

Web's existing 15% execution barrier is a separate issue: the server-side
artifact builder is not yet connected. More capable models do not remove it.

## AIVEXUS Studio builder adapter — manual, zero-cost gated (2026-11-20)

The app generator supports an optional opaque `builderRouteId` chosen via
the existing **Scelta modello** menu:

- `nemotron-ultra-orchestrator` → `nvidia/nemotron-3-ultra-550b-a55b`
- `kimi-k26-orchestrator` → `moonshotai/kimi-k2.6`
- `deepseek-v41-flash-orchestrator` → `deepseek-ai/deepseek-v4.1-flash`

**No NVIDIA route is enabled for source generation by merging this code.**
Gemma 4 on Workers AI Free remains the default. Desktop/Android Local,
Cloud and Hybrid are unchanged; manually selected large-model broker routes
remain excluded from AUTO.

All six eligibility conditions must be met:

1. Confirm NVIDIA trial entitlement and monetary cost zero for **full app
   generation**, not only a short synthetic probe; no billable overages.
2. The model/route must match the exact allowlist and NVIDIA trial endpoint
   `https://integrate.api.nvidia.com/v1/chat/completions`.
3. Its server-only `CANTIERE_CLOUD_ROUTES_JSON.orchestration` entry must
   reference an existing encrypted key and have `manualOnly:true`,
   `selfTestFree:true`, and the **separate** `builderFreeVerified:true`.
4. Cloudflare Pages Production must have
   `AIVEXUS_WEB_BUILDER_NIM_FREE_VERIFIED=true` set server-side.
5. The requester must be the **signed Cloudflare Access administrator**
   matched against private `AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT` on the server.
   An unverified admin or tester falls back to the original Gemma builder.
6. `/api/cantiere/models` must confirm `builderAvailable:true` for the
   exact route. The catalogue signals route authorization, not live credit balance.

**NVIDIA API Trial Terms restrict the trial to internal testing and evaluation,
and explicitly prohibit using the trial API service or its generated content
in production without a separate subscription/license** (NVIDIA API Trial
Terms, sections 1.2–1.4, checked 20 Nov 2026). Being the AIVEXUS owner or
having a free account does not override those terms. Until NVIDIA's actual
account-specific entitlement is independently checked, these 500B+ models
must be limited to private experimentation and cannot power the offered
client app-building service or produce customer-delivered artifacts.

**Both new controls are OFF by default.** An operator must independently
verify the specific account's free-trial terms before enabling them. No
provider credentials, URLs or untrusted models enter the Flutter app.

If the route is not approved, the client explicitly informs the user and
uses the preexisting free Cloudflare Gemma builder. A deliberately submitted
but unapproved builder alias is refused by the authenticated endpoint
**before D1 reserves an attempt**. An approved manual trial makes at most
**one NVIDIA inference POST**, with no hidden paid-provider fallback or additional inference attempts. If the provider responds with HTTP 202, the existing bounded status polling may issue GET requests without resubmitting inference.
If a trial expires, immediately turn off one or both server switches.

The original prompt validation, D1 quotas, source checks, verification,
owner isolation and GitHub runner are unchanged. Provenance records the
requested model/provider/route. When the upstream model is not declared,
the receipt says `not_reported_by_provider` instead of falsely attributing
an identity. Selection of an approved trial intentionally skips the
prompt-only verified-project cache, which might contain a Gemma result.

The free Cloudflare Neuron allowance is separate from NVIDIA's preview
credit pool. CI tests use fake NIM responses and make no real API calls.
