import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

@immutable
class SystemIndicatorsSnapshot {
  final bool voiceEngineActive;
  final String runtimeModeName;

  const SystemIndicatorsSnapshot({
    this.voiceEngineActive = false,
    this.runtimeModeName = 'hybrid',
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

class SystemIndicatorsController extends ValueNotifier<SystemIndicatorsSnapshot> {
  final AiRuntimeSettingsService runtimeSettings;
  final VoiceEngine voiceEngine;

  SystemIndicatorsController({
    required this.runtimeSettings,
    required this.voiceEngine,
  }) : super(const SystemIndicatorsSnapshot());

  /// Interroga lo stato dei servizi core per mappare la disponibilità dell'ASR e il profilo energetico
  Future<void> refreshIndicators() async {
    final runtimeMode = await runtimeSettings.loadRuntimeMode();
    final voiceStatus = await voiceEngine.inspect();

    value = SystemIndicatorsSnapshot(
      voiceEngineActive: voiceStatus.offlineAsrAvailable && voiceStatus.readyForInput,
      runtimeModeName: runtimeMode.name,
    );
  }
}
