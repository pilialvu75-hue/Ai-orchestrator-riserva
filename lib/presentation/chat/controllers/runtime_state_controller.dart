import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';

@immutable
class ChatRuntimeSnapshot {
  final LocalRuntimeState state;

  const ChatRuntimeSnapshot({this.state = const LocalRuntimeState()});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatRuntimeSnapshot &&
          runtimeType == other.runtimeType &&
          state.status == other.state.status &&
          state.message == other.state.message &&
          state.tokensGenerated == other.state.tokensGenerated &&
          state.elapsed == other.state.elapsed &&
          state.startedAt == other.state.startedAt;

  @override
  int get hashCode => Object.hash(
        state.status,
        state.message,
        state.tokensGenerated,
        state.elapsed,
        state.startedAt,
      );
}

class RuntimeStateController extends ValueNotifier<ChatRuntimeSnapshot> {
  final LocalRuntimeDiagnosticsService diagnostics;
  late final void Function(LocalRuntimeState) _diagnosticListener;
  bool _isMonitoring = false;
  int? _lastSignature;

  RuntimeStateController({required this.diagnostics}) : super(const ChatRuntimeSnapshot()) {
    _diagnosticListener = _onDiagnosticsStateChanged;
    diagnostics.monitor.addListener(_diagnosticListener);
    _syncState(diagnostics.monitor.state);
  }

  /// Keep the snapshot in sync with the authoritative diagnostics monitor.
  /// Listener-driven monitoring ignores the interval and keeps the old API stable.
  void startMonitoring([Duration interval = Duration.zero]) {
    if (interval != Duration.zero) {
      // Ignored: monitoring is now driven by diagnostics listeners.
    }
    _isMonitoring = true;
    _syncState(diagnostics.monitor.state);
  }

  /// Pause UI propagation while the page is backgrounded.
  void stopMonitoring() {
    _isMonitoring = false;
  }

  void _onDiagnosticsStateChanged(LocalRuntimeState state) {
    if (!_isMonitoring) return;
    _syncState(state);
  }

  void _syncState(LocalRuntimeState currentState) {
    final currentSignature = Object.hash(
      currentState.status,
      currentState.message,
      currentState.tokensGenerated,
      currentState.elapsed,
      currentState.startedAt,
    );

    if (currentSignature != _lastSignature) {
      _lastSignature = currentSignature;
      value = ChatRuntimeSnapshot(state: currentState);
    }
  }

  bool isInferencing() {
    final status = value.state.status;
    return status == LocalRuntimeStatus.inferencing || status == LocalRuntimeStatus.streaming;
  }

  @override
  void dispose() {
    diagnostics.monitor.removeListener(_diagnosticListener);
    stopMonitoring();
    super.dispose();
  }
}
