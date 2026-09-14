import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps an Android foreground execution lease alive while a Cloud response
/// is in flight.
///
/// The lease is deliberately best-effort: failure to start the native
/// foreground service must never turn a valid Cloud request into an error.
class CloudBackgroundExecutionLeaseService {
  CloudBackgroundExecutionLeaseService({
    MethodChannel? channel,
    TargetPlatform? platformOverride,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _platformOverride = platformOverride;

  static const String _channelName =
      'ai_orchestrator/cloud_background_execution';

  final MethodChannel _channel;
  final TargetPlatform? _platformOverride;

  static int _sequence = 0;

  bool get _isAndroid =>
      !kIsWeb &&
      (_platformOverride ?? defaultTargetPlatform) == TargetPlatform.android;

  Future<CloudBackgroundExecutionLease> acquire({
    required String sessionId,
    String providerHint = 'auto',
  }) async {
    final normalizedSession =
        sessionId.trim().isEmpty ? 'unknown' : sessionId.trim();
    final normalizedProvider =
        providerHint.trim().isEmpty ? 'auto' : providerHint.trim();
    final leaseId =
        'cloud-$normalizedSession-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

    if (!_isAndroid) {
      return CloudBackgroundExecutionLease._noop(leaseId);
    }

    try {
      await _channel.invokeMethod<void>('acquire', <String, Object>{
        'leaseId': leaseId,
        'sessionId': normalizedSession,
        'provider': normalizedProvider,
      });
      debugPrint(
        '[CLOUD_BACKGROUND] acquire_ok lease=$leaseId '
        'session=$normalizedSession provider=$normalizedProvider',
      );
      return CloudBackgroundExecutionLease._(
        leaseId: leaseId,
        releaseCallback: _releaseNative,
      );
    } catch (error) {
      debugPrint(
        '[CLOUD_BACKGROUND] acquire_skipped lease=$leaseId '
        'session=$normalizedSession error=$error',
      );
      return CloudBackgroundExecutionLease._noop(leaseId);
    }
  }

  Future<void> _releaseNative(String leaseId) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release', <String, Object>{
        'leaseId': leaseId,
      });
      debugPrint('[CLOUD_BACKGROUND] release_ok lease=$leaseId');
    } catch (error) {
      // Releasing a best-effort process-liveness lease must not alter the
      // inference result that has already completed.
      debugPrint(
        '[CLOUD_BACKGROUND] release_skipped lease=$leaseId error=$error',
      );
    }
  }
}

class CloudBackgroundExecutionLease {
  CloudBackgroundExecutionLease._({
    required this.leaseId,
    required Future<void> Function(String leaseId)? releaseCallback,
  }) : _releaseCallback = releaseCallback;

  factory CloudBackgroundExecutionLease._noop(String leaseId) =>
      CloudBackgroundExecutionLease._(
        leaseId: leaseId,
        releaseCallback: null,
      );

  final String leaseId;
  final Future<void> Function(String leaseId)? _releaseCallback;

  bool _released = false;

  bool get isReleased => _released;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    final callback = _releaseCallback;
    if (callback != null) {
      await callback(leaseId);
    }
  }
}
