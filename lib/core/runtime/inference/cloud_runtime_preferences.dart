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

  void bind({
    required String Function() preferredProvider,
    required String Function(String provider) modelForProvider,
    required bool Function(String provider) automaticUseAllowed,
  }) {
    _preferredProvider = preferredProvider;
    _modelForProvider = modelForProvider;
    _automaticUseAllowed = automaticUseAllowed;
  }

  String? get preferredProvider => _preferredProvider?.call();

  String? modelForProvider(String provider) => _modelForProvider?.call(provider);

  /// Fail closed until runtime settings bind the spending policy.
  ///
  /// Hybrid/automatic Cloud routing must never treat an unknown spending state
  /// as authorization. Once settings are bound, their current policy becomes
  /// authoritative for every provider request.
  bool automaticUseAllowed(String provider) =>
      _automaticUseAllowed?.call(provider) ?? false;
}
