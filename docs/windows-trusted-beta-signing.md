# AIVEXUS Windows beta — signed distribution gate

## Root cause (verified on ASUS, 14 November 2026)

On Windows 11 with Smart App Control / Code Integrity enabled, AIVEXUS updater
detected `1.0.15.200023-beta` successfully but installation ended with **4551**.
Event Viewer `Microsoft-Windows-CodeIntegrity/Operational`, event **3077**,
identified the blocked temporary Inno Setup self-copy
`AI-Orchestrator-Setup-x64.tmp`, launched by `AI-Orchestrator-Setup-x64.exe`.
This is not the separate CodeIntegrity 3033 event about a McAfee DLL.

## Release policy

The owner-only `.github/workflows/windows-computer-use-beta.yml` workflow now
**refuses to publish** if a trusted Authenticode signing identity is missing or
invalid. This applies to the manual Computer Use / offline 2048 QA beta and is
not a claim that every other historic release workflow has been migrated.

The signing path:

1. Requires a genuine CA-issued Windows code-signing certificate and its
   private key. Checks Code Signing EKU, trusted certificate chain and revocation.
2. Signs or validates all `.exe` and `.dll` files in the Windows release
   bundle, including the LOCAL inference runtime, after compatibility patching.
3. Compiles Inno Setup with `SignTool=aivexus_ci` and
   `SignedUninstaller=yes`. This signs Setup, uninstaller and **Inno's
   temporary self-copies**. Signing Setup *after* compilation is insufficient.
4. Validates the resulting installer's Authenticode chain and expected signer
   **before** computing SHA-256 and publishing a GitHub release.
5. Erases the ephemeral PFX file even if the workflow fails.

CI cannot reproduce the physical Smart App Control policy of the ASUS.
It does not promise that a merely signed app will always be allowed: the
publisher must be trusted by that policy, and the resulting release must be
tested on the ASUS with its Windows protections enabled.

## GitHub Actions secrets (not configured automatically)

Only the repository owner may decide to provision credentials. In GitHub
repository *Actions secrets* (never in source control, chat messages, logs,
screenshots or release assets), the owner would provide:

- `AIVEXUS_WINDOWS_SIGNING_PFX_B64`: base64 encoding of a CA-issued
  Authenticode PFX including its private key.
- `AIVEXUS_WINDOWS_SIGNING_PFX_PASSWORD`: password for that PFX.

The certificate must have Code Signing EKU and a chain trusted by a clean
Windows CI runner. No self-signed or test certificates should be used to
represent a public release as Smart App Control compatible.

These secrets are exposed only to preflight and signing steps. The PFX is
decoded on the ephemeral Windows runner **after** Flutter tests/build, and
deleted at job end. Password and PFX must never be displayed or committed.

Without the secrets, pressing **Run workflow** fails early and safely. The
already published `200023` remains install-blocked; do not keep retrying it.

## Zero-euro options (subject to owner approval)

- **SignPath Foundation:** [free OSS code-signing program](https://signpath.org/).
  Eligibility requires an OSI-approved license and open-source components.
  Repository visibility alone is insufficient; check all code, dependencies,
  license and intended commercial use before applying. Its HSM-backed signing
  integration is different from the PFX example above and requires a
  separately reviewed CI adapter.
- **Microsoft Store MSIX:** [Microsoft's code signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
  say Microsoft signs certified MSIX packages distributed through the Store.
  Registration for new individual developers is free in eligible markets.
  It does **not** sign direct GitHub Inno `.exe` downloads, and would require
  new packaging, Store approval, migration planning and explicit permission to
  publish; it is not an instant fix for the in-app updater.

The alternative of an ordinary commercial CA-issued certificate/managed signing
service may have costs and registration requirements: **do not purchase or sign
up without explicit owner authorization**.

## Acceptance criteria

- [ ] Valid trusted signing identity is available to the release pipeline.
- [ ] Inno Setup signs its temporary self-copies and uninstaller.
- [ ] Every PE in the bundle and the final installer is Authenticode valid.
- [ ] Manual workflow and signature pre-publication gate both pass.
- [ ] Existing AIVEXUS updater installs the beta in place on ASUS, with
      Smart App Control and Defender still enabled.
- [ ] LOCAL llama.cpp inference works after installing the beta.
- [ ] In Computer Use lab, actual LOCAL model decides offline 2048 moves,
      verified from observed board state (no hardcoded sequence).
