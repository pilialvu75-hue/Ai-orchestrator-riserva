# Update System

## Overview

AI-Orchestrator-Core now includes a modular, semi-automatic update foundation under:

- `lib/core/system/update/update_checker.dart`
- `lib/core/system/update/update_manager.dart`
- `lib/core/system/update/update_manifest.dart`
- `lib/core/system/update/release_channel.dart`
- `lib/core/system/update/update_state.dart`
- `lib/core/system/update/version_comparator.dart`

The system is designed to remain isolated from presentation logic and to fail safely in offline conditions.

---

## Update Flow

1. App starts normally.
2. `UpdateManager` starts a non-blocking background check.
3. `UpdateChecker` tries remote manifest fetch.
4. If manifest is unavailable/invalid, checker falls back to GitHub Releases API.
5. If network sources fail, checker falls back to cached manifest in local storage.
6. `VersionComparator` determines whether a compatible newer version exists.
7. UI is notified via `ValueNotifier<UpdateState>`.
8. If user accepts update:
   - APK is downloaded to temporary app storage.
   - Progress is tracked in `UpdateState.downloadProgress`.
   - Install intent is prepared and launched.
   - Android installer asks the user to confirm install.

Startup is never blocked by update checks.

---

## Release Channels

Supported channels:

- `stable` (default)
- `beta`
- `nightly`
- `dev`

Channel behavior:

- `stable`: only stable releases
- `beta`: stable + beta
- `nightly`: stable + beta + nightly
- `dev`: all channels

Users can change the preferred channel in **Settings → System updates**.

---

## Manifest Structure

Expected JSON structure:

```json
{
  "version": "1.0.8",
  "channel": "stable",
  "min_supported": "1.0.5",
  "apk_url": "https://.../app-release.apk",
  "changelog": "...",
  "critical": false
}
```

Validation rules:

- `version`, `min_supported`, `apk_url` are required.
- `apk_url` must be a valid `http/https` URL.
- malformed manifests are rejected safely.

---

## GitHub Release Integration

When manifest is missing/unavailable, the checker integrates with GitHub Releases:

- fetches releases from `pilialvu75-hue/AI-Orchestrator-Core`
- detects latest compatible release for selected channel
- parses version from tags (e.g. `v1.0.8`)
- extracts APK asset URL (`.apk`)
- uses release body as changelog

This preserves existing release workflow behavior:

- auto patch version increment
- APK artifact upload
- release tagging and notes generation

---

## Offline / Failsafe Behavior

If internet is unavailable, GitHub fails, or manifest is corrupted:

- app continues running normally
- startup remains non-blocking
- cached metadata is used when available
- errors are surfaced as non-fatal update state

No update failure can crash startup.

---

## Security Considerations

- Manifest parsing is defensive and rejects invalid payloads.
- APK URL scheme and host are validated before download.
- Download uses app-controlled temporary storage.
- Installation is never forced; user confirmation is required in Android installer.
- FileProvider is used for safe APK URI sharing with installer.

---

## Future Roadmap (Prepared, not implemented)

The architecture intentionally supports extension toward:

- model update channels
- plugin package updates
- runtime component updates
- desktop update providers (Linux/macOS/Windows)
- multi-artifact update manifests

Current implementation focuses only on application APK update groundwork.
