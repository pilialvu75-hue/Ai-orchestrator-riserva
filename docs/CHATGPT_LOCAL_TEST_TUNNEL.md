# AIVEXUS ↔ normal ChatGPT chats via OpenAI Secure MCP Tunnel (private QA)

**State (2026-11-17): prepared, NOT activated, NOT proven from ChatGPT.**
The local ASUS Windows QA adapter is already authenticated and independently
verified against the actual AIVEXUS process. ChatGPT ordinary Chat has not
exposed that *local* stdio MCP server. Work is not required for this route.

## Why this route

OpenAI's **Secure MCP Tunnel** lets a cloud-hosted ChatGPT chat use a PRIVATE
stdio MCP server on the ASUS. The official tunnel client polls OpenAI over
outbound HTTPS; no inbound firewall rule, public hostname, cloud proxy, or
Cloudflare account is required. The existing PowerShell adapter and six
allowlisted tools are reused unchanged. The user will create a **personal
custom MCP plugin** using ChatGPT **Plugins > Add custom MCP server > Tunnel**;
it should appear in `@` only **after** its creation and installation.

This is distinct from an MCP server merely listed under **Settings > MCP**,
and from the separate experimental bundled Desktop-only plugin package.
Ordinary ChatGPT Web cannot inherit local STDIO configurations.

Official references:
- https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
- https://developers.openai.com/api/docs/guides/custom-mcp-server
- https://github.com/openai/tunnel-client/blob/master/docs/onboarding.md
- https://github.com/openai/tunnel-client/releases/latest

## What is already proven and what is not

- **PASS:** PowerShell 5.1 `tools/list` returned six real MCP schemas.
- **PASS:** Authenticated `tools/call(instance_info)` returned a real running
  AIVEXUS Windows instance, app v1.0.16.16, model `qwen2_5_3b_instruct`.
- **PASS:** Authenticated fixed synthetic runtime test completed with
  `success: true`, `generated_text: OK`, elapsed 11,464 ms.
- **NOT YET:** Any direct tool call initiated by ordinary ChatGPT Chat.
- **OUT OF SCOPE:** Repairing AIVEXUS normal-chat inference (separate workstream).

## Preconditions — stop if unavailable

1. This OpenAI Platform **organization** must allow the account to use tunnels.
   The tunnel creator needs **Tunnels Read + Manage**; the restricted runtime
   API key needs **Tunnels Read + Use**. In Platform tunnel settings, create or
   reuse a `tunnel_id` and associate it with the **actual ChatGPT workspace**.
   A tunnel ID in the wrong workspace won't be visible as a ChatGPT plugin.
   Settings: https://platform.openai.com/settings/organization/tunnels
2. An OpenAI **Platform runtime API key** is required by the official tunnel
   client. It is NOT an AIVEXUS key, and a ChatGPT subscription does not
   automatically grant Platform API billing or tunnel permissions. The user
   must approve creating an account/key or incurring any charge; stop if any
   billing requirement appears. Never use a high-privilege admin API key
   for the daemon.
3. Install an authentic **Windows amd64** build of official
   `openai/tunnel-client`, using the Platform Tunnels download or verified
   GitHub release. Verify origin/checksum; the helper never downloads or
   installs a binary. Some published Windows builds have triggered Smart App
   Control; **do not disable Defender, Smart App Control or other protections**.
   If the binary is blocked, stop. Existing AIVEXUS QA and desktop MCP remain
   unchanged. **Known blocker:** OpenAI confirmed on 2026-09-15 that it did
   not plan to sign the prebuilt Windows tunnel-client executables; earlier
   official Windows builds were blocked by Smart App Control. Building the
   binary from source was suggested upstream, but a locally rebuilt unsigned
   executable does not itself guarantee acceptance by Smart App Control. Do
   not assume any current release is signed without verifying its signature
   and successful normal launch. Evidence:
   https://github.com/openai/tunnel-client/issues/68
4. Keep the existing Windows QA AIVEXUS running with the local bridge enabled.
   Keep `aivexus_mcp.ps1` on the ASUS. No new AIVEXUS build is required for
   the tunnel architecture.

## Prepared launcher (opt-in; no automatic execution)

The QA package includes `mcp-tools/aivexus_tunnel_start.ps1`. It validates
paths and tunnel ID, securely prompts for a separate Platform runtime key,
reads the existing **AIVEXUS bridge key** only from clipboard, and invokes
the verified local adapter.

For the verified ASUS layout the client defaults to
`%USERPROFILE%\\Downloads\\AIVEXUS-Tunnel-Client\\tunnel-client.exe` and
the launcher locates a unique `mcp-tools\\aivexus_mcp.ps1` beneath
`%USERPROFILE%\\Downloads`. If a second matching QA copy exists, stop and
supply the exact `-McpScriptPath` rather than choosing arbitrarily. The
launcher prompts for the already-created tunnel ID at runtime; the tunnel
ID is not secret. No key is entered in the PowerShell command line.

```powershell
# One-time, read-only ASUS preflight, using a locally reviewed copy of
# aivexus_tunnel_start.ps1 from this branch (not the web download ZIP):
& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$env:USERPROFILE\\Downloads\\AIVEXUS-Tunnel-Client\\aivexus_tunnel_start.ps1" -CheckOnly
```

This first check validates paths **without** reading secrets, invoking the
tunnel binary, contacting OpenAI, or changing Windows settings. The later
interactive run uses the same command without `-CheckOnly`; it asks for
tunnel ID, clipboard bridge key and a hidden Platform runtime key, then
checks `doctor` before starting `run`. Ensure the launcher is the trusted
reviewed repository file, and do not disable Windows protections.
The script does NOT create a tunnel or API key and does not install software,
open inbound ports, or register a ChatGPT plugin. Once invoked for real it
creates a local tunnel profile, runs `doctor --explain`, and leaves the
`tunnel-client run` process in the foreground. Close it with Ctrl+C; stop
AIVEXUS pairing from its own settings to revoke its local credential.

Only a trusted, user-approved API runtime key and the existing local bridge
secret are kept as environment variables in the launcher process while it
runs. On shutdown the environment is restored; neither secret is deliberately
written to the launcher-generated tunnel profile, repository, or logs.
The tunnel client and its spawned local MCP subprocess may inherit these
process environment values, so **run only reviewed trusted binaries**.
AIVEXUS bridge key should never be pasted into ChatGPT, GitHub or screenshots.

## Activation in normal ChatGPT Web: workspace entitlement required

**Do not treat this procedure as available on ChatGPT Plus.** OpenAI's
current support policy grants custom MCP server connections to Business
and Enterprise/Edu ChatGPT Web workspaces, with read/fetch limitations
for Pro. The user's Plus account does **not** currently expose the
required `Connection > Tunnel` form. The successful private tunnel runtime
does not override account entitlements.

For an **eligible** future ChatGPT Web workspace only, when the tunnel
client reports *ready and polling*:

1. In ChatGPT on the web, open **Plugins** → **Add custom MCP server**.
2. Under **Connection**, choose **Tunnel**, select the exact tunnel associated
   with your ChatGPT workspace (or paste its ID where the UI allows).
3. Under authentication, for this single-user private read-only diagnostics
   experiment choose **No authentication** only if accepted by the workspace;
   the tunnel's organization/workspace access and AIVEXUS's separate local
   bearer token remain active. Do NOT make the tunnel public or remove its
   separate Platform access controls. If workspace policy mandates OAuth,
   stop rather than falsely claiming it is configured.
4. Review the risk warning and select **Create as a plugin**. Install the new
   plugin in ChatGPT. Start a **new ordinary Chat**. Select the plugin with `@`
   and call `instance_info`. Record its *actual tool invocation*, returned
   app version/model, and errors. No Work is required.
5. If it fails, use `tunnel-client doctor --profile aivexus-local-test --explain`
   and the local /ui readiness screen. Never upload secrets, raw diagnostics,
   or access tokens. Stop/revoke the tunnel when not actively testing.

## ASUS live tunnel smoke-test finding (2026-11-17)

- **PASS**: the restricted Platform runtime key authenticated with OpenAI.
  `init` created the private profile, `doctor --explain` reported `RESULT ok`,
  the tunnel metadata was fetched, and the localhost health UI started.
- **FAIL**: the initial `run` repeatedly restarted the local stdio child.
  Its startup summary showed the configured `mcp_target_value` stopping at
  `...\\Downloads\\aivexus-chatgpt-bridge-windows-qa` before the ` (1)`
  directory suffix; the MCP script path had been truncated at whitespace.
  This did **not** prove end-to-end ChatGPT connectivity.
- **Mitigation now implemented**: stage a copy of the already-approved
  `aivexus_mcp.ps1` beside the verified `tunnel-client.exe` in the no-space
  `AIVEXUS-Tunnel-Client` download folder; use that exact path when generating
  the stdio profile. Reconfigure the script-owned `aivexus-local-test` profile
  with `init --force` (officially supported for an existing profile).
  Run with `--mcp.stdio-failure-policy=exit` so an unexpected child exit stops
  the tunnel instead of looping. Explicitly pause for the user to copy the
  AIVEXUS bridge key into the clipboard, preventing command-copy collisions.
- **Later verified on the real ASUS**: with the quoted-path fix below,
  the local tunnel UI reported `Health: live`, `Ready: ready`, the
  `main` stdio channel enabled, and successful control-plane polling.
  The actual ordinary-ChatGPT `instance_info` invocation remains
  **unverified**. Only start one tunnel-client per tunnel ID. Do not
  treat a green `doctor` as proof of a remote tool invocation.

### Confirmed parser defect from the second ASUS run

The repaired no-space path was `C:\\Users\\vivob\\Downloads\\AIVEXUS-Tunnel-Client\\aivexus_mcp.ps1`,
but the child still exited with Windows PowerShell code `0xfffd0000`
within 74 ms. Inspection of the *actual v0.0.21* upstream function
`parseCommandArgv` in `pkg/runtimeconfig/config.go` identified why:
**unquoted Windows backslashes are treated as escaping the next byte**.
A seemingly correct `-File C:\\Users\\...` is passed to the subprocess with
backslashes stripped, so Windows PowerShell cannot locate the script.

**Fix:** construct `--mcp-command` with the full adapter path enclosed
in literal single-quote characters. The official parser recognizes single
quotes and preserves literal backslashes within them. These quotes are
removed by the parser before `exec.Command` receives arguments. We
retain the shorter staged path and `--mcp.stdio-failure-policy=exit`.
A Python no-network regression test models the official lexer and proves
that unquoted and quoted paths behave differently. Official reference:
https://github.com/openai/tunnel-client/blob/v0.0.21/pkg/runtimeconfig/config.go

The first ASUS diagnosis of a whitespace-only failure was incomplete.
A green `doctor` does not prove that the spawned MCP subprocess is usable.
**Not yet proven:** a real local ASUS run of this quoted-path fix, the
`/readyz` status, and a real instance_info call from ordinary ChatGPT.

## ChatGPT plugin registration: confirmed separate from local MCP (2026-11-17)

**New actual observation:** On ASUS, the tunnel-client administration UI reports
`Health: live`, `Ready: ready`, `Logs: connected`, an enabled `main` stdio
channel, successful control-plane polling, and no poll errors. This proves the
private tunnel daemon is running and reaching OpenAI, **not** that a ChatGPT
conversation can invoke AIVEXUS `instance_info`.

The user's ChatGPT Desktop Plugins > MCP screen lists
`aivexus_local_test` as an enabled **local STDIO server**. The
**Add MCP Server** dialog accepts STDIO commands or HTTP; it does not offer
`Connection: Tunnel`. The **Create plugin** menu opens Plugin Creator,
which reports that an existing *registered app connection* must be referenced
by its exact `plugin_asdk_app_...` ID in `.app.json`; it cannot map the
local server alias to that ID. No plugin was created.

Official packaging docs distinguish these:
https://developers.openai.com/plugins/build/plugins#package-with-plugin-creator
First register an MCP connection via **Add custom MCP server** and copy the
`plugin_asdk_app...` ID from the resulting browser URL, then reference it
in `.app.json`. A local STDIO alias does not prove such registration exists.
Official help lists custom MCP web registration for Business/Enterprise/Edu
and some read/fetch restrictions for Pro; availability must be checked
against the actual user account/workspace before assuming the tunnel can
be added to ordinary ChatGPT Chat:
https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt

**Safe current outcome:** Preserve the working local MCP server and tunnel
configuration. Do not register a second STDIO adapter, buy API credits,
upgrade the plan, or create a misleading plugin. The next distinct action
is to inspect any existing registered ChatGPT MCP connection detail for a
real `plugin_asdk_app...` ID, or verify actual entitlement to the
`Connection: Tunnel` creation flow. If neither exists, mark cloud-chat
activation blocked by ChatGPT surface/permissions, not by AIVEXUS runtime.
A local tunnel can be stopped with Ctrl+C until a compatible consumer exists.

## Final entitlement finding and zero-cost next steps (ChatGPT Plus)

The `aivexus_local_test` entry observed under ChatGPT Desktop **Plugins >
MCP** is a local `powershell.exe` + STDIO configuration with an
`AIVEXUS_BRIDGE_TOKEN` environment variable. Its edit dialog shows
command, arguments, env, passthrough, and working directory, but no
registered app ID. The user temporarily replaced the token value with
`a` for a screenshot; if saved rather than just masked for the screenshot,
the original valid token must be restored before any local MCP test.
Do **not** paste the token into ChatGPT, shell history, or GitHub.

The `plugin_asdk_app_...` identifier described in the official packaging
guide is associated with a **registered ChatGPT MCP app connection**, not
the human-readable local server name. Plugin Creator refused to infer
that ID, and no ChatGPT plugin was created. Do not fabricate one:
https://developers.openai.com/plugins/build/plugins

The user is on **ChatGPT Plus**. OpenAI's Help Center says custom MCP
web connections and full support are available to Business/Enterprise/Edu,
and that Pro has limited read/fetch support. Plus is not listed:
https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt
The Desktop add-MCP screen the user actually sees exposes STDIO and
HTTP only; it cannot be used as proof of web tunnel integration.

**Supported alternative without requiring a plan upgrade:** official
documentation states that ChatGPT Desktop can run a *desktop-only plugin
containing a local MCP server*. This is distinct from referencing a
registered app in `.app.json`. The portable plugin can declare an MCP
server in `mcp.json`, but that starts/configures an MCP child for the
plugin; it is **not a verified reuse of the already configured
`aivexus_local_test` connection**. Creating that alternate binding
requires a separate user decision because the original request explicitly
forbade duplicate connectors.
https://help.openai.com/en/articles/20001256-plugins-in-chatgpt
https://developers.openai.com/plugins/build/plugins

**Current no-change action:** retain the existing enabled
`aivexus_local_test` local MCP configuration and the validated private
tunnel setup. Stop the tunnel process with Ctrl+C while not testing to
avoid unnecessary use. Do not request API credits, payment methods,
new credentials, an additional tunnel, or a second STDIO registration.
The next technical milestone is either (a) a genuinely eligible ChatGPT
workspace with `Connection: Tunnel`, or (b) approval for a *separate
desktop-only local plugin binding* that reuses the same AIVEXUS loopback
endpoint and can expose just `instance_info`.

## Optional instance_info-only MCP profile (implemented in branch)

The bridge adapter now checks `AIVEXUS_MCP_INSTANCE_ONLY=1` when it starts.
With that **opt-in** environment variable, `tools/list` returns exactly one
schema: `instance_info`. `tools/call` also enforces the same restriction
at dispatch: any other method returns
`tool_disabled_by_read_only_profile` without reaching AIVEXUS.

With the variable unset, the existing `aivexus_local_test` setup continues
exposing its six historical tools. No installed Desktop connection or
Windows environment was changed by this repository patch. Windows CI
exercises both the default six-tool mode and the restricted one-tool mode,
including a direct attempt to call blocked `test_start`. No secret or real
AIVEXUS instance is required for these protocol-level tests.

This is preparatory work for a future Desktop-only plugin. It is NOT a
registered ChatGPT `plugin_asdk_app` connection, nor evidence that normal
ChatGPT web can call the Desktop MCP server on Plus. A local plugin using
this filtered adapter would still require an explicit separate binding
decision. Do not install or launch a duplicate MCP server automatically.

## Authorized separate Desktop-only plugin (private, v0.1.0)

User explicitly authorized a **second** local MCP binding while preserving
`aivexus_local_test`. The repository now includes the complete self-contained
source package under `plugins/aivexus-local-desktop-readonly/`:

- `plugin.json` (portable Agent Plugins 1.0 + Desktop-only metadata).
- `mcp.json` (one `powershell.exe` stdio entry with bundled scripts).
- `server/aivexus_mcp.ps1` (copies the approved adapter with the opt-in
  `instance_info`-only filter).
- `server/aivexus_desktop_readonly.ps1` (forces that filter at runtime,
  obtains local AIVEXUS token from an encrypted, per-Windows-user DPAPI file,
  then runs the bundled MCP adapter without extra stdout).
- `setup-token.ps1` (asks user to copy the AIVEXUS local bridge key, stores
  DPAPI-protected material under `%LOCALAPPDATA%` and clears the clipboard).
- `skills/aivexus-runtime-check/SKILL.md` and `README.md`.

Windows GitHub Actions now parses all three PowerShell scripts and exercises
the **bundled** wrapper without credentials: tools/list advertises exactly
`instance_info`, direct `test_start` is denied, and absence of a token
returns `bridge_token_missing`. Python MCP tests also pass.

Plugin Creator successfully saved one **private USER-scoped** package
`aivexus-local-desktop-readonly` version `0.1.0` and exposed portable and
compatibility manifests. This does **not** mean it is installed on ASUS or
callable from ordinary Chat: the user must install it via ChatGPT Desktop,
complete the local DPAPI setup and verify a real `instance_info` result.
No work mode, new tunnel, OpenAI API credit, higher subscription, app change,
or Windows machine-wide security change is required by the package.

User's previous tunnel remains available but unnecessary for this
Desktop-only path; it can be stopped with Ctrl+C. If the private-plugin
installer on the current ChatGPT Chat surface does not make local tools
available, report this access constraint rather than inventing a success.

## Security and limits

- The tunnel transports requests to a local MCP subprocess, which itself
  forwards only authenticated calls to the existing loopback AIVEXUS listener
  on `127.0.0.1:47941`.
- No personal chats, arbitrary shell access, raw logs, general HTTP proxying,
  remote commands or model control are exposed in this prototype.
- The diagnostic tool `test_start` initiates a synthetic local runtime test.
  It has resource costs and is **not** semantically read-only. Tool approvals
  must reflect that; `instance_info` and status reads can be read-only.
- There is **no guarantee of zero billing** for Platform access. No deployment,
  key creation, account upgrade, paid service activation or tunnel registration
  has been performed by this repository change.
- Official tunnel support allows testing privately but does not satisfy
  requirements for submitting a public plugin.

**Completion criterion:** an ordinary ChatGPT chat actually invokes
`instance_info` from a correctly authorized AIVEXUS MCP integration and
receives live version/model/runtime information from the ASUS.
`Ready` on the tunnel dashboard or enabled on the Desktop MCP list is
not sufficient. Until that call is observed, state is
**transport prepared; ChatGPT tool connection blocked by registration/
entitlement**.
