import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AiRuntimeSettingsService> createService() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    return AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(preferences)),
    );
  }

  test('AUTO free-first requires opt-in for conditional free-access tiers',
      () async {
    final service = await createService();

    expect(CloudProviderCatalog.costClassFor('gemini'),
        CloudProviderCostClass.freeTier);
    expect(CloudProviderCatalog.costClassFor('groq'),
        CloudProviderCostClass.unknown);
    expect(CloudProviderCatalog.costClassFor('nvidiaNim'),
        CloudProviderCostClass.unknown);
    expect(CloudProviderCatalog.costClassFor('mistral'),
        CloudProviderCostClass.unknown);
    expect(CloudProviderCatalog.costClassFor('openRouter'),
        CloudProviderCostClass.freeTier);

    expect(service.automaticCloudUseAllowed('gemini'), isTrue);
    expect(service.automaticCloudUseAllowed('openRouter'), isTrue);
    expect(service.automaticCloudUseAllowed('groq'), isFalse);
    expect(service.automaticCloudUseAllowed('nvidiaNim'), isFalse);
    expect(service.automaticCloudUseAllowed('mistral'), isFalse);

    for (final provider in <String>['groq', 'nvidiaNim', 'mistral']) {
      await service.setCloudProviderParticipatesInAuto(provider, true);
      expect(service.automaticCloudUseAllowed(provider), isTrue);
    }
  });

  test('manual selection remains independent from AUTO fallback eligibility',
      () async {
    final service = await createService();

    await service.setManualCloudProvider('nvidiaNim');
    expect(service.manualCloudProvider, 'nvidiaNim');
    expect(
      service.automaticCloudUseAllowedForTask(
        'nvidiaNim',
        CloudTaskClass.general,
      ),
      isFalse,
    );

    await service.setCloudProviderParticipatesInAuto('nvidiaNim', true);
    expect(service.manualCloudProvider, 'nvidiaNim');
    expect(
      service.automaticCloudUseAllowedForTask(
        'nvidiaNim',
        CloudTaskClass.general,
      ),
      isTrue,
    );
  });

  test('unrestricted spending does not bypass explicit AUTO participation',
      () async {
    final service = await createService();

    await service.setCloudSpendingMode(CloudSpendingMode.unrestricted);

    expect(service.automaticCloudUseAllowed('groq'), isFalse);
    expect(service.automaticCloudUseAllowed('nvidiaNim'), isFalse);
    expect(service.automaticCloudUseAllowed('mistral'), isFalse);
    expect(service.automaticCloudUseAllowed('copilot'), isFalse);
    expect(service.automaticCloudUseAllowed('openRouter'), isTrue);

    await service.setCloudProviderParticipatesInAuto('copilot', true);
    expect(service.automaticCloudUseAllowed('copilot'), isTrue);
  });
}
