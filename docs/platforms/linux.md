# Linux desktop

AI Orchestrator Linux is built as a Flutter/GTK x86_64 desktop application.
The first distribution target is Debian/Ubuntu-compatible systems.

## Runtime contract

- Flutter release bundle is self-contained under `/usr/lib/ai-orchestrator` in the `.deb` package.
- `llama-completion` from the pinned `third_party/llama.cpp` submodule is bundled next to the app executable.
- The helper is built CPU-only with portable x86_64 settings for the baseline package; hardware-specific acceleration can be added after the baseline is validated.
- The app emits its existing runtime/forensics events through `RuntimeEventLog`, including model validation and inference failures.

## CI artifacts

`Build Linux Desktop` produces:

- `ai-orchestrator-linux-x64.tar.gz` — portable bundle.
- `AI-Orchestrator_<version>_amd64.deb` and SHA-256 sidecar — installable Debian package.
- Flutter test and GUI launch logs for diagnostics.

## Local install

```bash
sudo apt install ./AI-Orchestrator_<version>_amd64.deb
```

Launch from the desktop menu or run `ai-orchestrator`.
