import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';

enum AiRuntimeMode {
  local,
  cloud,
  hybrid;

  String get storageValue => name;

  static AiRuntimeMode fromStoredValue(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'local':
      case 'local_ai':
      case 'on_device':
      case 'ai_runtime_mode_local':
      case 'fast':
        return AiRuntimeMode.local;
      case 'cloud':
      case 'remote':
      case 'ai_runtime_mode_cloud':
      case 'deep':
        return AiRuntimeMode.cloud;
      case 'hybrid':
      case 'ai_runtime_mode_hybrid':
      case 'balanced':
      default:
        return AiRuntimeMode.hybrid;
    }
  }
}

class AiRuntimeSettingsService extends ChangeNotifier {
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
    notifyListeners();
  }

  Future<void> setActiveProvider(String provider) async {
    await _configRepository.setString(
      AppConstants.prefActiveProvider,
      normalizeProvider(provider),
    );
    notifyListeners();
  }

  bool get developerMode =>
      _configRepository.getBool(AppConstants.prefDeveloperMode) ?? false;

  Future<void> setDeveloperMode(bool enabled) async {
    await _configRepository.setBool(
      AppConstants.prefDeveloperMode,
      enabled,
    );
    notifyListeners();
  }

  String normalizeProvider(String? provider) {
    if (provider != null && supportedProviders.contains(provider)) {
      return provider;
    }
    return 'openAi';
  }

  String? get selectedModelId =>
      _configRepository.getString(AppConstants.prefSelectedModel);

  MemoryWindowProfile get memoryWindowProfile =>
      MemoryWindowProfile.fromStoredValue(
        _configRepository.getString(AppConstants.prefMemoryWindowProfile),
      );

  int get customMemoryTokenBudget => _readInt(
        AppConstants.prefMemoryWindowCustomTokenBudget,
        fallback: 8000,
      );

  int get customMemoryLineBudget => _readInt(
        AppConstants.prefMemoryWindowCustomLineBudget,
        fallback: 60,
      );

  Future<void> setMemoryWindowProfile(MemoryWindowProfile profile) async {
    await _configRepository.setString(
      AppConstants.prefMemoryWindowProfile,
      profile.name,
    );
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomTokenBudget(int value) async {
    await _configRepository.setString(
      AppConstants.prefMemoryWindowCustomTokenBudget,
      value.toString(),
    );
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomLineBudget(int value) async {
    await _configRepository.setString(
      AppConstants.prefMemoryWindowCustomLineBudget,
      value.toString(),
    );
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomSettings({
    required int tokenBudget,
    required int lineBudget,
  }) async {
    await Future.wait<void>([
      _configRepository.setString(
        AppConstants.prefMemoryWindowCustomTokenBudget,
        tokenBudget.toString(),
      ),
      _configRepository.setString(
        AppConstants.prefMemoryWindowCustomLineBudget,
        lineBudget.toString(),
      ),
    ]);
    notifyListeners();
  }

  MemoryWindowConfig get memoryWindowConfig =>
      resolveMemoryWindowConfig();

  MemoryWindowConfig resolveMemoryWindowConfig({
    String? modelId,
    bool isWeb = kIsWeb,
  }) {
    switch (memoryWindowProfile) {
      case MemoryWindowProfile.compact:
        return MemoryWindowConfig.compact(isWeb: isWeb);
      case MemoryWindowProfile.standard:
        return MemoryWindowConfig.standard(isWeb: isWeb);
      case MemoryWindowProfile.performance:
        return MemoryWindowConfig.performance(isWeb: isWeb);
      case MemoryWindowProfile.custom:
        return MemoryWindowConfig.custom(
          maxContextLines: customMemoryLineBudget,
          maxTotalSize: customMemoryTokenBudget,
          isWeb: isWeb,
        );
      case MemoryWindowProfile.automatic:
        return MemoryWindowConfig.automatic(
          modelId: modelId ?? selectedModelId,
          isWeb: isWeb,
        );
    }
  }

  int _readInt(String key, {required int fallback}) {
    final raw = _configRepository.getString(key);
    final parsed = int.tryParse((raw ?? '').trim());
    if (parsed == null) {
      return fallback;
    }
    return parsed > 0 ? parsed : fallback;
  }
}
