# MiniCPM5-2B Q4_K_M — Computer Use Windows experimental QA

**Scope:** ASUS Windows 11 beta only, LOCAL inference, no default-model change.
This candidate is additive to the model catalogue; Qwen is retained.

## Model

- ID: `minicpm5_2b`
- Official author/repository: `openbmb/MiniCPM5-2B-GGUF`
- File: `MiniCPM5-2B-Q4_K_M.gguf` (approximately 1.56 GB)
- Official license: Apache-2.0 (verify upstream before redistribution)
- URL: https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q4_K_M.gguf
- The app **does not bundle the GGUF**. Download is user initiated with the existing model manager.
- The installed `llama.cpp` runtime must be verified with this specific model.
  Catalog registration or unit tests do not prove that inference works.

## Manual beta test

1. Install only the approved AIVEXUS Windows beta from the in-app updater.
   Do not disable Smart App Control or change Windows security policy.
2. In Settings > Models, locate **MiniCPM5 2B (OpenBMB, prova)**
   under desktop models. Download, wait for file validation, select it
   explicitly and select manual LOCAL model routing.
3. In ordinary LOCAL chat, send `Ciao, rispondi in italiano.` and
   `Explique la conduction thermique en français.` Verify complete
   replies, error states, elapsed time, first token, token rate if reported.
4. Open **Computer Use — Laboratorio**, explicitly authorize the
   interactive session, launch the local 2048 test, select its window
   and start the LOCAL planner. Watch for real selected-window actions,
   observed board changes and the independent verifier. STOP must revoke
   authorization and abort inference.
5. Repeat steps 3–4 with Qwen2.5 3B, same device, prompt and mode.
   Compare completion, latency and the real game moves; do not infer
   superiority merely from smaller model size.
6. Return to Qwen manually. The existing model manager can remove
   the MiniCPM5 GGUF if no longer needed.

## Expectations and limitations

- MiniCPM5 uses ChatML message delimiters. Completed
  `<think>...</think>` prefixes are removed for the Computer Use
  planner only; the strict, typed action JSON parser and allowlist remain
  unchanged. Incomplete thinking remains an error.
- For MiniCPM5 **only**, the 2048 planner permits up to 120 seconds for
  one LOCAL completion and 12 minutes for the whole game QA; all existing
  permissions, STOP, step count and per-action verification remain.
- The model is not a visual/screenshot reader. The 2048 test uses the
  existing Windows accessibility description, not vision inference.
- The existing model catalogue and runtime support do not guarantee
  Windows 8.1 compatibility; this candidate is specifically targeted at
  Windows testing on the ASUS.
- No automatic downloads, no Cloud fallback, no publication outside
  the owner's approved beta, and no claim that this model is production
  certified.

**Release gate:** merge this candidate into `main` before the Windows beta
build is cut; verify relevant CI and the exact release commit. A PR alone
is not proof of inclusion in an installer.
