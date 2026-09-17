# Linux desktop

AI Orchestrator Linux is built as a Flutter/GTK x86_64 desktop application.
The first distribution target is Debian/Ubuntu-compatible systems.

## Runtime contract

- Flutter release bundle is self-contained under `/usr/lib/ai-orchestrator` in the `.deb` package.
- `llama-completion` from the pinned `third_party/llama.cpp` submodule is bundled next to the app executable.
- `llama-runtime` is the Linux runtime authority: it invokes the bundled helper with the non-conversational/quiet flags expected by the desktop process provider.
- The installed `/usr/bin/ai-orchestrator` launcher exports `LLAMA_CPP_EXECUTABLE=/usr/lib/ai-orchestrator/llama-runtime` before starting Flutter. The app therefore does not depend on a system-wide `llama-cli` installation.
- The portable bundle follows the same contract through `run-ai-orchestrator`; launching the raw Flutter executable is not the supported portable entry point.
- The helper is built CPU-only with portable x86_64 settings for the baseline package; hardware-specific acceleration is a later optimization and must keep a CPU fallback.
- The app emits the shared runtime/forensics events through `RuntimeEventLog`, including model validation and inference failures.
- Installation registers the desktop entry and scalable Linux icon; package maintainer scripts refresh desktop/icon caches when the host exposes those utilities.

## CI artifacts

`Build Linux Desktop` produces:

- `ai-orchestrator-linux-x64.tar.gz` — portable bundle with `run-ai-orchestrator`, `llama-runtime`, and the bundled `llama-completion` helper.
- `AI-Orchestrator_<version>_amd64.deb` and SHA-256 sidecar — installable Debian package.
- Flutter test and GUI launch logs for diagnostics.

The Linux build gate validates Dart analysis/tests, a real GGUF inference through the bundled llama.cpp helper, the Flutter release bundle, unresolved shared-library dependencies, the exact runtime launcher wiring, GUI startup under Xvfb through `run-ai-orchestrator`, and Debian package contents.

## Coordinated releases

`Publish Linux Release Asset` follows the same coordinated release line used by Android and Windows:

1. Wait for a successful `Build & Release APK` run on `main`.
2. Rebuild Linux from the exact Android release commit.
3. Inject the Android workflow run number into the desktop version (`<semver>+<run>`).
4. Build and validate the Debian package.
5. Publish `AI-Orchestrator-Linux-amd64.deb` and `AI-Orchestrator-Linux-amd64.deb.sha256` into the matching GitHub Release tag.

The fixed release filename is intentional: update discovery can identify one deterministic Linux asset while the Debian package metadata itself keeps the coordinated version.

## Update contract

Linux participates in the shared update discovery system with `UpdateTargetPlatform.linux`.
Only a release containing the fixed Debian asset with a valid GitHub SHA-256 digest is eligible. Android-only releases are ignored by Linux rather than being treated as installable updates.

The Linux update manager:

- checks in the background using the shared release channel policy;
- downloads the `.deb` with resumable range requests;
- validates exact byte size and SHA-256 before it becomes installable;
- persists a verified pending package across restarts;
- removes stale or superseded update downloads;
- re-verifies the package immediately before launch;
- opens the package using the desktop package handler (`xdg-open`, with `gio open` fallback).

AI Orchestrator does not silently invoke `sudo`, `pkexec`, `apt`, or another privileged installer. Package installation and privilege escalation remain visible to and controlled by the user through the operating system.

## Local install

```bash
sudo apt install ./AI-Orchestrator_<version>_amd64.deb
```

Launch from the desktop menu or run:

```bash
ai-orchestrator
```

For the portable archive:

```bash
tar -xzf ai-orchestrator-linux-x64.tar.gz
cd AI-Orchestrator
./run-ai-orchestrator
```

The portable `.tar.gz` remains available for diagnostics and non-system testing, while the coordinated self-update path targets the Debian package so there is a single verifiable installation format for the initial Linux release line.
