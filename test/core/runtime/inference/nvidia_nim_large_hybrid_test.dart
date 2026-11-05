import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
import 'package:ai_orchestrator/core/runtime/inference/custom_cloud_provider_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/nvidia_nim_large_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Hybrid uses the explicitly selected NVIDIA model ID without changing '
      'Cloud consent or activating AUTO', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    await CustomCloudProviderStore.instance.initialize(preferences: prefs);
    final settings = AiRuntimeSettingsService(
      configRepository: ConfigRepository(PreferencesService(prefs)),
    );
    // Settings bind the same model callback consumed by CloudRuntimeProvider
    // in both direct Cloud and Hybrid. No other provider identity is created.
    for (final id in <String>[
      NvidiaNimLargeModels.kimiK26,
      NvidiaNimLargeModels.deepSeekV41Flash,
    ]) {
      await settings.setCloudModel('nvidiaNim', id);
      expect(settings.cloudModelFor('nvidiaNim'), id);
      expect(CloudRuntimePreferences.instance.modelForProvider('nvidiaNim'), id);
      expect(settings.cloudProviderParticipatesInAuto('nvidiaNim'), isFalse);
    }

    // Existing AUTO participation is explicitly opt-in; selecting a model
    // must not enable it.
    await settings.setCloudProviderParticipatesInAuto('nvidiaNim', true);
    expect(settings.cloudProviderParticipatesInAuto('nvidiaNim'), isTrue);
    await settings.setCloudModel('nvidiaNim', NvidiaNimLargeModels.kimiK26);
    expect(settings.cloudProviderParticipatesInAuto('nvidiaNim'), isTrue);
    await settings.setCloudProviderParticipatesInAuto('nvidiaNim', false);
  });
}
