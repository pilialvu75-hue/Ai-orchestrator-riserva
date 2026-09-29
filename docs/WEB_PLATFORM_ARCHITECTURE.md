# AI-Orchestrator Web Platform

Status: W1 merged; W3 durable-storage implementation

## Product boundary

The first Web product is **Cantiere only**. It is not a browser edition of the
general Assistant.

The Web platform shares Cantiere domain contracts with Android/desktop while
browser mechanics remain behind Web-specific adapters.

## Sequencing

1. W1 browser-safe startup and ordinary Web build.
2. W2 private authenticated deployment.
3. W3 durable browser storage.
4. W4 Cantiere Cloud/AUTO execution.
5. W5 Module Library + Researcher parity.
6. W6 browser-safe Diagnostics queue/transport.
7. W7 complete Cantiere workflow, reuse/import/export.
8. W8 stabilization and real browser/mobile validation.
9. W9 PWA/installable/offline-first browser behavior.
10. W10 optional browser-local inference evaluation.

W1 intentionally has **no Web manifest/service-worker product work**. PWA work
must not be pulled forward.

## W1 compilation boundary

The Web entrypoint is `lib/web_main.dart`.

Its reachable product graph is deliberately small:

```
web_main.dart
  -> WorkshopWebShell
      -> shared workshop_contract.dart
      -> Flutter UI
```

It does not import the native application bootstrap or general Assistant
composition. Consequently these native capabilities cannot block W1 startup:

- llama.cpp / Dart FFI
- process/shell execution
- native filesystem workspace
- native database bootstrap
- native voice runtimes
- native updater/installers
- Android intents/background services

Unavailable native capabilities are shown explicitly rather than being mapped
to another platform.

## Security

- no provider or GitHub secret is compiled into the W1 bundle;
- no general Assistant UI is reachable;
- no prompt/conversation data is emitted by the W1 shell;
- future provider calls must use an appropriate server-side broker when a
  browser-held credential would be unsafe;
- private authenticated hosting is a separate W2 gate.

## W1 CI exit gate

`flutter build web --release --target lib/web_main.dart` is mandatory in the
Web workflow together with the focused Web shell tests.

Android/Windows/Linux/macOS CI remains unchanged.


## W3 durable browser storage

W3 reuses the existing `WorkshopCheckpointStore` and
`PersistentWorkshopCheckpointStore`; it does not create a Web-only project
persistence model.

To keep the browser dependency graph clean, the checkpoint data model,
interface and in-memory implementation live in
`workshop_checkpoint_store.dart`, which has no dependency on
`WorkshopEngine`, Flutter UI, native filesystem/process execution or runtime
providers. `workshop_background_service.dart` re-exports that contract for
source compatibility with existing native callers.

The Web adapter opens the existing persistent store through
`PreferencesService` + `shared_preferences`. On Web this is provided by the
federated browser implementation. A failure to open/read persistence is shown
as unavailable; Cantiere Web must not silently fall back to volatile storage.

This persistence is durable for the current browser/profile only. It is not a
credential vault, cloud authority or multi-device synchronization layer;
provider/GitHub/Cloudflare secrets must never be written through this adapter.

CI runs the storage adapter test both on the VM and in Chrome, then still
requires the ordinary `flutter build web --release --target lib/web_main.dart`
gate. W3 does not add PWA/offline-first behavior; durable browser state and PWA
installation are separate concerns.
