# Cantiere Web private deployment — W2

Status: implementation contract for Ring W2.

## Goal

The ordinary Cantiere Web build from W1 may be deployed only when both the
production `<project>.pages.dev` hostname and Pages preview hostnames are
already protected by Cloudflare Access.

The deployment workflow is intentionally manual. A Git push must never publish
the private Web product automatically during development/stabilization.

## Two-phase bootstrap and deployment

The manual **Web Private Deploy** workflow has two operations:

1. `bootstrap_pages` creates the empty Cloudflare Pages project if it does not
   already exist. It never builds or uploads the Cantiere Web application.
2. `deploy_private` proves Cloudflare Access is fail-closed, then builds and
   uploads the private Web application.

This split allows the Pages project to be created from GitHub Actions without
using the Cloudflare dashboard for project creation, while preserving the rule
that no real application assets are uploaded before Access is active.

### Bootstrap confirmation

Run the workflow with:

- operation: `bootstrap_pages`
- confirmation: `BOOTSTRAP_EMPTY_PAGES`

The bootstrap is idempotent: if the configured project already exists, the job
exits successfully without changing or deploying it.

## Cloudflare setup prerequisite

Before the first real application deployment:

1. Run `bootstrap_pages` to create the Cloudflare Pages project without
   uploading the Cantiere build.
2. In Workers & Pages / Zero Trust, enable an Access policy for the Pages
   project.
3. Configure the Pages Access application so the production
   `<project>.pages.dev` hostname is protected.
4. Re-enable/keep the preview Access application for
   `*.<project>.pages.dev` so immutable and branch preview URLs are protected.
5. Configure an Allow policy containing only the intended authenticated user(s).
   Access is deny-by-default for users who do not match an Allow policy.
6. Do not add provider keys, GitHub tokens, model credentials or user identity
   values to source code.

The deploy operation probes both the production hostname and an unused
preview-style hostname before uploading real assets. Both must redirect to a
Cloudflare Access login boundary. A public 200/404 response fails the deployment
before the Cantiere build is uploaded.

## GitHub configuration

Repository **secrets**:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN` — scoped to the minimum Pages permissions needed for
  this project.

Repository **variable**:

- `CLOUDFLARE_PAGES_PROJECT` — the Pages project name only; it is not a secret.

The workflow uses GitHub's built-in `GITHUB_TOKEN` only for deployment
metadata. No Cloudflare credential is passed to the Flutter build.

## Deployment

After Access is configured, run **Web Private Deploy** manually with:

- operation: `deploy_private`
- confirmation: `DEPLOY_PRIVATE_CANTIERE`

The deploy job:

1. fails unless the Cloudflare configuration values exist;
2. proves Access blocks the production and wildcard-preview hostnames;
3. runs the W1 focused tests and ordinary Flutter Web build;
4. verifies no PWA manifest has been introduced;
5. deploys `build/web` with the official Cloudflare Wrangler action;
6. verifies the returned immutable deployment URL is also Access-protected.

A deployment is not considered W2-complete merely because Wrangler reports
success. The post-deploy Access check must also pass.

## Security boundary

Cloudflare Access is the W2 authentication boundary. The Flutter bundle does
not contain a client-side password screen, API token, allow-list or provider
credential. Client-side checks are not treated as access control.

`web/_headers` adds no-indexing and basic browser hardening, but those headers
are defense-in-depth only and do not replace Access.

W2 does not add Cloud/AUTO provider brokering, durable storage, Library,
Researcher or Diagnostics transport. Those remain later rings.
