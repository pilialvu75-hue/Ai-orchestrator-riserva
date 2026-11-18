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
