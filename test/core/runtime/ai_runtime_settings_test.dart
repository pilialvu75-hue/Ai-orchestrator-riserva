import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';

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

    test('persists memory window presets and custom values', () async {
      final service = await createService();

      await service.setMemoryWindowProfile(MemoryWindowProfile.custom);
      await service.setMemoryWindowCustomSettings(
        tokenBudget: 12000,
        lineBudget: 72,
      );

      expect(service.memoryWindowProfile, MemoryWindowProfile.custom);
      expect(service.customMemoryTokenBudget, 12000);
      expect(service.customMemoryLineBudget, 72);
      expect(service.memoryWindowConfig.maxTotalSize, 12000);
      expect(service.memoryWindowConfig.maxContextLines, 72);
    });

    test('resolves automatic config from the selected model', () async {
      final service = await createService(
        <String, Object>{
          AppConstants.prefMemoryWindowProfile: 'automatic',
          AppConstants.prefSelectedModel: 'llama_1b',
        },
      );

      final config = service.resolveMemoryWindowConfig(isWeb: false);

      expect(config.profile, MemoryWindowProfile.automatic);
      expect(config.activeProfile, MemoryWindowProfile.compact);
      expect(config.maxTotalSize, 4096);
      expect(config.maxContextLines, 6);
    });
  });
}
