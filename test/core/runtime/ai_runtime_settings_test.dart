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

    test('persists manual Cloud provider and clears back to automatic',
        () async {
      final service = await createService();

      expect(service.manualCloudProvider, isNull);
      expect(service.isCloudProviderAutomatic, isTrue);

      await service.setManualCloudProvider('claude');
      expect(service.manualCloudProvider, 'claude');
      expect(service.isCloudProviderAutomatic, isFalse);

      await service.setManualCloudProvider(null);
      expect(service.manualCloudProvider, isNull);
      expect(service.isCloudProviderAutomatic, isTrue);
    });

    test('manual Cloud provider rejects unsupported provider IDs', () async {
      final service = await createService();

      await expectLater(
        service.setManualCloudProvider('unsupported'),
        throwsArgumentError,
      );
      expect(service.manualCloudProvider, isNull);
    });

    test('falls back to OpenAI for unsupported providers', () async {
      final service = await createService(
        <String, Object>{AppConstants.prefActiveProvider: 'unsupported'},
      );

      expect(service.activeProvider, 'openAi');
      expect(service.normalizeProvider(null), 'openAi');
    });

    test('uses catalog model by default and persists provider override', () async {
      final service = await createService();

      expect(service.cloudModelFor('openAi'), 'gpt-5.6-terra');
      await service.setCloudModel('openAi', 'custom-openai-model');
      expect(service.cloudModelFor('openAi'), 'custom-openai-model');

      await service.setCloudModel('openAi', '');
      expect(service.cloudModelFor('openAi'), 'gpt-5.6-terra');
    });

    test('free-tier automatic Cloud remains available while paid stays opt-in',
        () async {
      final service = await createService();

      expect(
        service.cloudSpendingMode,
        CloudSpendingMode.confirmBeforeSpending,
      );
      expect(service.automaticCloudSpendingAllowed, isFalse);
      expect(service.automaticCloudUseAllowed('gemini'), isTrue);
      expect(service.automaticCloudUseAllowed('claude'), isFalse);
      expect(service.automaticCloudUseAllowed('openAi'), isFalse);
      expect(service.automaticCloudUseAllowed('copilot'), isFalse);

      await service.setCloudSpendingMode(CloudSpendingMode.freeOnly);
      expect(service.automaticCloudUseAllowed('gemini'), isTrue);
      expect(service.automaticCloudUseAllowed('claude'), isFalse);

      await service.setCloudSpendingMode(CloudSpendingMode.prepaidOnly);
      expect(service.automaticCloudUseAllowed('gemini'), isTrue);
      expect(service.automaticCloudUseAllowed('claude'), isFalse);

      await service.setCloudSpendingMode(CloudSpendingMode.budgetLimit);
      expect(service.automaticCloudUseAllowed('gemini'), isTrue);
      expect(service.automaticCloudUseAllowed('claude'), isFalse);

      await service.setCloudSpendingMode(CloudSpendingMode.unrestricted);
      expect(service.automaticCloudSpendingAllowed, isTrue);
      expect(service.automaticCloudUseAllowed('gemini'), isTrue);
      expect(service.automaticCloudUseAllowed('claude'), isTrue);
      expect(service.automaticCloudUseAllowed('openAi'), isTrue);
      expect(service.automaticCloudUseAllowed('copilot'), isTrue);
    });

    test('persists and clears Cloud budget limit', () async {
      final service = await createService();

      await service.setCloudSpendingMode(CloudSpendingMode.budgetLimit);
      await service.setCloudBudgetLimit(12.5);
      expect(service.cloudSpendingMode, CloudSpendingMode.budgetLimit);
      expect(service.cloudBudgetLimit, 12.5);

      await service.setCloudBudgetLimit(null);
      expect(service.cloudBudgetLimit, isNull);
    });

    test('persists memory window presets and custom values', () async {
      final service = await createService();

      await service.setMemoryWindowProfile(MemoryWindowProfile.custom);
      await service.setMemoryWindowCustomSettings(
        tokenBudget: 5120,
        lineBudget: 60,
      );

      expect(service.memoryWindowProfile, MemoryWindowProfile.custom);
      expect(service.customMemoryTokenBudget, 5120);
      expect(service.customMemoryLineBudget, 60);
      expect(service.memoryWindowConfig.maxTotalSize, 5120);
      expect(service.memoryWindowConfig.maxContextLines, 60);
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
      expect(config.maxTotalSize, 3072);
      expect(config.maxContextLines, 24);
    });
  });
}
