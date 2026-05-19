import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Runtime lifecycle states for the local GGUF inference engine.
///
/// Reported by [LocalRuntimeMonitor] so that UI layers and diagnostics can
/// reflect the current state of the local AI runtime without coupling
/// directly to provider internals.
enum LocalRuntimeStatus {
  uninitialized,
  loading,
  tokenizing,
  runtimeUnavailable,

  /// Model is loaded and ready to accept inference requests.
  ready,

  /// An inference request is actively running.
  inferencing,
  streaming,
  completed,
  timedOut,
  stalled,

  /// Required Android native library is missing for the current ABI.
  ffiMissing,

  /// No valid local model is selected or present on disk.
  modelMissing,

  /// Runtime initialization failed after all required artifacts were found.
  failed,
}

/// Snapshot of the local runtime state at a point in time.
class LocalRuntimeState {
  const LocalRuntimeState({
    this.status = LocalRuntimeStatus.uninitialized,
    this.message,
    this.tokensGenerated = 0,
    this.elapsed = Duration.zero,
    this.startedAt,
  });

  final LocalRuntimeStatus status;

  /// Human-readable description of the current state or error.
  final String? message;
  final int tokensGenerated;
  final Duration elapsed;
  final DateTime? startedAt;

  LocalRuntimeState copyWith({
    LocalRuntimeStatus? status,
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
  }) {
    return LocalRuntimeState(
      status: status ?? this.status,
      message: message,
      tokensGenerated: tokensGenerated ?? this.tokensGenerated,
      elapsed: elapsed ?? this.elapsed,
      startedAt: startedAt ?? this.startedAt,
    );
  }

  @override
  String toString() =>
      'LocalRuntimeState(${status.name}, $message, tokens=$tokensGenerated, elapsed=$elapsed)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalRuntimeState &&
           runtimeType == other.runtimeType &&
           status == other.status &&
           message == other.message &&
           tokensGenerated == other.tokensGenerated &&
           elapsed == other.elapsed &&
           startedAt == other.startedAt;

  @override
  int get hashCode => Object.hash(
        status,
        message,
        tokensGenerated,
        elapsed,
        startedAt,
      );
}

/// Observable monitor that tracks the live state of the local AI runtime.
///
/// Providers call [update] as they transition through lifecycle stages.
/// Consumers (UI, diagnostics) register listeners via [addListener] to react
/// to state changes without polling.
///
/// Thread-safety: all mutations are expected to occur on the Flutter main
/// isolate.  Listeners are called synchronously within [update].
class LocalRuntimeMonitor {
  LocalRuntimeState _state = const LocalRuntimeState();
  final List<void Function(LocalRuntimeState)> _listeners = [];

  /// Current runtime state snapshot.
  LocalRuntimeState get state => _state;

  /// Adds a [listener] that is called synchronously on every state change.
  void addListener(void Function(LocalRuntimeState state) listener) {
    _listeners.add(listener);
  }

  /// Removes a previously registered [listener].
  void removeListener(void Function(LocalRuntimeState state) listener) {
    _listeners.remove(listener);
  }

  /// Transitions to [status] and notifies all listeners.
  ///
  /// [message] carries optional human-readable context (e.g. an error
  /// description or the model name that is being loaded).
  void update(
    LocalRuntimeStatus status, {
    String? message,
    int? tokensGenerated,
    Duration? elapsed,
    DateTime? startedAt,
    bool resetProgress = false,
  }) {
    final previousState = resetProgress
        ? const LocalRuntimeState()
        : _state;
    final nextElapsed = elapsed ?? previousState.elapsed;
    final nextTokens = tokensGenerated ?? previousState.tokensGenerated;
    debugPrint(
      '[AI_RUNTIME_MONITOR] ${previousState.status.name} -> ${status.name}'
      ' tokens=$nextTokens elapsed_ms=${nextElapsed.inMilliseconds}'
      ' message="${message ?? ''}"',
    );
    RuntimeEventLog.instance.emit(
      '[AI_RUNTIME_MONITOR] ${previousState.status.name} -> ${status.name}'
      ' tokens=$nextTokens elapsed_ms=${nextElapsed.inMilliseconds}'
      ' message="${message ?? ''}"',
    );
    _state = LocalRuntimeState(
      status: status,
      message: message,
      tokensGenerated: nextTokens,
      elapsed: nextElapsed,
      startedAt: resetProgress ? startedAt : (startedAt ?? previousState.startedAt),
    );
    for (final listener in List.of(_listeners)) {
      listener(_state);
    }
  }
}
