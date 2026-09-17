# Point 1.5 — Cloud access classification

Point 1.5 keeps provider cost and access semantics explicit and provider-neutral.

The catalog distinguishes:

- `recurringFreeTier`: a recurring provider free tier; quotas and rate limits still apply.
- `developmentPrototypeFreeAccess`: free access intended for development/prototyping and not assumed safe for unrestricted production use.
- `accountDependentFreeAccess`: free access that depends on account, region, eligibility, plan, or provider policy.
- `promoCredit`: temporary promotional credit and never treated as a durable free tier.
- `paid`: usage can incur provider charges.
- `unknown`: billing status is unverified and must be treated as spend-sensitive.

Automatic free-first routing combines access classification, cost classification, explicit AUTO participation and the spending policy. Only a `recurringFreeTier` with `freeTier` cost is spend-safe by classification alone. Development/prototype and account-dependent free access fail closed for AUTO until the user explicitly opts the provider in. Promotional-credit and unknown access also default out of AUTO; paid routes remain governed by the configured spending policy.

Current Point 1.5 free-pool classifications:

- Groq — account-dependent free access. Groq accounts can use a Free plan or a pay-as-you-go Developer plan, so the provider name alone does not prove that the next request is free.
- NVIDIA NIM — development/prototype free access.
- Mistral — account-dependent free access.
- OpenRouter Free Pool — recurring free tier.

Credentials alone never make a conditional, paid, promotional-credit, or unknown route automatically spend-safe. Existing explicit AUTO choices are preserved; a provider without a stored choice uses the fail-closed default appropriate to its access class.
