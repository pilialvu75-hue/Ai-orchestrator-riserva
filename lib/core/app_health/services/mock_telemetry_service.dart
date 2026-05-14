import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/app_health/contracts/abstract_telemetry_service.dart';

/// Offline-safe telemetry implementation that writes to the Flutter debug
/// console instead of any remote backend.
///
/// This service is the default registered implementation and acts as a
/// safe no-crash fallback in all environments (CI, debug, offline).
///
/// Future hook: replace with [FirebaseTelemetryService] by rebinding the
/// [AbstractTelemetryService] registration in [initDependencies].
class MockTelemetryService implements AbstractTelemetryService {
  const MockTelemetryService();

  static const String _tag = '[Telemetry]';

  @override
  void logCrash(
    Object error, {
    StackTrace? stackTrace,
    String? context,
  }) {
    final label = context != null ? '[$context] ' : '';
    debugPrint('$_tag CRASH ${label}error=$error');
    if (stackTrace != null) {
      debugPrint('$_tag CRASH stackTrace=$stackTrace');
    }
  }

  @override
  void logEvent(String name, {Map<String, Object>? parameters}) {
    if (parameters != null && parameters.isNotEmpty) {
      debugPrint('$_tag EVENT $name params=$parameters');
    } else {
      debugPrint('$_tag EVENT $name');
    }
  }

  @override
  void logError(
    Object error, {
    StackTrace? stackTrace,
    String? reason,
  }) {
    final label = reason != null ? '[$reason] ' : '';
    debugPrint('$_tag ERROR ${label}error=$error');
    if (stackTrace != null) {
      debugPrint('$_tag ERROR stackTrace=$stackTrace');
    }
  }

  @override
  PerformanceTrace startTrace(String name) => _MockPerformanceTrace(name);
}

/// Stub trace that measures wall-clock time and logs it on [stop].
class _MockPerformanceTrace implements PerformanceTrace {
  _MockPerformanceTrace(this._name) : _start = DateTime.now();

  final String _name;
  final DateTime _start;

  @override
  void stop() {
    final elapsed = DateTime.now().difference(_start);
    debugPrint('[Telemetry] TRACE $_name elapsed=${elapsed.inMilliseconds}ms');
  }
}
