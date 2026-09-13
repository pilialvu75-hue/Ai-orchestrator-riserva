import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';
import 'package:ai_orchestrator/core/runtime/inference/memory_window_config.dart';

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
  complexTasksOnly,
  unrestricted;

  static CloudSpendingMode fromStoredValue(String? value) {
    for (final mode in CloudSpendingMode.values) {
      if (mode.name == value) return mode;
    }
    return CloudSpendingMode.complexTasksOnly;
  }
}

enum InternetPolicy { always }

class AiRuntimeSettingsService extends ChangeNotifier {
  AiRuntimeSettingsService({required ConfigRepository configRepository})
      : _configRepository = configRepository {
    CloudRuntimePreferences.instance.bind(
      preferredProvider: () => activeProvider,
      modelForProvider: cloudModelFor,
      automaticUseAllowedForTask: automaticCloudUseAllowedForTask,
    );
  }

  static List<String> get supportedProviders => CloudProviderCatalog.supportedProviders;
  static const String _cloudModelPrefix = 'cloud.provider.model.';
  static const String _cloudAutoParticipationPrefix = 'cloud.provider.auto_enabled.';
  static const String _cloudSpendingModeKey = 'cloud.spending.mode';
  static const String _cloudBudgetLimitKey = 'cloud.spending.budget_limit';
  static const String _manualCloudProviderKey = 'cloud.manual_provider';
  final ConfigRepository _configRepository;

  AiRuntimeMode get runtimeMode => AiRuntimeMode.fromStoredValue(_configRepository.getString(AppConstants.prefAiMode));
  String get activeProvider => normalizeProvider(_configRepository.getString(AppConstants.prefActiveProvider));

  String? get manualCloudProvider {
    final stored = _configRepository.getString(_manualCloudProviderKey)?.trim();
    if (stored == null || stored.isEmpty) return null;
    return supportedProviders.contains(stored) ? stored : null;
  }

  bool get isCloudProviderAutomatic => manualCloudProvider == null;
  Future<AiRuntimeMode> loadRuntimeMode() async => runtimeMode;

  Future<void> setRuntimeMode(AiRuntimeMode mode) async {
    await _configRepository.setString(AppConstants.prefAiMode, mode.storageValue);
    notifyListeners();
  }

  Future<void> setActiveProvider(String provider) async {
    await _configRepository.setString(AppConstants.prefActiveProvider, normalizeProvider(provider));
    notifyListeners();
  }

  Future<void> setManualCloudProvider(String? provider) async {
    final normalized = provider?.trim();
    if (normalized == null || normalized.isEmpty) {
      await _configRepository.remove(_manualCloudProviderKey);
      notifyListeners();
      return;
    }
    if (!supportedProviders.contains(normalized)) {
      throw ArgumentError.value(provider, 'provider', 'Unsupported Cloud provider.');
    }
    await _configRepository.setString(_manualCloudProviderKey, normalized);
    notifyListeners();
  }

  String cloudModelFor(String provider) {
    final normalized = normalizeProvider(provider);
    final stored = _configRepository.getString('$_cloudModelPrefix$normalized')?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return CloudProviderCatalog.defaultModelFor(normalized);
  }

  Future<void> setCloudModel(String provider, String modelId) async {
    final normalized = normalizeProvider(provider);
    final model = modelId.trim();
    if (model.isEmpty) {
      await _configRepository.remove('$_cloudModelPrefix$normalized');
    } else {
      await _configRepository.setString('$_cloudModelPrefix$normalized', model);
    }
    notifyListeners();
  }

  bool cloudProviderParticipatesInAuto(String provider) {
    final normalized = provider.trim();
    if (!supportedProviders.contains(normalized)) return false;
    return _configRepository.getBool('$_cloudAutoParticipationPrefix$normalized') ?? true;
  }

  Future<void> setCloudProviderParticipatesInAuto(String provider, bool enabled) async {
    final normalized = provider.trim();
    if (!supportedProviders.contains(normalized)) {
      throw ArgumentError.value(provider, 'provider', 'Unsupported Cloud provider.');
    }
    await _configRepository.setBool('$_cloudAutoParticipationPrefix$normalized', enabled);
    notifyListeners();
  }

  CloudSpendingMode get cloudSpendingMode => CloudSpendingMode.fromStoredValue(_configRepository.getString(_cloudSpendingModeKey));
  bool get automaticCloudSpendingAllowed => cloudSpendingMode == CloudSpendingMode.unrestricted;
  bool automaticCloudUseAllowed(String provider) => automaticCloudUseAllowedForTask(provider, CloudTaskClass.general);

  /// Authorizes automatic Cloud use without confusing access entitlement with
  /// billing cost. Recurring free tiers are always spend-safe. Development or
  /// account-dependent free access is also eligible when the user has left the
  /// provider opted into AUTO; this is the explicit participation consent and
  /// still does not authorize providers classified as paid. Promo credit and
  /// unknown access fail closed because neither proves that the next request is
  /// free. Paid routes keep the existing task-aware spending policy.
  bool automaticCloudUseAllowedForTask(String provider, CloudTaskClass task) {
    if (!cloudProviderParticipatesInAuto(provider)) return false;

    final accessClass = CloudProviderCatalog.accessClassFor(provider);
    switch (accessClass) {
      case CloudProviderAccessClass.recurringFreeTier:
      case CloudProviderAccessClass.developmentPrototypeFreeAccess:
      case CloudProviderAccessClass.accountDependentFreeAccess:
        return true;
      case CloudProviderAccessClass.promoCredit:
      case CloudProviderAccessClass.unknown:
        break;
      case CloudProviderAccessClass.paid:
        final costClass = CloudProviderCatalog.costClassFor(provider);
        switch (cloudSpendingMode) {
          case CloudSpendingMode.unrestricted:
            return true;
          case CloudSpendingMode.complexTasksOnly:
            return costClass == CloudProviderCostClass.paid && task != CloudTaskClass.general;
          case CloudSpendingMode.freeOnly:
          case CloudSpendingMode.prepaidOnly:
          case CloudSpendingMode.budgetLimit:
          case CloudSpendingMode.confirmBeforeSpending:
            return false;
        }
    }

    // Unknown/promo access remains fail-closed unless the user explicitly
    // authorizes unrestricted Cloud spending.
    return cloudSpendingMode == CloudSpendingMode.unrestricted;
  }

  Future<void> setCloudSpendingMode(CloudSpendingMode mode) async {
    await _configRepository.setString(_cloudSpendingModeKey, mode.name);
    notifyListeners();
  }

  double? get cloudBudgetLimit {
    final value = double.tryParse((_configRepository.getString(_cloudBudgetLimitKey) ?? '').trim());
    return value != null && value > 0 ? value : null;
  }

  Future<void> setCloudBudgetLimit(double? value) async {
    if (value == null || value <= 0) {
      await _configRepository.remove(_cloudBudgetLimitKey);
    } else {
      await _configRepository.setString(_cloudBudgetLimitKey, value.toStringAsFixed(4));
    }
    notifyListeners();
  }

  bool get developerMode => _configRepository.getBool(AppConstants.prefDeveloperMode) ?? false;

  Future<void> setDeveloperMode(bool enabled) async {
    await _configRepository.setBool(AppConstants.prefDeveloperMode, enabled);
    notifyListeners();
  }

  String normalizeProvider(String? provider) {
    if (provider != null && supportedProviders.contains(provider)) return provider;
    return 'openAi';
  }

  String? get selectedModelId => _configRepository.getString(AppConstants.prefSelectedModel);
  MemoryWindowProfile get memoryWindowProfile => MemoryWindowProfile.fromStoredValue(_configRepository.getString(AppConstants.prefMemoryWindowProfile));
  int get customMemoryTokenBudget => _readInt(AppConstants.prefMemoryWindowCustomTokenBudget, fallback: 8000);
  int get customMemoryLineBudget => _readInt(AppConstants.prefMemoryWindowCustomLineBudget, fallback: 60);

  Future<void> setMemoryWindowProfile(MemoryWindowProfile profile) async {
    await _configRepository.setString(AppConstants.prefMemoryWindowProfile, profile.name);
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomTokenBudget(int value) async {
    await _configRepository.setString(AppConstants.prefMemoryWindowCustomTokenBudget, value.toString());
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomLineBudget(int value) async {
    await _configRepository.setString(AppConstants.prefMemoryWindowCustomLineBudget, value.toString());
    notifyListeners();
  }

  Future<void> setMemoryWindowCustomSettings({required int tokenBudget, required int lineBudget}) async {
    await Future.wait<void>([
      _configRepository.setString(AppConstants.prefMemoryWindowCustomTokenBudget, tokenBudget.toString()),
      _configRepository.setString(AppConstants.prefMemoryWindowCustomLineBudget, lineBudget.toString()),
    ]);
    notifyListeners();
  }

  MemoryWindowConfig get memoryWindowConfig => resolveMemoryWindowConfig();

  MemoryWindowConfig resolveMemoryWindowConfig({String? modelId, bool isWeb = kIsWeb}) {
    switch (memoryWindowProfile) {
      case MemoryWindowProfile.compact:
        return MemoryWindowConfig.compact(isWeb: isWeb);
      case MemoryWindowProfile.standard:
        return MemoryWindowConfig.standard(isWeb: isWeb);
      case MemoryWindowProfile.performance:
        return MemoryWindowConfig.performance(isWeb: isWeb);
      case MemoryWindowProfile.custom:
        return MemoryWindowConfig.custom(maxContextLines: customMemoryLineBudget, maxTotalSize: customMemoryTokenBudget, isWeb: isWeb);
      case MemoryWindowProfile.automatic:
        return MemoryWindowConfig.automatic(modelId: modelId ?? selectedModelId, isWeb: isWeb);
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
