import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';

void main() {
  Future<AiRuntimeSettingsService> service() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    return AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(preferences)),
    );
  }

  test('AUTO requires opt-in for account/prototype free-access fallback tiers',
      () async {
    final settings = await service();

    // Durable recurring free tiers remain first-class AUTO candidates.
    expect(settings.automaticCloudUseAllowed('gemini'), isTrue);
    expect(settings.automaticCloudUseAllowed('openRouter'), isTrue);

    // Account- or plan-dependent access fails closed until the user explicitly
    // opts the route into AUTO.
    for (final provider in <String>['groq', 'nvidiaNim', 'mistral']) {
      expect(settings.automaticCloudUseAllowed(provider), isFalse);
      await settings.setCloudProviderParticipatesInAuto(provider, true);
      expect(settings.automaticCloudUseAllowed(provider), isTrue);
    }

    // Paid and unknown-access providers remain protected for general chat.
    expect(settings.automaticCloudUseAllowed('claude'), isFalse);
    expect(settings.automaticCloudUseAllowed('openAi'), isFalse);
    expect(settings.automaticCloudUseAllowed('copilot'), isFalse);
  });

  test('AUTO participation switch remains authoritative for fallback tiers',
      () async {
    final settings = await service();

    expect(settings.automaticCloudUseAllowed('nvidiaNim'), isFalse);
    await settings.setCloudProviderParticipatesInAuto('nvidiaNim', true);
    expect(settings.automaticCloudUseAllowed('nvidiaNim'), isTrue);
    await settings.setCloudProviderParticipatesInAuto('nvidiaNim', false);
    expect(settings.automaticCloudUseAllowed('nvidiaNim'), isFalse);
  });

  test('paid complex-task policy is unchanged', () async {
    final settings = await service();

    expect(
      settings.automaticCloudUseAllowedForTask('claude', CloudTaskClass.coding),
      isTrue,
    );
    expect(
      settings.automaticCloudUseAllowedForTask('claude', CloudTaskClass.general),
      isFalse,
    );
  });
}
