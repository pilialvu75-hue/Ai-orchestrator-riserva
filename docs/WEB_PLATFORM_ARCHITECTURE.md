# AI-Orchestrator Web Platform

Status: bootstrap v1

## Goal

Make Web a first-class AI-Orchestrator platform that shares the same application core and product semantics as Android, Windows and macOS while replacing native-only services with browser-safe adapters.

Web must not become a separate fork of the product.

## Shared topology

The platform keeps the existing topology:

```text
Assistant / Cantiere
        |
        v
Module Library <---- Module Researcher
        |
        v
Diagnostics
```

The Web client must consume the same Module Library contracts, Researcher status/evidence and Diagnostics schema as the other platforms. Platform-specific code is limited to runtime, storage, filesystem, updater, voice/audio and browser integration adapters.

## Platform policy

### Available from the first usable Web release

- Shared chat/orchestration UI
- Cloud providers and AUTO routing
- FREE-FIRST / SPEND-SAFE routing rules
- Module Library read path
- Researcher status/evidence exposed through the Module Library layer
- Web-safe Diagnostics pipeline
- Preferences and non-secret local state
- Responsive browser/PWA shell
- Browser-safe attachments where supported

### Capability-gated

The following features must never prevent Web startup:

- llama.cpp / Dart FFI local inference
- native filesystem workspace access
- native process execution / shell tools
- Android background services and intents
- native OTA installer flows
- native voice model runtimes

When a native capability is unavailable, Web must expose an explicit capability state rather than falling back to the wrong desktop/Android implementation.

## Architecture rules

1. No `dart:io` or `dart:ffi` may be reachable from the Web compilation graph.
2. Platform selection must use conditional imports/exports or browser-safe capability contracts, not `Platform.isX` from shared Web-reachable files.
3. The shared core owns behavior and policy; adapters own operating-system/browser mechanics.
4. Cloud credentials and Library credentials must use a Web-safe secret-storage abstraction. No secrets may be compiled into the Web bundle.
5. Diagnostics must keep the existing privacy projection: no conversation text, prompts, provider secrets or tokens.
6. Web storage must preserve the same domain repository contracts used by the rest of the app.
7. Web Cantiere may use Cloud/Library/Researcher before a browser-local model runtime exists.
8. Offline-first on Web means the UI, cached state, project metadata and reusable Library material remain available where the browser storage model allows it. Features requiring network access must fail clearly when offline.

## Known bootstrap blockers on current main

The current repository has no `web/` platform shell yet. Several shared paths directly depend on native APIs, including:

- database initialization (`dart:io`, `sqflite_common_ffi`)
- application shell filesystem/path-provider code
- local runtime provider selection and llama FFI
- native execution engine selection
- GitHub Diagnostics disk queue
- workspace and semantic-index filesystem services
- model and voice download/storage paths

These are adapter-boundary problems, not reasons to fork the product.

## Delivery rings

### Ring W0 — Platform shell

- Add Flutter Web/PWA shell.
- Define Web capability matrix.
- Keep Android/Windows/macOS behavior unchanged.

### Ring W1 — Browser-safe startup

- Split startup/bootstrap from native warmups.
- Add browser-safe platform identity/capability service.
- Prevent local-runtime/database/native-service assumptions from blocking startup.
- Reach the shared application shell in a browser build.

Exit gate: `flutter build web` succeeds in CI.

### Ring W2 — Storage

- Put database/project-memory/chat-history repositories behind a storage abstraction.
- Implement a browser storage backend with durable local persistence.
- Keep repository/domain contracts stable.

Exit gate: conversation/project state survives browser reload and schema migration tests pass.

### Ring W3 — Cloud assistant

- Enable Cloud and AUTO routes on Web.
- Preserve provider participation switches, FREE-FIRST and SPEND-SAFE policy.
- Make Local mode visibly unavailable until a Web local runtime is certified.

Exit gate: Web chat completes real provider requests without embedding secrets in the bundle.

### Ring W4 — Library + Researcher

- Reuse the existing Module Library contracts.
- Reuse Researcher status/evidence through the Library integration.
- Add browser-safe GitHub authorization/storage where required.
- Keep consumption verification and reuse policy identical across platforms.

Exit gate: Web can read Library catalog/needs and display Researcher state using the same domain projection as native platforms.

### Ring W5 — Diagnostics

- Split Diagnostics persistence/queue from its transport/projection policy.
- Implement browser-safe durable queue.
- Preserve public-log projection and bounded retention.
- Tag platform as Web while keeping the same diagnostics repository.

Exit gate: opt-in Web diagnostics reach `Ai-orchestrator-diagnostics` without user content or secrets.

### Ring W6 — Web Cantiere

- Enable Cantiere with Cloud + Module Library + Researcher first.
- Browser-incompatible native tools report explicit unavailable capability states.
- Add browser-compatible workspace/import/export flows.

Exit gate: a project can be planned and assembled from reusable modules from the Web client without requiring native FFI.

### Ring W7 — Offline/PWA hardening

- Cache application shell and safe static assets.
- Define offline behavior for Library cache and project data.
- Add installable PWA metadata/icons.
- Add update/reload policy appropriate to service-worker deployments.

Exit gate: installed PWA launches offline with local state intact and reconnects cleanly.

### Ring W8 — Optional browser-local AI

Evaluate only after the Web platform is stable. Possible browser-local runtimes must be treated as separate providers/capabilities and must meet memory, performance, privacy and compatibility gates before AUTO can select them.

## CI gates

Before Web work merges to `main`:

- Existing Android gate remains green.
- Existing Windows gate remains green.
- Web compile/test gate is added once W1 reaches browser-safe compilation.
- Cross-platform changes require regression tests proving native behavior did not change.

## Non-goals for bootstrap

- Rewriting AI-Orchestrator as a JavaScript application.
- Duplicating the Module Library, Researcher or Diagnostics projects.
- Shipping native API keys in browser assets.
- Pretending FFI/local-model features exist when the browser cannot provide them.
- Blocking the useful Cloud/Web experience on future browser-local inference work.
