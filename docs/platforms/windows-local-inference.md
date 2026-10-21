# Windows local inference candidate

The Windows x64 package builds `llama-completion.exe` from the pinned
`third_party/llama.cpp` commit and installs it next to `ai_orchestrator.exe`.
No Node.js, Codex runtime, CUDA Toolkit, shell script, global PATH, or user-specific
environment variable is required. A bundled helper takes priority over old
`LLAMA_CPP_EXECUTABLE` workarounds. The developer override remains a fallback
when no bundled helper is present.

Windows calls completion in non-conversational mode with quiet logging, rather
than `--log-disable`, which suppresses generated stdout. Context is bounded at
4096 tokens, CPU threads at 1–8, and GPU offload is disabled for this portable
baseline. The provider drains both pipes before deciding success. Empty output
or a nonzero process exit cannot establish runtime verification.

## Compatibility and evidence

This is a CPU-only x64 candidate intended for Windows 8.1 first, then Windows 7
SP1. The existing Flutter compatibility shims and installer minimum remain.
The helper targets Windows 7 APIs and an SSE2 CPU baseline, uses a static C/C++
runtime and excludes CUDA, OpenMP, network/TLS and host-specific CPU flags.
CI audits its imports and performs two real GGUF generations through the same
Dart provider used by the UI. The test fixture is downloaded only on the runner
and is not shipped with the app. Android, Linux and macOS execution paths retain
their previous options.

Hosted CI runs on Windows Server 2022. A successful CI build is **not proof** of
Windows 8.1 or Windows 7 compatibility, nor of performance with every GGUF.
Physical tests remain required; no Windows ARM64 or 32-bit support is claimed.

## Physical test checklist

1. Preserve the previous installer and back up application data before updating.
2. Install the candidate or extract the complete portable ZIP into a new folder.
   Keep every file together; do not copy only the app EXE.
3. Check `llama-completion.exe` is next to `ai_orchestrator.exe`.
4. Use an already available small GGUF; this release does not download or change
   the default Android model.
5. Select Local mode and send `Calcola 17 per 23 e spiega brevemente`.
6. Confirm generated text appears, the request finishes and runtime becomes Ready.
7. Send a second distinct request; test cancellation and a subsequent request.
8. Restart the app and repeat; a loaded model file alone is not inference proof.
9. Record Windows version, CPU, RAM, model, first-token delay and any missing DLL
   or entry-point error. Test Windows 8.1 before Windows 7 SP1.

The independent candidate workflow publishes a prerelease with its exact source
commit, installer, portable ZIP and SHA-256 files. It does not run Android release
jobs or update the coordinated stable manifest.
