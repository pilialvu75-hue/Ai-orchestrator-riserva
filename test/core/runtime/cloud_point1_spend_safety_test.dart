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

  test('AUTO free-first admits only recurring verified free tiers by default',
      () async {
    final service = await createService();

    expect(CloudProviderCatalog.costClassFor('gemini'),
        CloudProviderCostClass.freeTier);
    expect(CloudProviderCatalog.costClassFor('groq'),
        CloudProviderCostClass.freeTier);
    expect(CloudProviderCatalog.costClassFor('nvidiaNim'),
        CloudProviderCostClass.unknown);
    expect(CloudProviderCatalog.costClassFor('mistral'),
        CloudProviderCostClass.unknown);
    expect(CloudProviderCatalog.costClassFor('openRouter'),
        CloudProviderCostClass.unknown);

    expect(service.automaticCloudUseAllowed('gemini'), isTrue);
    expect(service.automaticCloudUseAllowed('groq'), isTrue);
    expect(service.automaticCloudUseAllowed('nvidiaNim'), isFalse);
    expect(service.automaticCloudUseAllowed('mistral'), isFalse);
    expect(service.automaticCloudUseAllowed('openRouter'), isFalse);
  });

  test('manual selection remains available while AUTO fails closed', () async {
    final service = await createService();

    await service.setManualCloudProvider('nvidiaNim');
    expect(service.manualCloudProvider, 'nvidiaNim');
    expect(service.automaticCloudUseAllowedForTask(
      'nvidiaNim',
      CloudTaskClass.general,
    ), isFalse);
  });

  test('unrestricted remains explicit authorization for uncertain access',
      () async {
    final service = await createService();

    await service.setCloudSpendingMode(CloudSpendingMode.unrestricted);
    expect(service.automaticCloudUseAllowed('nvidiaNim'), isTrue);
    expect(service.automaticCloudUseAllowed('mistral'), isTrue);
    expect(service.automaticCloudUseAllowed('openRouter'), isTrue);
  });
}
