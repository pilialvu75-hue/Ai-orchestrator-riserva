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

  /// Conservative default: before settings are bound, Cloud is allowed only
  /// by the existing provider-availability checks. Once bound, spending policy
  /// becomes authoritative.
  bool automaticUseAllowed(String provider) =>
      _automaticUseAllowed?.call(provider) ?? true;
}
