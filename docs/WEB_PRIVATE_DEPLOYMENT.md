# Cantiere Web — W2 private deployment

W2 keeps the ordinary Flutter Web application private during development and
stabilization. It uses a root Cloudflare Pages Function as an authentication
gate; the Flutter bundle itself contains no credential.

## Security boundary

Every route is included in `web/_routes.json`, so HTML and static assets pass
through `functions/_middleware.js`.

The middleware:

- fails closed with HTTP 503 when its access secrets are missing;
- requires HTTP Basic authentication over Cloudflare HTTPS;
- compares SHA-256 digests rather than plain credential strings;
- returns HTTP 401 for missing/invalid credentials;
- applies no-store to HTML and defensive browser headers;
- never embeds the username/password in Flutter assets.

This is a temporary private-development gate. A future Cloudflare Access policy
may replace the Basic-auth front door without changing Cantiere application
contracts.

## One-time Cloudflare Pages setup

Create a Pages project, then configure the GitHub environment
`cantiere-web-private` with:

Repository/environment variables:

- `CLOUDFLARE_PAGES_PROJECT`: Pages project name.
- `CLOUDFLARE_PAGES_URL`: canonical `https://<project>.pages.dev` URL used by
  the post-deploy gate tests.

Environment secrets:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN` with the minimum Pages deployment/secret permissions
- `WEB_ACCESS_USER`
- `WEB_ACCESS_PASSWORD` (use a long unique password)

The deployment workflow updates the two access secrets in Cloudflare before
uploading `build/web`.

## Deployment gate

Run **Web Private Deploy** manually. A deployment is accepted only when:

1. the ordinary W1 Web build succeeds;
2. `_routes.json` is present in the built output;
3. the root and a static asset both return 401 without credentials;
4. the same requests both return 200 with the configured credentials.

If the secret configuration is missing, the middleware intentionally serves no
application content.

W2 does not add PWA/installable/offline-first behavior. That remains W9.
