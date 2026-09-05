import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
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

enum CloudSpendingMode {
  freeOnly,
  prepaidOnly,
  budgetLimit,
  confirmBeforeSpending,
  unrestricted;

  static CloudSpendingMode fromStoredValue(String? value) {
    for (final mode in CloudSpendingMode.values) {
      if (mode.name == value) return mode;
    }
    return CloudSpendingMode.confirmBeforeSpending;
  }
}

/// Internet availability is independent from Local/Cloud/Hybrid routing.
enum InternetPolicy {
  always,
}

/// Persists runtime settings and notifies listeners when a setting changes.
class AiRuntimeSettingsService extends ChangeNotifier {
  AiRuntimeSettingsService({required ConfigRepository configRepository})
      : _configRepository = configRepository {
    CloudRuntimePreferences.instance.bind(
      preferredProvider: () => activeProvider,
      modelForProvider: cloudModelFor,
      automaticUseAllowed: (_) => automaticCloudSpendingAllowed,
    );
  }

  static const List<String> supportedProviders =
      CloudProviderCatalog.supportedProviders;

  static const String _cloudModelPrefix = 'cloud.provider.model.';
  static const String _cloudSpendingModeKey = 'cloud.spending.mode';
  static const String _cloudBudgetLimitKey = 'cloud.spending.budget_limit';

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

  String cloudModelFor(String provider) {
    final normalized = normalizeProvider(provider);
    final stored =
        _configRepository.getString('$_cloudModelPrefix$normalized')?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return CloudProviderCatalog.defaultModelFor(normalized);
  }

  Future<void> setCloudModel(
    String provider,
    String modelId,
  ) async {
    final normalized = normalizeProvider(provider);
    final model = modelId.trim();
    if (model.isEmpty) {
      await _configRepository.remove('$_cloudModelPrefix$normalized');
    } else {
      await _configRepository.setString('$_cloudModelPrefix$normalized', model);
    }
    notifyListeners();
  }

  CloudSpendingMode get cloudSpendingMode =>
      CloudSpendingMode.fromStoredValue(
        _configRepository.getString(_cloudSpendingModeKey),
      );

  /// Automatic paid Cloud calls are deliberately opt-in. Modes that require
  /// quota/cost verification remain blocked until a provider-specific billing
  /// adapter can prove the request satisfies that policy.
  bool get automaticCloudSpendingAllowed =>
      cloudSpendingMode == CloudSpendingMode.unrestricted;

  Future<void> setCloudSpendingMode(CloudSpendingMode mode) async {
    await _configRepository.setString(_cloudSpendingModeKey, mode.name);
    notifyListeners();
  }

  double? get cloudBudgetLimit {
    final value = double.tryParse(
      (_configRepository.getString(_cloudBudgetLimitKey) ?? '').trim(),
    );
    return value != null && value > 0 ? value : null;
  }

  Future<void> setCloudBudgetLimit(double? value) async {
    if (value == null || value <= 0) {
      await _configRepository.remove(_cloudBudgetLimitKey);
    } else {
      await _configRepository.setString(
        _cloudBudgetLimitKey,
        value.toStringAsFixed(4),
      );
    }
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

  MemoryWindowConfig get memoryWindowConfig => resolveMemoryWindowConfig();

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

  InternetPolicy get internetPolicy => InternetPolicy.always;

  int _readInt(String key, {required int fallback}) {
    final raw = _configRepository.getString(key);
    final parsed = int.tryParse((raw ?? '').trim());
    if (parsed == null) return fallback;
    return parsed > 0 ? parsed : fallback;
  }
}
