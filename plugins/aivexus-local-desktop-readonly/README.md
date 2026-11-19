# AIVEXUS Local Desktop — private read-only plugin

This local ChatGPT Desktop plugin starts a separate MCP stdio adapter which reads **only** `instance_info` from the already-running AIVEXUS Windows app at `127.0.0.1:47941`. It does not change or unregister the old `aivexus_local_test` server, invoke paid OpenAI APIs, start inference tests or use the Secure MCP Tunnel. No external server is deployed.

## Configure the one local credential (Windows 11)

The plugin never contains the bridge key. Once you have the verified plugin ZIP on the ASUS, extract it into a folder you own. From Windows PowerShell, run the `setup-token.ps1` file **in that extracted folder** (the installed copy may be in a private plugin cache). Use:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File 'C:\path\to\aivexus-local-desktop-readonly\setup-token.ps1'
```

When asked, copy the ephemeral **local** connection key using the AIVEXUS app button and press Enter. The script validates its length and stores only a **Windows DPAPI-encrypted** copy under `%LOCALAPPDATA%\AIVEXUS\ChatGPT-Desktop-ReadOnly\bridge-token.dpapi`. It clears the clipboard if the original secret is still there. The plaintext key is not included in plugin files or printed to logs. Rerun whenever AIVEXUS rotates its key. To remove the encrypted local token, run the same setup script with `-Clear`.

## Install

Use the private plugin link (if saved to your ChatGPT account) from **ChatGPT Desktop**, or add the plugin folder to a **personal local marketplace**. Open a new Desktop thread that supports local plugins, select `@AIVEXUS Local Desktop`, and ask for `instance_info`. Plugin installation and actual tool invocation must be verified on the user's ASUS: this package does not guarantee the surface will make local tools available in every Chat session.

The plugin runs `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File <plugin root>/server/aivexus_desktop_readonly.ps1` without changing Windows Defender, Smart App Control or the machine's execution policy. If the host reports the script blocked due to Mark of the Web, only after verifying its origin, unblock the relevant individual script files rather than disabling security globally.

## Safety and limits

- Only the `instance_info` tool is discoverable. Every other MCP tool is rejected at runtime, including a direct attempt to invoke `test_start`.
- All AIVEXUS requests stay on the local loopback address. No OpenAI Platform API key is needed.
- The token is reusable by processes running as the same Windows user (normal DPAPI boundary). Treat the PC user session as trusted. Keep plugin and token private.
- If the user changes the AIVEXUS connection key or starts a new app instance, repeat the local setup. If there is no token, the tool responds with `bridge_token_missing`.
- Stop/remove this plugin in the Desktop plugin manager. Run `setup-token.ps1 -Clear` to erase the stored encrypted token.
- The repo and package contain no personal bridge token, Platform key, identity, or persistent runtime credentials.

## Status and troubleshooting: ChatGPT Chat versus local MCP

As of 2026-11-19, the personal plugin is installed as v0.1.1, its skill is
enabled and its server appears in Settings > Plugins > MCP under "From plugins".
The Windows user confirmed that the DPAPI file exists, but ordinary ChatGPT Chat
did **not** expose the `instance_info` callable tool. The listing and DPAPI
file existence do **not** prove startup, token validity or a successful call.

Official OpenAI guidance: Desktop-only MCP plugins require a **local execution
surface**; saving them in the account does not make their tools callable from a
web/mobile or ordinary cloud-hosted chat. Do not change the bridge credentials,
restart inference or duplicate a tunnel to solve an unavailable tool selection.
Refs:
- https://help.openai.com/en/articles/20001256-plugins-in-chatgpt
- https://developers.openai.com/plugins/deploy/desktop-only

If a local Windows diagnosis is needed, **do not re-run setup-token.ps1** when the
protected file is already present. To distinguish ChatGPT tool availability from
local bridge authentication, open normal (non-admin) Windows PowerShell and run
the installed read-only wrapper. This is a read-only `instance_info` call;
it does not start inference or synthetic tests, print the stored key or reach
the internet:

```powershell
$root = Join-Path $env:USERPROFILE '.codex\plugins\cache\created-by-me-remote\aivexus-local-desktop-readonly'
$adapter = Get-ChildItem -LiteralPath $root -Recurse -Filter aivexus_desktop_readonly.ps1 -File |
    Sort-Object FullName -Descending | Select-Object -First 1
if ($null -eq $adapter) { throw 'Plugin runtime script not found in local cache' }
$request = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"instance_info","arguments":{}}}'
$raw = $request | & powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $adapter.FullName
if ($LASTEXITCODE -ne 0) { throw 'Local MCP adapter did not start' }
$response = $raw | Select-Object -First 1 | ConvertFrom-Json
if ($null -eq $response.result) { throw 'MCP response missing' }
$body = $response.result.content[0].text | ConvertFrom-Json
$body | ConvertTo-Json -Depth 8
```

The result should be a version/model/runtime object (local bridge reachable)
or an error code such as `bridge_token_missing`, `bridge_http_error` or
`aivexus_not_reachable`. No key is exposed. A successful PowerShell response
still does **not** make the tool available in normal ChatGPT Chat.
