import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Best-effort platform lease used to keep an explicit Cloud response alive
/// while the app is no longer the foreground activity.
///
/// The lease never owns inference, credentials, routing or persistence. Those
/// remain in the existing ChatRepository / InferenceService pipeline. Its only
/// responsibility is asking the platform to keep the current process eligible
/// to finish an already user-started Cloud request.
abstract interface class CloudBackgroundExecutionLease {
  Future<void> acquire(String leaseId);

  Future<void> release(String leaseId);
}

/// Android implementation backed by a short-lived foreground service.
///
/// Failures are deliberately non-fatal: inability to promote the process must
/// not change provider routing or turn an otherwise valid Cloud request into a
/// failed request. Diagnostics are emitted so device certification can detect
/// when background protection was unavailable.
final class PlatformCloudBackgroundExecutionLease
    implements CloudBackgroundExecutionLease {
  const PlatformCloudBackgroundExecutionLease();

  static const MethodChannel _channel =
      MethodChannel('ai_orchestrator/cloud_background');

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> acquire(String leaseId) async {
    if (!_supported) return;
    await _invokeBestEffort('acquire', leaseId);
  }

  @override
  Future<void> release(String leaseId) async {
    if (!_supported) return;
    await _invokeBestEffort('release', leaseId);
  }

  Future<void> _invokeBestEffort(String method, String leaseId) async {
    try {
      await _channel.invokeMethod<void>(
        method,
        <String, Object>{'leaseId': leaseId},
      );
      debugPrint(
        '[CLOUD_BACKGROUND] action=$method lease=$leaseId status=ok',
      );
    } on MissingPluginException catch (error) {
      debugPrint(
        '[CLOUD_BACKGROUND] action=$method lease=$leaseId '
        'status=unavailable error=$error',
      );
    } on PlatformException catch (error) {
      debugPrint(
        '[CLOUD_BACKGROUND] action=$method lease=$leaseId '
        'status=platform_error code=${error.code}',
      );
    } catch (error) {
      debugPrint(
        '[CLOUD_BACKGROUND] action=$method lease=$leaseId '
        'status=error error=$error',
      );
    }
  }
}
