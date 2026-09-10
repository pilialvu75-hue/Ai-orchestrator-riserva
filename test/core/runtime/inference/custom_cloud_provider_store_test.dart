import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    await CustomCloudProviderStore.instance.initialize(preferences: preferences);
  });

  test('custom free provider becomes a first-class catalog entry', () async {
    final profile = await CustomCloudProviderStore.instance.create(
      displayName: 'Future Free AI',
      endpoint: 'https://example.test/v1/chat/completions',
      defaultModel: 'future-code-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    );

    expect(CloudProviderCatalog.supportedProviders, contains(profile.id));
    final definition = CloudProviderCatalog.definitionFor(profile.id);
    expect(definition, isNotNull);
    expect(definition!.displayName, 'Future Free AI');
    expect(definition.defaultModel, 'future-code-1');
    expect(definition.costClass, CloudProviderCostClass.freeTier);
    expect(definition.isCustom, isTrue);
    expect(
      CloudProviderCatalog.supports(
        profile.id,
        CloudProviderCapability.coding,
      ),
      isTrue,
    );
  });

  test('custom paid provider remains spend-policy paid', () async {
    final profile = await CustomCloudProviderStore.instance.create(
      displayName: 'Future Premium AI',
      endpoint: 'https://premium.example.test/messages',
      defaultModel: 'premium-1',
      protocol: CustomCloudProviderProtocol.anthropicCompatible,
      billing: CustomCloudProviderBilling.paid,
    );

    expect(
      CloudProviderCatalog.costClassFor(profile.id),
      CloudProviderCostClass.paid,
    );
  });

  test('profiles persist and reload without storing credentials in metadata', () async {
    final profile = await CustomCloudProviderStore.instance.create(
      displayName: 'Persistent AI',
      endpoint: 'https://persistent.example.test/v1/chat/completions',
      defaultModel: 'persistent-1',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    );

    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('cloud.custom.providers.v1');
    expect(raw, isNotNull);
    expect(raw, isNot(contains('apiKey')));
    expect(raw, isNot(contains('secret')));

    await CustomCloudProviderStore.instance.initialize(preferences: preferences);
    expect(CustomCloudProviderStore.instance.profileFor(profile.id), isNotNull);
  });

  test('plain HTTP remote endpoints are rejected', () async {
    expect(
      () => CustomCloudProviderStore.instance.create(
        displayName: 'Unsafe AI',
        endpoint: 'http://example.test/v1/chat/completions',
        defaultModel: 'unsafe-1',
        protocol: CustomCloudProviderProtocol.openAiCompatible,
        billing: CustomCloudProviderBilling.free,
      ),
      throwsArgumentError,
    );
  });
}
