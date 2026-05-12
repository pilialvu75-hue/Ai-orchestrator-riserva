import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';

void main() {
  Future<AiRuntimeSettingsService> createService(
      [Map<String, Object> values = const <String, Object>{}]) async {
    SharedPreferences.setMockInitialValues(values);
    final preferences = await SharedPreferences.getInstance();
    return AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(preferences)),
    );
  }

  group('AiRuntimeSettingsService', () {
    test('maps legacy AI mode values to runtime modes', () async {
      final localService =
          await createService(<String, Object>{AppConstants.prefAiMode: 'fast'});
      final cloudService =
          await createService(<String, Object>{AppConstants.prefAiMode: 'deep'});
      final hybridService = await createService(
          <String, Object>{AppConstants.prefAiMode: 'balanced'});

      expect(localService.runtimeMode, AiRuntimeMode.local);
      expect(cloudService.runtimeMode, AiRuntimeMode.cloud);
      expect(hybridService.runtimeMode, AiRuntimeMode.hybrid);
    });

    test('persists runtime mode and provider using normalized values', () async {
      final service = await createService();

      await service.setRuntimeMode(AiRuntimeMode.cloud);
      await service.setActiveProvider('gemini');

      expect(service.runtimeMode, AiRuntimeMode.cloud);
      expect(service.activeProvider, 'gemini');
    });

    test('falls back to OpenAI for unsupported providers', () async {
      final service = await createService(
        <String, Object>{AppConstants.prefActiveProvider: 'unsupported'},
      );

      expect(service.activeProvider, 'openAi');
      expect(service.normalizeProvider(null), 'openAi');
    });
  });
}
