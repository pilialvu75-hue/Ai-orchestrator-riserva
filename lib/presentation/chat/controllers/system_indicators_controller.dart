import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

@immutable
class SystemIndicatorsSnapshot {
  final bool voiceEngineActive;
  final String runtimeModeName;

  const SystemIndicatorsSnapshot({
    this.voiceEngineActive = false,
    required this.runtimeModeName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SystemIndicatorsSnapshot &&
          runtimeType == other.runtimeType &&
          voiceEngineActive == other.voiceEngineActive &&
          runtimeModeName == other.runtimeModeName;

  @override
  int get hashCode => Object.hash(voiceEngineActive, runtimeModeName);
}

class SystemIndicatorsController
    extends ValueNotifier<SystemIndicatorsSnapshot> {
  final AiRuntimeSettingsService runtimeSettings;
  final VoiceEngine voiceEngine;

  SystemIndicatorsController({
    required this.runtimeSettings,
    required this.voiceEngine,
  }) : super(SystemIndicatorsSnapshot(
            runtimeModeName: runtimeSettings.runtimeMode.name)) {
    runtimeSettings.addListener(_syncRuntimeMode);
  }

  bool _disposed = false;
  int _refreshId = 0;

  void _syncRuntimeMode() {
    if (_disposed) return;
    value = SystemIndicatorsSnapshot(
      voiceEngineActive: value.voiceEngineActive,
      runtimeModeName: runtimeSettings.runtimeMode.name,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshId++;
    runtimeSettings.removeListener(_syncRuntimeMode);
    super.dispose();
  }

  /// Interroga lo stato dei servizi core per mappare la disponibilità dell'ASR e il profilo energetico
  Future<void> refreshIndicators() async {
    if (_disposed) return;
    _syncRuntimeMode();
    final refreshId = ++_refreshId;
    var voiceActive = false;
    try {
      final voiceStatus = await voiceEngine.inspect();
      voiceActive =
          voiceStatus.offlineAsrAvailable && voiceStatus.readyForInput;
    } on Object {
      // A voice probe failure must not hide or change the selected AI mode.
    }
    if (_disposed || refreshId != _refreshId) return;
    value = SystemIndicatorsSnapshot(
      voiceEngineActive: voiceActive,
      runtimeModeName: runtimeSettings.runtimeMode.name,
    );
  }
}
