# AIVEXUS Windows CUDA — Microsoft Store private Beta (0 € candidate)

**Status: SOURCE-ONLY EXPERIMENT. No Store release, sideload installer, account registration, submission, or migration has been executed.**

## Why this alternative exists

Windows 11 Smart App Control on the ASUS blocked the unsigned temporary Inno Setup self-copy (error 4551; CodeIntegrity event 3077). The owner-approved Windows EXE beta release gate needs a CA-trusted code-signing identity. The actual release request for main `4eadb421` failed at the signing-secret preflight. Do not disable Smart App Control or substitute a self-signed PFX.

Microsoft Store registers individual developers for free in eligible regions and re-signs **MSIX** submissions after certification. It does **not** re-sign existing GitHub-distributed Inno EXE installers. A private audience can receive a beta without a public Store listing.

Sources:
- https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account
- https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements
- https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/visibility-options
- https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-manual-conversion

## What the QA pipeline does

Source-only workflow: `.github/workflows/windows-store-msix-qa.yml`.

1. Compiles **the same Flutter AIVEXUS app** on Windows 2022 with `AIVEXUS_WINDOWS_CUDA_QA=true`, `AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA=true`, and `AIVEXUS_LOCAL_TEST_BRIDGE=true`.
2. Bundles the pinned, SHA-256-verified llama.cpp CUDA runtime and the local `mcp-tools/aivexus_mcp.ps1` adapter. Vulkan/CPU fallback stays available.
3. Creates a minimal full-trust Windows Desktop package using Windows SDK `MakeAppx.exe`. Reads the original AIVEXUS icon and generates the MSIX tile assets. Requires the exact Store product identity, publisher, and display names for a real Store submission candidate.
4. Uses an **explicit QA placeholder identity on pull requests**, never as a Store-ready product. A manually triggered build instead requires the real values reserved in Partner Center.
5. Enforces MSIX Store version `1.0.<workflow_run_number+1000>.0`. The final component is exactly zero, as Microsoft requires for Store submissions.
6. Unpacks the MSIX with MakeAppx and checks that the app, CUDA engine and ChatGPT adapter are present. Uploads an **unsigned temporary Actions artifact only**, with a checksum and QA warning. It does not install, sign, upload to Partner Center, or publish any GitHub Release.

The `AIVEXUS_WINDOWS_STORE_MSIX` compile-time flag prevents the Windows MSIX build from downloading or launching GitHub/Inno EXE updates, and Settings tells the user to obtain Store updates. **Existing EXE builds retain the previous updater unchanged.**

## What requires an owner decision and account access

1. The owner creates or selects a free Microsoft Store developer account, accepts any Partner Center agreements, reserves the AIVEXUS product identity, and determines commercial/visibility terms. No agent should register or submit in the owner's name without explicit approval.
2. Obtain the exact **Identity Name**, **Publisher**, **Publisher Display Name**, and **App Display Name** from Partner Center. Those are public product identity fields, not passwords. Supply them directly as manual workflow inputs.
3. Inspect the generated unsigned MSIX artifact and complete a private-audience submission in Partner Center. Microsoft must certify and sign it. Select a tester group containing the owner's **personal Microsoft account**.
4. Test on a clean Windows 11 account or test PC **without replacing the existing ASUS EXE installation**: app launch, local model loading, NVIDIA runtime, VRAM, TTFT, 2048 Computer Use actions, ChatGPT bridge menu, data paths and revocation.
5. Before migrating the current ASUS, verify that Microsoft Store package identity, persistence and app data can coexist with or migrate from the Inno EXE installation. No conversion/downgrade is automatically guaranteed.
6. Verify Smart App Control on the real ASUS accepts the resulting Microsoft-signed Store installation. Store signing alone does not prove that every bundled native DLL passes the device policy.

## Explicit limits

- MSIX targets **Windows 10/11 only**, not the existing Windows 8.1 experiment.
- Microsoft Store delivers its own updates; this does **not** meet the original requirement that the existing AIVEXUS EXE updater install the beta in place. The original route remains blocked until a valid Windows code signer is available.
- The QA artifact is unsigned and **must not be sideloaded** or treated as an installable beta. Do not import a self-signed CA into the ASUS trust store to make it install.
- ChatGPT menu and local MCP adapter are packaged, but ordinary ChatGPT chat-to-AIVEXUS MCP visibility remains separately unverified.
- The main Stable release, Android, macOS, Linux and the existing Windows EXE installer are untouched by the Store QA build.
