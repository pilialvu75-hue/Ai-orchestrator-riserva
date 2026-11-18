---
name: aivexus-runtime-check
description: Use when the user wants to inspect the running AIVEXUS Windows instance version, chosen model, or local inference-runtime status without changing anything.
---

This private, Windows Desktop-only plugin has exactly one approved tool: `instance_info`.
Call it when asked to report the AIVEXUS app version, selected model, or runtime status.
Present precisely the values returned. Do not invent current status or imply inference is working merely because the MCP server responds.
Do not start synthetic tests, change models, open files, or perform system actions.
If the tool reports `bridge_token_missing`, instruct the user to refresh their local encrypted token with packaged `setup-token.ps1` after copying the key inside AIVEXUS.
If the tool reports `aivexus_not_reachable` or an HTTP error, ask the user to check that AIVEXUS Windows and its local bridge are running.
This plugin does not use Secure MCP Tunnel or the OpenAI Platform API.
