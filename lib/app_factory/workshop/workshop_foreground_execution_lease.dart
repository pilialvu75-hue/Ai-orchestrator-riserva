import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class WorkshopExecutionLease {
  Future<void> release();
}

abstract interface class WorkshopExecutionLeaseService {
  Future<WorkshopExecutionLease> acquire({
    required String operationId,
  });
}

/// Best-effort Android process-liveness lease for owner-started Cantiere work.
///
/// The native bridge is intentionally shared with Cloud inference so Android
/// runs one ref-counted foreground service instead of one service per feature.
/// The foreground service does not own Workshop execution: Flutter keeps the
/// authoritative task/runtime/workspace lifecycle and this lease only protects
/// it while the app is backgrounded.
final class WorkshopForegroundExecutionLeaseService
    implements WorkshopExecutionLeaseService {
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

  @override
  Future<WorkshopExecutionLease> acquire({
    required String operationId,
  }) async {
    final normalizedOperation =
        operationId.trim().isEmpty ? 'unknown' : operationId.trim();
    final leaseId =
        'workshop-$normalizedOperation-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

    if (!_isAndroid) {
      return _WorkshopForegroundExecutionLease.noop(leaseId);
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
      return _WorkshopForegroundExecutionLease(
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
      return _WorkshopForegroundExecutionLease.noop(leaseId);
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

final class _WorkshopForegroundExecutionLease
    implements WorkshopExecutionLease {
  _WorkshopForegroundExecutionLease({
    required this.leaseId,
    required Future<void> Function(String leaseId)? releaseCallback,
  }) : _releaseCallback = releaseCallback;

  factory _WorkshopForegroundExecutionLease.noop(String leaseId) =>
      _WorkshopForegroundExecutionLease(
        leaseId: leaseId,
        releaseCallback: null,
      );

  final String leaseId;
  final Future<void> Function(String leaseId)? _releaseCallback;

  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    final callback = _releaseCallback;
    if (callback != null) {
      await callback(leaseId);
    }
  }
}
