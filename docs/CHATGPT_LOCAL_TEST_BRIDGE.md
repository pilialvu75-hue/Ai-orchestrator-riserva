# AIVEXUS ↔ ChatGPT Desktop local test bridge (experimental)

**State (2026-11-17): the internal Windows QA build was tested on the actual ASUS.**
A device-side PowerShell MCP `instance_info` call returned a real AIVEXUS
v1.0.16.16 process, and an authenticated runtime self-test completed with
`success: true` (`generated_text: OK`, `elapsed_ms: 11464`). The local
AIVEXUS ↔ MCP connection is **verified**. The MCP tools were **not** exposed
to an ordinary ChatGPT Desktop chat; end-to-end ChatGPT-chat invocation is
**not yet verified**. This remains a feature-branch internal QA experiment,
not a general release. CI protocol tests additionally use synthetic stubs.

## Purpose and non-goals

This is a narrow, opt-in test transport, not a new inference engine. The MCP
process forwards a restricted set of JSON-RPC tools to the actual running
Flutter AIVEXUS process over an authenticated loopback HTTP server. The app
server delegates a runtime test to the EXISTING RuntimeSelfTestService and uses
the EXISTING selected-model and diagnostics services for status metadata.

It does **not** expose a terminal, run arbitrary commands, read user chats,
export raw log files, list files, alter Windows protections, call Cloud APIs,
or start AIVEXUS when the app is not running.

AIVEXUS Cantiere Web is a separate browser product and is NOT treated as the
same instance. A ChatGPT Desktop installation is the *control host*; Windows is
the *AIVEXUS execution host* in the first experiment.

## Components

- `scripts/chatgpt_bridge/aivexus_mcp.ps1`: preferred stdio MCP adapter
  using native Windows PowerShell (no Python installation). It does not
  modify PowerShell execution policy or Windows security protections.
- `scripts/chatgpt_bridge/aivexus_mcp.py`: alternative stdio MCP adapter
  using Python 3's standard library; also used by synthetic CI tests.
  Both adapters use only fixed `127.0.0.1:47941` endpoints.
- `lib/core/diagnostics/chatgpt_bridge/aivexus_test_bridge_server.dart`:
  authenticated loopback listener inside the existing AIVEXUS app.
- `lib/core/diagnostics/chatgpt_bridge/aivexus_bridge_controller.dart`:
  on-device opt-in using OS-protected secret storage, rotation and revocation.
- `lib/features/settings/presentation/pages/modules/chatgpt_bridge_settings_page.dart`:
  guided activation from inside the existing AIVEXUS Settings page.
- `lib/app/runtime_bootstrap.dart`: exposes the bridge **only** on Windows
  with the explicit internal compile-time switch. It starts only after the
  first user opt-in; a previously enabled pairing is restored on restart.
  Ordinary releases are disabled.
- `RuntimeSelfTestService.run(cancellationToken: ...)`: supports cooperative
  cancellation without changing existing callers.

Default: **completely disabled**.

## What can currently be tested

| MCP tool | Execution path | Limits |
|---|---|---|
| `instance_info` | AIVEXUS app status + selected model | engine_version is null unless independently proven |
| `diagnostics_read` | Sanitized test status + runtime state | no raw diagnostics, paths, user prompts, credentials |
| `test_start` | actual `RuntimeSelfTestService.run()` | fixed synthetic prompt, kind=`runtime` only |
| `test_status` | stored request ID and sanitized result | no re-execution |
| `test_cancel` | shared CancellationToken | cooperative; a blocked native call may not stop instantly |
| `test_compare` | two test-status records | duration delta only if both durations known |

The current self-test uses `LocalRuntimeProvider.streamInference` directly.
It **does not** prove the entire ChatRepository/Orchestrator/memory/UI path.
App-pipeline test remains **NOT IMPLEMENTED**, explicitly advertised as false
by `instance_info`. Model-path strings and free-form self-test summaries are
not returned to ChatGPT.

The app's `instance_id` is generated per process launch and is never derived
from user identifiers. Successful metadata comes from inside the actual Flutter
process, authenticated with a secret known only to the local pair. This is
stronger than a standalone Python llama.cpp call, but not an attestation
against malicious software running under the same Windows account.

## ASUS activation — no PowerShell commands or manual key generation

**First use only**, after a reviewed internal QA build is available and the
user has separately approved trying it on the ASUS:

1. Open **AIVEXUS → Impostazioni → Collegamento ChatGPT (test)** and press
   **Attiva collegamento**. A random secret is generated in OS-protected storage
   and the localhost listener starts in the REAL running AIVEXUS application.
   No console, manual command or environment-variable setup before launch.
2. Open **ChatGPT Desktop → Impostazioni → Plugin → MCP → Aggiungi →
   MCP personalizzato → STDIO** and set:
   - **Name**: `AIVEXUS Local Test`
   - **Command**: `powershell.exe`
   - **Arguments**: `-NoProfile`, `-File`, and the path copied from the
     **Copia percorso del componente MCP** button in AIVEXUS. These are three
     separate arguments in the ChatGPT configuration UI. On the ASUS,
     Windows PowerShell's script execution policy initially prevented
     starting the `.ps1`. After independently verifying the file and
     unblocking that specific trusted QA script, the user successfully
     invoked it with `-NoProfile -ExecutionPolicy RemoteSigned -File
     <absolute-path-to-aivexus_mcp.ps1>` (five separate arguments). This
     affects only the launched PowerShell process, not the machine-wide
     execution policy. Do not disable Windows security protection.
   - **Environment variable**: name `AIVEXUS_BRIDGE_TOKEN`; value pasted from
     **Copia chiave di collegamento** in AIVEXUS. **Never send this value
     as a chat message or put it in screenshots, code, GitHub or Diagnostics.**
3. Save MCP configuration once. Ask ChatGPT to use
   `instance_info` from **AIVEXUS Local Test**. Verify the real process
   version and selected model. Then run one synthetic runtime test.
4. **Disattiva e revoca** inside AIVEXUS stops the server and deletes its
   secret. **Rigenera chiave** invalidates previous credentials immediately.
   After rotation update the token in the local ChatGPT MCP settings.

The UI supplies the script path so the user never needs to find it manually.
If the adapter is missing from the package, the Copy Path button is disabled
and the screen explains the missing component. Pairing requires AIVEXUS
and ChatGPT Desktop to run on the *same ASUS*. The script uses built-in Windows
PowerShell, tested in CI; Python installation is not needed.

**Important:** ChatGPT currently has no documented, verified API for
automatically registering a custom MCP from inside AIVEXUS. The initial MCP
entry in ChatGPT Desktop remains manual. This is a limitation, not a missing
AIVEXUS permission. If PowerShell script execution is blocked by OS/device
policy, stop rather than changing policy or Smart App Control.

**No installation, signing or updater publication is performed by this PR.**

## Actual ASUS validation and desktop tool visibility (2026-11-17)

On the user's ASUS, direct STDIO invocation demonstrated all six tools via
`tools/list`. Authenticated `tools/call(instance_info)` returned the real
Windows AIVEXUS app version `v1.0.16.16`, selected model
`qwen2_5_3b_instruct`, and runtime state `runtimeUnavailable` at that
moment. A subsequent fixed synthetic runtime test completed successfully
with `generated_text=OK` in 11,464 ms. This DOES NOT establish that the
normal chat/inference pipeline works; its separate investigation remains
out of scope here.

A manually launched PowerShell process does **not** inherit environment
variables entered only in the ChatGPT Desktop MCP settings. A missing token
in that manual process produces `bridge_token_missing` and does not by
itself indicate a server outage. The authenticated control probe was run
using a temporary process-local `AIVEXUS_BRIDGE_TOKEN`; no secret or actual
instance ID is saved in this document.

Despite a configured and enabled `aivexus_local_test` STDIO server, the
ordinary ChatGPT Desktop chat did not expose `instance_info` or the other
MCP tools. Do not treat that as an AIVEXUS app failure. First try selecting
an installed plugin explicitly with `@` in the Desktop chat (if offered).
Some independent reports describe a Windows Desktop Chat tool-exposure issue
where the same local MCP works in Work, although other reports show Work
can also be affected. A Desktop Work task or local Codex session is a
possible diagnostic alternative, **not** a guarantee; it must independently
show an actual `tools/call` from the target session. The hosted ChatGPT web
surface does not automatically inherit a Windows STDIO MCP configuration.

Related documentation and issue reports:
- https://learn.chatgpt.com/docs/extend/mcp
- https://github.com/openai/codex/issues/38162

Until a ChatGPT-hosted `tools/call` is observed, report the state precisely:
**MCP adapter ↔ AIVEXUS verified; ChatGPT chat → MCP not yet verified.**

## Security and reliability

- HTTP listener binds **only** to `127.0.0.1`, not `0.0.0.0` / LAN.
- A 32+ character bearer token is generated with `Random.secure()` on first
  user opt-in and persisted only in FlutterSecureStorage (OS-protected).
  No secret is compiled into the binary, printed in logs, or returned to MCP.
- Strict allow-list of methods, paths, kind, and request ID syntax; POST body
  bounded to 4096 bytes. Browser Origin requests rejected. No CORS.
- MCP adapter connects to one fixed host/port only and does not follow redirects.
- Stdio output carries JSON-RPC only. No exceptions, raw logs, credentials,
  stack traces, file paths or personal chat history returned.
- Unique IDs persisted before launch; retries of the same ID do not re-execute.
  Results persist as sanitized metadata through app restarts. Only the last
  512 IDs are retained; do not claim permanent exactly-once execution.
- One runtime test at a time. Cancellation is cooperative; an OS/native hang
  requires separate diagnosis. No process termination or firewall changes.
- Revocation is available as **Disattiva e revoca** inside AIVEXUS (stop +
  remove secret). Removing an MCP in ChatGPT alone does not stop the listener;
  use the AIVEXUS switch to actually revoke access.

## Platform expansion

The protocol schema and test ledger are platform-independent. Desktop Linux
and macOS can reuse the loopback HTTP code after real device builds/tests and
their own launch/security integration. Windows 8.1 needs a separate compatibility
check; it should not be treated as identical to Windows 11. Android/iOS require
a platform-appropriate permission/foreground lifecycle and safe transport
instead of assuming a background HTTP listener. ChatGPT Mobile/Web must use
a separately authorized supported remote transport; local STDIO is a desktop
capability and is not automatically available in those clients.

No remote tunnel, Cloudflare Worker, OpenAI API key, paid hosting, installed
MCP server or signed production build is introduced by this first increment.

## Validation gates before making this operational

1. Python synthetic protocol tests: `python -m unittest discover -s scripts/chatgpt_bridge -p 'test_*.py'` (CI only; does not require Python on ASUS).
   Native Windows PowerShell 5.1 JSON-RPC handshake test via GitHub Actions.
2. Flutter: `flutter test test/core/diagnostics/chatgpt_bridge/` (both server
   and one-tap pairing-controller tests).
3. Flutter static analysis / native Windows CI build (internal flag OFF by
   default). Fix CI failures before merging.
4. On ASUS, verify legitimate AIVEXUS binary and model; no Smart App Control
   bypass. Confirm `instance_info` actual build + model.
5. Repeat runtime tests; verify cancellation, restart recovery, closed app,
   missing model and inability to read personal logs.
6. **Second milestone** (not implemented): a deliberately isolated app-level
   test using `ChatRepository`/orchestrator and synthetic memory in a distinct
   profile, with a forced local-only route and separate UI verification.
7. **Third milestone**: platform adaptations and remote MCP only after account
   entitlement, transport authorization, revocation and cost review.

Do not describe passing Python stub tests as proof of real ASUS inference.
