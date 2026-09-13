import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AiRuntimeSettingsService> createSettings() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    await CustomCloudProviderStore.instance.initialize(preferences: preferences);
    return AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(preferences)),
    );
  }

  group('Point 1.5 Free Intelligence Pool', () {
    test('registers provider-neutral system profiles without exposing them as user profiles', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = CustomCloudProviderStore.instance;
      await store.initialize(preferences: preferences);

      expect(store.profileFor('groq')?.endpoint,
          'https://api.groq.com/openai/v1/chat/completions');
      expect(store.profileFor('nvidiaNim')?.endpoint,
          'https://integrate.api.nvidia.com/v1/chat/completions');
      expect(store.profileFor('mistral')?.endpoint,
          'https://api.mistral.ai/v1/chat/completions');
      expect(store.profileFor('openRouter')?.endpoint,
          'https://openrouter.ai/api/v1/chat/completions');
      expect(store.profiles, isEmpty);
      expect(store.isSystemProfile('groq'), isTrue);
      expect(store.isSystemProfile('openRouter'), isTrue);
    });

    test('distinguishes access classes and fails closed for unverified free access', () async {
      final settings = await createSettings();

      expect(
        CloudProviderCatalog.accessClassFor('groq'),
        CloudProviderAccessClass.recurringFreeTier,
      );
      expect(
        CloudProviderCatalog.accessClassFor('nvidiaNim'),
        CloudProviderAccessClass.developmentPrototypeFreeAccess,
      );
      expect(
        CloudProviderCatalog.accessClassFor('mistral'),
        CloudProviderAccessClass.accountDependentFreeAccess,
      );
      expect(
        CloudProviderCatalog.accessClassFor('openRouter'),
        CloudProviderAccessClass.recurringFreeTier,
      );
      expect(
        CloudProviderCatalog.accessClassFor('openAi'),
        CloudProviderAccessClass.paid,
      );
      expect(
        CloudProviderCatalog.accessClassFor('copilot'),
        CloudProviderAccessClass.unknown,
      );

      for (final provider in <String>['groq', 'openRouter']) {
        expect(
          CloudProviderCatalog.costClassFor(provider),
          CloudProviderCostClass.freeTier,
        );
        expect(
          settings.automaticCloudUseAllowed(provider),
          isTrue,
          reason: '$provider is a verified recurring free-tier route',
        );
      }

      for (final provider in <String>[
        'nvidiaNim',
        'mistral',
      ]) {
        expect(
          CloudProviderCatalog.costClassFor(provider),
          CloudProviderCostClass.unknown,
          reason: '$provider must fail closed until free access is verified',
        );
        expect(
          settings.automaticCloudUseAllowed(provider),
          isFalse,
          reason: '$provider must not be auto-routed without verified free access',
        );
      }

      expect(settings.automaticCloudUseAllowed('openAi'), isFalse);
      expect(settings.automaticCloudUseAllowed('claude'), isFalse);
    });

    test('system free-pool providers are visible to normal Cloud selectors', () async {
      await createSettings();

      expect(
        CloudProviderCatalog.supportedProviders,
        containsAll(<String>['groq', 'nvidiaNim', 'mistral', 'openRouter']),
      );
      expect(
        CloudProviderCatalog.defaultModelFor('openRouter'),
        'openrouter/free',
      );
      expect(
        CloudProviderCatalog.defaultModelFor('mistral'),
        'mistral-small-latest',
      );
    });
  });
}
