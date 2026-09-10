import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';

/// Process-wide read-only bridge between persisted runtime settings and the
/// Cloud router.
///
/// The bridge contains no storage and no secrets. Settings bind lightweight
/// callbacks once; CloudRuntimeProvider reads the latest values at request time.
/// This avoids coupling the provider layer to Flutter UI or ConfigRepository.
final class CloudRuntimePreferences {
  CloudRuntimePreferences._();

  static final CloudRuntimePreferences instance = CloudRuntimePreferences._();

  String Function()? _preferredProvider;
  String Function(String provider)? _modelForProvider;
  bool Function(String provider)? _automaticUseAllowed;
  bool Function(String provider, CloudTaskClass task)?
      _automaticUseAllowedForTask;

  void bind({
    required String Function() preferredProvider,
    required String Function(String provider) modelForProvider,
    bool Function(String provider)? automaticUseAllowed,
    bool Function(String provider, CloudTaskClass task)? automaticUseAllowedForTask,
  }) {
    assert(
      automaticUseAllowed != null || automaticUseAllowedForTask != null,
      'A Cloud automatic spending policy must be bound.',
    );
    _preferredProvider = preferredProvider;
    _modelForProvider = modelForProvider;
    _automaticUseAllowed = automaticUseAllowed;
    _automaticUseAllowedForTask = automaticUseAllowedForTask;
  }

  String? get preferredProvider => _preferredProvider?.call();

  String? modelForProvider(String provider) => _modelForProvider?.call(provider);

  /// Compatibility authorization for callers that do not carry task intent.
  ///
  /// Task-aware settings are evaluated as [CloudTaskClass.general] here, so a
  /// provider that is authorized only for complex work never becomes generally
  /// spendable through a legacy caller.
  bool automaticUseAllowed(String provider) =>
      _automaticUseAllowed?.call(provider) ??
      _automaticUseAllowedForTask?.call(provider, CloudTaskClass.general) ??
      false;

  /// Request-specific automatic authorization.
  ///
  /// Fail closed until runtime settings bind a spending policy. The legacy
  /// provider-only callback remains supported for tests/older callers and is
  /// treated as authoritative for every task when it is the only policy bound.
  bool automaticUseAllowedForTask(String provider, CloudTaskClass task) =>
      _automaticUseAllowedForTask?.call(provider, task) ??
      _automaticUseAllowed?.call(provider) ??
      false;
}
