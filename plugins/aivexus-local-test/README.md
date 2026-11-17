# AIVEXUS Local Test — experimental Desktop-only plugin

This is a **plugin package**, separate from the local MCP server entry already configured in ChatGPT Desktop. Registering a raw MCP server under Settings → MCP **does not by itself install a plugin** that appears in `@`.

The portable package contains `plugin.json`, `mcp.json`, and the verified Windows PowerShell 5.1 stdio adapter. The launch arguments use a process-local `-ExecutionPolicy RemoteSigned` (not a machine-wide policy change) and `${PLUGIN_ROOT}` for the bundled adapter path. The script is only suitable for trusted internal QA builds. Do not disable Defender or Smart App Control.

**Important limitations:** Packaging or enabling a Desktop-only local MCP plugin does **not** guarantee tools can be called from ordinary cloud-hosted ChatGPT chats or the web. Desktop-only tools may only be available to compatible *locally executing* threads. A direct authenticated Windows PowerShell `tools/call(instance_info)` succeeded on the ASUS, but ordinary ChatGPT Chat still did not expose those tools. This plugin has **not yet** been installed or tested in the actual ChatGPT Desktop plugin picker.

**Pairing:** No AIVEXUS token is stored in this package, marketplace, CI, or documentation. The server expects `AIVEXUS_BRIDGE_TOKEN` in its process environment. The existing token typed into a separate custom MCP server's Desktop settings is not guaranteed to be inherited by this packaged plugin. Until the host provides a supported, secure environment-variable setup for bundled servers, this is a packaging prototype, **not** a complete no-touch pairing solution. Never paste a token into chats, source control, screenshots, or manifests. Manual direct authentication from an isolated PowerShell session has already been verified separately.

The plugin only offers `instance_info`, `diagnostics_read`, `test_start`, `test_status`, `test_cancel`, and `test_compare`. It does not expose shell access or chat history. The runtime's normal inference pipeline is handled in another workstream.

Local marketplace metadata is at repository root `.agents/plugins/marketplace.json` for compatible desktop plugin hosts. It is not a public plugin submission and requires the host to discover/install that marketplace plugin in an eligible local session. An `@` entry is evidence of plugin installation; an actual `tools/call` with verified AIVEXUS response is the completion criterion.

References: https://developers.openai.com/plugins/build/plugins and https://developers.openai.com/plugins/deploy/desktop-only
