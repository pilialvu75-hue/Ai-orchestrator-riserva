# Core/Riserva Separation Audit

This document records the separation of production-safe Core from experimental modules.

## Classification

### CORE STABLE (keep in AI-Orchestrator-Core)
- `lib/core/**`
- `lib/features/**`
- `lib/app/**` (after MobileIDE-mode removal)
- `lib/injection_container.dart` (after MobileIDE DI removal)
- `.github/workflows/main.yml`
- `.github/workflows/build.yml`

### EXPERIMENTAL (migrate to AI-Orchestrator-Riserva)
- `lib/mobileide_os/**`
- `docs/MOBILEIDE_OS_ARCHITECTURE.md`
- `docs/PROVIDER_SDK.md`
- `docs/RUNTIME_SDK.md`

### BROKEN/INCOMPLETE (migrate to AI-Orchestrator-Riserva)
The following MobileIDE components contain stubs/TODOs/Unimplemented paths and must stay out of Core runtime:
- `lib/mobileide_os/providers/local_llm/llamatik_adapter.dart`
- `lib/mobileide_os/providers/codegen/dyad_adapter.dart`
- `lib/mobileide_os/providers/github/github_provider.dart`
- `lib/mobileide_os/runtimes/android/android_runtime_adapter.dart`
- `lib/mobileide_os/runtimes/sandbox/sandbox_runtime_adapter.dart`
- `lib/mobileide_os/modules/app_generation/app_generation_pipeline.dart` (pending TODO stages)

## Riserva target structure

Use this structure in `AI-Orchestrator-Riserva`:

```text
ai-orchestrator-riserva/
  /experimental/
  /ui-prototypes/
  /ai-integrations/
  /runtimes/
  /notes/
```

Recommended mapping:
- `lib/mobileide_os/core/**`, `lib/mobileide_os/agents/**`, `lib/mobileide_os/modules/**` → `/experimental/`
- `lib/mobileide_os/ui/**` → `/ui-prototypes/`
- `lib/mobileide_os/providers/**` → `/ai-integrations/`
- `lib/mobileide_os/runtimes/**` → `/runtimes/`
- `docs/MOBILEIDE_OS_ARCHITECTURE.md`, this audit, and migration notes → `/notes/`
- `docs/PROVIDER_SDK.md`, `docs/RUNTIME_SDK.md` → `/notes/`

## Core restoration actions performed

- Removed MobileIDE mode switching from active app shell.
- Removed MobileIDE dependency injection wiring.
- Removed MobileIDE extension tree from Core repository.

## Rule

Never merge Riserva back into Core without explicit review and stabilization.
