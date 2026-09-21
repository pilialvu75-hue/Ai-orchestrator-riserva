import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:ai_orchestrator/core/app_health/contracts/abstract_telemetry_service.dart';

/// Privacy-conscious PostHog-backed telemetry.
///
/// Design constraints:
/// - never blocks or crashes the application if telemetry fails;
/// - keeps a local debug trace on every platform;
/// - only enables the remote SDK on Flutter platforms supported by PostHog;
/// - never forwards raw exception messages;
/// - redacts properties whose keys can carry user content or credentials;
/// - does not identify users and does not enable session replay.
///
/// The PostHog project token is a public client token, not a secret API key.
class PostHogTelemetryService implements AbstractTelemetryService {
  PostHogTelemetryService._({
    required bool remoteRequested,
    required bool supportedPlatform,
  })  : _remoteRequested = remoteRequested,
        _supportedPlatform = supportedPlatform;

  static const String defaultHost = 'https://eu.i.posthog.com';
  static const String _tag = '[Telemetry/PostHog]';

  final bool _remoteRequested;
  final bool _supportedPlatform;
  bool _ready = false;

  bool get remoteEnabled => _ready;

  static bool get _isSupportedPlatform {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static Future<PostHogTelemetryService> create({
    required String projectToken,
    String host = defaultHost,
    bool enabled = true,
  }) async {
    final requested = enabled && projectToken.trim().isNotEmpty;
    final supported = _isSupportedPlatform;
    final service = PostHogTelemetryService._(
      remoteRequested: requested,
      supportedPlatform: supported,
    );

    if (!requested || !supported) {
      debugPrint(
        '$_tag remote disabled '
        '(requested=$requested supportedPlatform=$supported)',
      );
      return service;
    }

    try {
      final config = PostHogConfig(projectToken.trim());
      config.host = host;
      config.debug = false;
      await Posthog().setup(config);
      service._ready = true;
      debugPrint('$_tag remote telemetry ready host=$host');
    } catch (error, stackTrace) {
      debugPrint('$_tag setup failed; continuing local-only: $error');
      debugPrint('$_tag setup stackTrace=$stackTrace');
    }

    return service;
  }

  @override
  void logCrash(
    Object error, {
    StackTrace? stackTrace,
    String? context,
  }) {
    final safeContext = _safeLabel(context);
    debugPrint(
      '$_tag CRASH type=${error.runtimeType} '
      'context=${safeContext ?? "none"}',
    );
    if (stackTrace != null) {
      debugPrint('$_tag CRASH stackTrace=$stackTrace');
    }
    if (!_ready) return;

    unawaited(
      _guard(
        () => Posthog().captureException(
          // Do not forward error.toString(): runtime errors can contain prompts,
          // file paths, provider responses, credentials, or other user data.
          error: Exception('redacted:${error.runtimeType}'),
          stackTrace: stackTrace,
          properties: <String, Object>{
            'severity': 'fatal',
            'error_type': error.runtimeType.toString(),
            if (safeContext != null) 'context': safeContext,
          },
        ),
      ),
    );
  }

  @override
  void logEvent(
    String name, {
    Map<String, Object>? parameters,
  }) {
    final safeName = _safeEventName(name);
    final safeParameters = _redactParameters(parameters);
    debugPrint(
      '$_tag EVENT $safeName'
      '${safeParameters.isEmpty ? "" : " params=$safeParameters"}',
    );
    if (!_ready) return;

    unawaited(
      _guard(
        () => Posthog().capture(
          eventName: safeName,
          properties: safeParameters.isEmpty ? null : safeParameters,
        ),
      ),
    );
  }

  @override
  void logError(
    Object error, {
    StackTrace? stackTrace,
    String? reason,
  }) {
    final safeReason = _safeLabel(reason);
    debugPrint(
      '$_tag ERROR type=${error.runtimeType} '
      'reason=${safeReason ?? "none"}',
    );
    if (stackTrace != null) {
      debugPrint('$_tag ERROR stackTrace=$stackTrace');
    }
    if (!_ready) return;

    unawaited(
      _guard(
        () => Posthog().captureException(
          error: Exception('redacted:${error.runtimeType}'),
          stackTrace: stackTrace,
          properties: <String, Object>{
            'severity': 'error',
            'error_type': error.runtimeType.toString(),
            if (safeReason != null) 'reason': safeReason,
          },
        ),
      ),
    );
  }

  @override
  PerformanceTrace startTrace(String name) {
    return _PostHogPerformanceTrace(
      telemetry: this,
      name: _safeEventName(name),
    );
  }

  Future<void> _captureTrace(String name, int elapsedMs) {
    if (!_ready) return Future<void>.value();
    return _guard(
      () => Posthog().capture(
        eventName: 'performance_trace',
        properties: <String, Object>{
          'trace_name': name,
          'elapsed_ms': elapsedMs,
        },
      ),
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      // Telemetry must always fail open. Never recurse through logError here.
      debugPrint('$_tag remote operation failed: $error');
      debugPrint('$_tag remote stackTrace=$stackTrace');
    }
  }

  static String _safeEventName(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (normalized.isEmpty) return 'telemetry_event';
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  static String? _safeLabel(String? value) {
    if (value == null) return null;
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;
    return normalized.length <= 120
        ? normalized
        : '${normalized.substring(0, 120)}…';
  }

  static Map<String, Object> _redactParameters(
    Map<String, Object>? parameters,
  ) {
    if (parameters == null || parameters.isEmpty) {
      return const <String, Object>{};
    }

    final result = <String, Object>{};
    for (final entry in parameters.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      if (_looksSensitiveKey(key)) {
        result[key] = '[redacted]';
        continue;
      }

      final value = entry.value;
      if (value is String) {
        result[key] = _safeLabel(value) ?? '';
      } else if (value is num || value is bool) {
        result[key] = value;
      } else {
        // Complex objects can hide arbitrary user content. Keep only their type.
        result[key] = '[${value.runtimeType}]';
      }
    }
    return result;
  }

  static bool _looksSensitiveKey(String key) {
    final lower = key.toLowerCase();
    const fragments = <String>[
      'prompt',
      'message',
      'content',
      'text',
      'query',
      'token',
      'api_key',
      'apikey',
      'secret',
      'password',
      'authorization',
      'cookie',
      'email',
      'phone',
      'file_path',
      'filepath',
      'model_path',
      'user_path',
    ];
    return fragments.any(lower.contains);
  }
}

class _PostHogPerformanceTrace implements PerformanceTrace {
  _PostHogPerformanceTrace({
    required PostHogTelemetryService telemetry,
    required String name,
  })  : _telemetry = telemetry,
        _name = name,
        _start = DateTime.now();

  final PostHogTelemetryService _telemetry;
  final String _name;
  final DateTime _start;
  bool _stopped = false;

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    final elapsedMs = DateTime.now().difference(_start).inMilliseconds;
    debugPrint('${PostHogTelemetryService._tag} TRACE $_name elapsed=${elapsedMs}ms');
    unawaited(_telemetry._captureTrace(_name, elapsedMs));
  }
}
