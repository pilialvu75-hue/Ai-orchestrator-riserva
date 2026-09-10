# Point 1.5 — Cloud access classification

Point 1.5 keeps provider cost and access semantics explicit and provider-neutral.

The catalog distinguishes:

- `recurringFreeTier`: a recurring provider free tier; quotas and rate limits still apply.
- `developmentPrototypeFreeAccess`: free access intended for development/prototyping and not assumed safe for unrestricted production use.
- `accountDependentFreeAccess`: free access that depends on account, region, eligibility, or provider policy.
- `promoCredit`: temporary promotional credit and never treated as a durable free tier.
- `paid`: usage can incur provider charges.
- `unknown`: billing status is unverified and must be treated as spend-sensitive.

Automatic free-first routing remains governed by `CloudProviderCostClass`. Access classification exists so Settings and diagnostics can explain *why* a route is considered free-first without inferring policy from provider names.

Current Point 1.5 free-pool classifications:

- Groq — recurring free tier.
- NVIDIA NIM — development/prototype free access.
- Mistral — account-dependent free access.
- OpenRouter Free Pool — account-dependent free access.

Paid, promotional-credit and unknown routes must never become automatically spend-safe merely because credentials exist.
