import 'package:ai_orchestrator/core/app_health/contracts/abstract_remote_config_service.dart';

/// No-operation remote config implementation used when no remote backend
/// is configured.
///
/// [fetch] is a deliberate no-op; [getValue] always returns [defaultValue].
/// This ensures the rest of the codebase can call remote-config APIs safely
/// from day one without any network dependency.
///
/// Future hook: replace with a [FirebaseRemoteConfigService] that wraps
/// `firebase_remote_config` by rebinding [AbstractRemoteConfigService] in
/// [initDependencies].
class NoopRemoteConfigService implements AbstractRemoteConfigService {
  const NoopRemoteConfigService();

  @override
  Future<void> fetch() async {
    // Intentional no-op: no remote backend is configured yet.
  }

  @override
  String getValue(String key, {String defaultValue = ''}) {
    return defaultValue;
  }
}
