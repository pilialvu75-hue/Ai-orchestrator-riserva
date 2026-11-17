# AIVEXUS ↔ ChatGPT Desktop local test bridge (experimental)

**State (2026-11-17): implementation prepared on feature branch; NOT released or
verified against the running ASUS AIVEXUS process.** Python protocol tests use a
synthetic HTTP stub. No MCP should be declared working with the app until a
device-side authenticated probe returns the actual AIVEXUS instance ID.

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
- `lib/app/runtime_bootstrap.dart`: starts the listener **only** on Windows
  with the explicit internal compile-time switch enabled AND a sufficiently
  long runtime secret. Neither ordinary release nor usual OTA enables it.
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

## Device-side prerequisites (NOT performed automatically)

1. Use the already installed Windows PowerShell. A historical ASUS audit
   reported the Python launcher unavailable, so Python is **not required**.
   Check `powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'`
   without changing execution policy. If script execution is forbidden by
   corporate/device policy, stop; do not bypass or disable protection.
2. Obtain an internal AIVEXUS Windows build compiled explicitly with
   `--dart-define=AIVEXUS_LOCAL_TEST_BRIDGE=true`. Standard shipped builds
   leave the bridge disabled. Do not turn off Smart App Control.
3. Generate a cryptographically random secret locally **on the ASUS**.
   Do not put it in GitHub, chats, screenshots, diagnostic releases, or logs.
   Use PowerShell (compatible with Windows PowerShell 5.1):

   ```powershell
   $bytes = New-Object byte[] 48
   $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
   $rng.GetBytes($bytes)
   $rng.Dispose()
   $secret = [Convert]::ToBase64String($bytes)
   ```

4. Launch the approved internal AIVEXUS build from an environment where
   `AIVEXUS_BRIDGE_TOKEN` equals this secret. The application must be running
   in that same session; the bridge cannot wake or launch it. The exact
   executable path is device-specific and must be verified, not guessed.
5. In **ChatGPT Desktop → Impostazioni → Plugin → MCP → Aggiungi → MCP
   personalizzato**, select **STDIO**:
   - Name: `AIVEXUS Local Test`
   - Command: `powershell.exe`
   - Arguments: `-NoProfile`, `-File`, then the **actual absolute path** to
     `scripts/chatgpt_bridge/aivexus_mcp.ps1`
   - Optional alternative only if Python 3 is already installed:
     Command `py`, arguments `-3` and the absolute path to
     `scripts/chatgpt_bridge/aivexus_mcp.py`
   - Environment variable: `AIVEXUS_BRIDGE_TOKEN` = same local secret.
   Never post the value or screenshot the populated field.
6. Ask in ChatGPT: "Use `instance_info` of AIVEXUS Local Test".
   Expected: AIVEXUS process instance ID, installed app version, host Windows,
   selected model and runtime status. The app's active version is read from
   actual runtime package metadata, not copied from this document.
7. Start one synthetic `runtime` test with a unique stable `request_id`;
   poll `test_status` using that *same ID*. Record PASS/FAIL and elapsed time.
   Repeat with AIVEXUS closed: `aivexus_not_reachable` is expected.

**No user action is required for this prototype until the internal build is
reviewed and explicitly approved. Do not install or publish from this document.**

## Security and reliability

- HTTP listener binds **only** to `127.0.0.1`, not `0.0.0.0` / LAN.
- A 32+ character bearer token is mandatory and provided at process runtime,
  never compiled into the binary. A missing secret keeps the listener disabled.
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
- To revoke access: close AIVEXUS, remove the custom MCP in ChatGPT and
  invalidate the shared secret; a new app launch without the secret remains
  disabled. Removing MCP alone does not stop an already enabled app listener.

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
2. Flutter: `flutter test test/core/diagnostics/chatgpt_bridge/aivexus_test_bridge_server_test.dart`.
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
