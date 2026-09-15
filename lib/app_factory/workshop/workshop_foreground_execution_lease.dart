import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Best-effort Android process-liveness lease for owner-started Cantiere work.
///
/// The native bridge is intentionally shared with Cloud inference so Android
/// runs one ref-counted foreground service instead of one service per feature.
/// The foreground service does not own Workshop execution: Flutter keeps the
/// authoritative task/runtime/workspace lifecycle and this lease only protects
/// it while the app is backgrounded.
class WorkshopForegroundExecutionLeaseService {
  WorkshopForegroundExecutionLeaseService({
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

  Future<WorkshopForegroundExecutionLease> acquire({
    required String operationId,
  }) async {
    final normalizedOperation =
        operationId.trim().isEmpty ? 'unknown' : operationId.trim();
    final leaseId =
        'workshop-$normalizedOperation-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

    if (!_isAndroid) {
      return WorkshopForegroundExecutionLease._noop(leaseId);
    }

    try {
      await _channel.invokeMethod<Object?>('acquire', <String, Object>{
        'leaseId': leaseId,
        'kind': 'workshop',
        'sessionId': normalizedOperation,
        'provider': 'workshop',
      });
      debugPrint(
        '[WORKSHOP_BACKGROUND] acquire_ok lease=$leaseId '
        'operation=$normalizedOperation',
      );
      return WorkshopForegroundExecutionLease._(
        leaseId: leaseId,
        releaseCallback: _releaseNative,
      );
    } catch (error) {
      // Process-liveness is an Android optimization. Failure to start a
      // foreground service must never turn a valid Cantiere task into a task
      // failure; durable Workshop recovery remains the fallback.
      debugPrint(
        '[WORKSHOP_BACKGROUND] acquire_skipped lease=$leaseId '
        'operation=$normalizedOperation error=$error',
      );
      return WorkshopForegroundExecutionLease._noop(leaseId);
    }
  }

  Future<void> _releaseNative(String leaseId) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<Object?>('release', <String, Object>{
        'leaseId': leaseId,
      });
      debugPrint('[WORKSHOP_BACKGROUND] release_ok lease=$leaseId');
    } catch (error) {
      debugPrint(
        '[WORKSHOP_BACKGROUND] release_skipped lease=$leaseId error=$error',
      );
    }
  }
}

class WorkshopForegroundExecutionLease {
  WorkshopForegroundExecutionLease._({
    required this.leaseId,
    required Future<void> Function(String leaseId)? releaseCallback,
  }) : _releaseCallback = releaseCallback;

  factory WorkshopForegroundExecutionLease._noop(String leaseId) =>
      WorkshopForegroundExecutionLease._(
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
