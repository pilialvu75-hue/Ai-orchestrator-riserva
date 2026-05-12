# lib/native/runtime/

Platform-specific execution engine implementations for the AI Orchestrator.

The runtime layer provides the concrete `ExecutionEngine` implementations
that allow the orchestrator to dispatch device commands on each platform.

## Contents

| File/Directory | Purpose |
|---|---|
| `execution_engine_factory.dart` | Factory function — returns the correct executor for the current platform |
| `android/android_executor.dart` | Android implementation using `android_intent_plus` |
| `windows/windows_executor.dart` | Windows / desktop fallback (no-op) implementation |

## Design

The abstract `ExecutionEngine` contract lives in `lib/core/orchestrator/execution_engine.dart`.
The factory is registered into the service locator in `lib/injection_container.dart`.
