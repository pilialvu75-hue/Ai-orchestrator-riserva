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
   unchanged.
4. Keep the existing Windows QA AIVEXUS running with the local bridge enabled.
   Keep `aivexus_mcp.ps1` on the ASUS. No new AIVEXUS build is required for
   the tunnel architecture.

## Prepared launcher (opt-in; no automatic execution)

The QA package includes `mcp-tools/aivexus_tunnel_start.ps1`. It validates
paths and tunnel ID, securely prompts for a separate Platform runtime key,
reads the existing **AIVEXUS bridge key** only from clipboard, and invokes:

```
# Illustrative syntax, not a ready-to-execute command. Replace the placeholders.
& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File <launcher_path> \
  -TunnelId <tunnel_32_lowercase_hex_or_digits> \
  -TunnelClientExe <verified_tunnel_client_exe_path> \
  -McpScriptPath <aivexus_mcp_ps1_path>
```

Run `-CheckOnly` first to validate paths and ID syntax **without** reading
secrets, invoking the binary, contacting OpenAI, or changing Windows settings.
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

## Activate in normal ChatGPT Chat (not Work)

Only when the tunnel client reports *ready and polling*:

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

**Completion criterion:** an ordinary ChatGPT chat calls
`aivexus_local_test.instance_info` through the approved private tunnel and
receives live data from the running ASUS instance. Until observed, state is
**prepared, not connected**.
