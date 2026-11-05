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
