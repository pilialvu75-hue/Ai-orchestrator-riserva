import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';

enum AiRuntimeMode {
  local,
  cloud,
  hybrid;

  String get storageValue => name;

  static AiRuntimeMode fromStoredValue(String? value) {
    switch (value) {
      case 'local':
      case 'fast':
        return AiRuntimeMode.local;
      case 'cloud':
      case 'deep':
        return AiRuntimeMode.cloud;
      case 'hybrid':
      case 'balanced':
      default:
        return AiRuntimeMode.hybrid;
    }
  }
}

class AiRuntimeSettingsService {
  AiRuntimeSettingsService({required ConfigRepository configRepository})
      : _configRepository = configRepository;

  static const List<String> supportedProviders =
      CloudProviderCatalog.supportedProviders;

  final ConfigRepository _configRepository;

  AiRuntimeMode get runtimeMode => AiRuntimeMode.fromStoredValue(
      _configRepository.getString(AppConstants.prefAiMode));

  String get activeProvider =>
      normalizeProvider(_configRepository.getString(AppConstants.prefActiveProvider));

  Future<AiRuntimeMode> loadRuntimeMode() async => runtimeMode;

  Future<void> setRuntimeMode(AiRuntimeMode mode) async {
    await _configRepository.setString(
      AppConstants.prefAiMode,
      mode.storageValue,
    );
  }

  Future<void> setActiveProvider(String provider) async {
    await _configRepository.setString(
      AppConstants.prefActiveProvider,
      normalizeProvider(provider),
    );
  }

  String normalizeProvider(String? provider) {
    if (provider != null && supportedProviders.contains(provider)) {
      return provider;
    }
    return 'openAi';
  }
}
