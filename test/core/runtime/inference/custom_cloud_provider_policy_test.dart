import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AiRuntimeSettingsService> createService() async {
    final preferences = await SharedPreferences.getInstance();
    return AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(preferences)),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    await CustomCloudProviderStore.instance.initialize(preferences: preferences);
  });

  test('custom Free route participates in AUTO spend-safe policy', () async {
    final profile = await CustomCloudProviderStore.instance.create(
      displayName: 'Future Free',
      endpoint: 'https://free.example.test/v1/chat/completions',
      defaultModel: 'free-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    );
    final service = await createService();

    expect(service.automaticCloudUseAllowed(profile.id), isTrue);
    await service.setManualCloudProvider(profile.id);
    expect(service.manualCloudProvider, profile.id);
    expect(service.cloudModelFor(profile.id), 'free-1');
  });

  test('custom Paid route remains blocked from AUTO until unrestricted', () async {
    final profile = await CustomCloudProviderStore.instance.create(
      displayName: 'Future Paid',
      endpoint: 'https://paid.example.test/v1/chat/completions',
      defaultModel: 'paid-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.paid,
    );
    final service = await createService();

    expect(service.automaticCloudUseAllowed(profile.id), isFalse);

    await service.setCloudSpendingMode(CloudSpendingMode.unrestricted);
    expect(service.automaticCloudUseAllowed(profile.id), isTrue);
  });
}
