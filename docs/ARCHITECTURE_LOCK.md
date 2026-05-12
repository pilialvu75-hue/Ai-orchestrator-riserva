# ARCHITECTURE LOCK

## Purpose

This document freezes the currently working AI-Orchestrator-Core architecture as the stable baseline reference for future development.

## Stable Baseline

- **Status:** LOCKED
- **Baseline Type:** Stable Architecture Baseline
- **Scope:** App root widget tree, orchestrator state flow, and configuration structure

## Locked Root Widget Tree

The stable root flow is:

`AppRoot → MaterialApp → AppShell → Scaffold → ChatPage`

Current root composition details:

- `main.dart` boots `AppRoot` via `runApp(const AppRoot())`.
- `AppRoot` provides root BLoCs with `MultiBlocProvider` and builds `MaterialApp`.
- `MaterialApp.home` is `AppShell`.
- `AppShell` owns the top-level `Scaffold` and sets `body: const ChatPage()`.
- `ChatPage` is the primary conversation surface and uses `OrchestratorStateEngine` for chat state and events.
- Navigation is currently route-lite and imperative (`Navigator.push` + `MaterialPageRoute` from shell/page actions), with no named-route tree defined at the root.

## OrchestratorStateEngine Lock

- `OrchestratorStateEngine` is the app-level chat state engine.
- It is registered in DI (`injection_container.dart`) and provided in `AppRoot`.
- It must remain accessible across navigated routes through root-level provisioning.
- Core events handled: message loading, sending, history pruning, and provider switching.

## Config System Lock

The configuration architecture is locked to the current module split under `lib/core/config/`:

- `app/` — app-level constants and environment (`AppConstants`, `AppConfig`, `EnvironmentConfig`)
- `ai/` — AI provider/model/role configuration contracts and registry types
- `storage/` — preference-backed config persistence (`ConfigRepository`, `PreferencesService`, `ConfigStorage`)
- `runtime/` — runtime behavior flags/config (`RuntimeConfig`, `FeatureFlags`, platform/language/runtime flags)

Canonical constants path remains:

- `lib/core/config/app/app_constants.dart`

Compatibility export remains:

- `lib/config/app/app_constants.dart`

## Forbidden Modifications

The following changes are explicitly forbidden under this lock:

1. **UI structure changes** to the locked root widget flow (`AppRoot → MaterialApp → AppShell → Scaffold → ChatPage`).
2. **Orchestrator system refactors** that replace or demote `OrchestratorStateEngine` from root-level state ownership.
3. **Config architecture changes** that alter the current `lib/core/config/` structure or move canonical config ownership away from it.
4. **New architectural patterns** that replace the current stable composition without an explicit architecture unlock decision.

## Change Policy

All future work must treat this document as the reference baseline.  
Any structural change to these locked areas requires a formal architecture unlock/update decision before implementation.
