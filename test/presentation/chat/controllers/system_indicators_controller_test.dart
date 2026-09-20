import 'dart:async';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/system_indicators_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Voice extends Mock implements VoiceEngine {}

class _Status extends Mock implements VoiceEngineStatus {}

void main() {
  late AiRuntimeSettingsService settings;
  late _Voice voice;
  late SystemIndicatorsController controller;
  VoiceEngineStatus status(bool active) {
    final result = _Status();
    when(() => result.offlineAsrAvailable).thenReturn(active);
    when(() => result.readyForInput).thenReturn(active);
    return result;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({AppConstants.prefAiMode: 'local'});
    settings = AiRuntimeSettingsService(
        configRepository: ConfigRepository(
            PreferencesService(await SharedPreferences.getInstance())));
    voice = _Voice();
    controller = SystemIndicatorsController(
        runtimeSettings: settings, voiceEngine: voice);
  });
  tearDown(() {
    settings.dispose();
  });

  test('shows saved local mode before any voice inspection', () {
    expect(controller.value.runtimeModeName, 'local');
    verifyNever(() => voice.inspect());
    controller.dispose();
  });
  test('settings changes update immediately while voice inspection is pending',
      () async {
    final pending = Completer<VoiceEngineStatus>();
    when(() => voice.inspect()).thenAnswer((_) => pending.future);
    final refresh = controller.refreshIndicators();
    await settings.setRuntimeMode(AiRuntimeMode.cloud);
    expect(controller.value.runtimeModeName, 'cloud');
    pending.complete(status(true));
    await refresh;
    expect(controller.value.runtimeModeName, 'cloud');
    controller.dispose();
  });
  test('voice failure preserves the selected mode without an unhandled error',
      () async {
    when(() => voice.inspect())
        .thenAnswer((_) async => throw StateError('voice unavailable'));
    await controller.refreshIndicators();
    expect(controller.value.runtimeModeName, 'local');
    expect(controller.value.voiceEngineActive, isFalse);
    controller.dispose();
  });
  test('older probes cannot overwrite newer voice status', () async {
    final pending = Completer<VoiceEngineStatus>();
    when(() => voice.inspect()).thenAnswer((_) => pending.future);
    final old = controller.refreshIndicators();
    when(() => voice.inspect()).thenAnswer((_) async => status(true));
    await controller.refreshIndicators();
    pending.complete(status(false));
    await old;
    expect(controller.value.voiceEngineActive, isTrue);
    controller.dispose();
  });
  test('late probe and settings updates are safe after disposal', () async {
    final pending = Completer<VoiceEngineStatus>();
    when(() => voice.inspect()).thenAnswer((_) => pending.future);
    final refresh = controller.refreshIndicators();
    controller.dispose();
    await settings.setRuntimeMode(AiRuntimeMode.hybrid);
    pending.complete(status(true));
    await refresh;
  });
}
