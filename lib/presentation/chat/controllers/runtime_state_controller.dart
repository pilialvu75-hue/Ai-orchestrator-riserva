import 'dart:async';
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
  Timer? _pollingTimer;
  int? _lastSignature;

  RuntimeStateController({required this.diagnostics}) : super(const ChatRuntimeSnapshot()) {
    _syncState();
  }

  /// Avvia il ciclo di monitoraggio isolato ad alta frequenza senza toccare la UI generale
  void startMonitoring(Duration interval) {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(interval, (_) => _syncState());
    _syncState();
  }

  /// Interrompe il ciclo quando la pagina è in background o distrutta
  void stopMonitoring() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  void _syncState() {
    final currentState = diagnostics.monitor.state;
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
    stopMonitoring();
    super.dispose();
  }
}
