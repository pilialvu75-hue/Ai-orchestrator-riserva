/// Abstract contract for remote runtime configuration.
///
/// Remote config allows changing app behaviour server-side without
/// shipping a new build. The interface is deliberately thin so that any
/// backend (Firebase Remote Config, a custom JSON endpoint, or an offline
/// stub) can be plugged in through the injection layer.
abstract class AbstractRemoteConfigService {
  /// Fetches the latest remote configuration values.
  ///
  /// Implementations must not throw; transient errors should be swallowed
  /// and the service should fall back to cached or default values.
  Future<void> fetch();

  /// Returns the raw string representation of [key], or [defaultValue]
  /// if the key is absent or remote config has not been fetched yet.
  String getValue(String key, {String defaultValue = ''});
}
