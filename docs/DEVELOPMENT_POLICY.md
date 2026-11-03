# Aivexus / AI Orchestrator — mandatory development-first policy
Date: 2026-11-03. Applies while the app is used solely on the owner's devices.

## Operating rule
The project is **under active development**, not commercial distribution. Do not
self-impose premature production requirements that prevent ordinary testing,
iteration, or delivery to the owner's own Android, Windows, macOS and Linux
devices. Keep the default path as zero-cost and practical. Defer commercial
release preparation until an actual finished product/external distribution
requires it and the owner explicitly decides to pursue that phase.

## What this changes
- Internal desktop/macOS releases must **not** require a paid Apple Developer
  account or notarization credentials to be *built and published for personal
  testing*. Keep ad-hoc signing as the fallback if those credentials are absent.
- Keep Developer ID signing and notarization available **when configured** for
  future general distribution, but their absence must not block the internal
  development delivery path.
- Update the owner's installed application via **Settings → Updates**. Build
  artifacts or manual DMG/APK handoffs are not proof of a working OTA path.
- Keep only meaningful technical checks: authorized source and release,
  reproducible build identity, compatible platform asset, file size/SHA-256,
  basic runtime integrity, and protection of user data/configuration.
- Avoid expensive or redundant builds and repeated approvals where automated
  evidence is enough. Preserve existing working app installations and SQLite;
  no forced uninstall or reset for an update test.

## Honest constraints
Ad-hoc code signing is **not** Apple notarization. macOS Gatekeeper may require
an explicit approval for a new or replaced app and may prevent first launch.
Do not bypass Gatekeeper globally or silently strip user quarantine settings.
An ad-hoc DMG can be discovered and downloaded by the in-app updater only
after it is published under the expected GitHub Release tag and its verified
SHA-256 digest. The updater opens a verified DMG; completion of the macOS
installation and data preservation still require a test on the physical Mac.
If macOS prevents the intended in-app process, document that limitation and
repair the local development flow rather than claiming it is solved.

## Revisit only when needed
Public redistribution, external testers, commercial sales, Apple Developer ID,
notarization, legal/compliance onboarding and additional governance should be
planned as **later optional milestones**, not development-blocking prerequisites.

Related implementation: `.github/workflows/macos-release-publish.yml` and
`lib/core/system/update/macos_update_manager.dart`. Tracking: issue #948.
