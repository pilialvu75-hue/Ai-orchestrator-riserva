import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_self_test_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Explicitly opted-in, loopback-only test interface for the running AIVEXUS app.
///
/// This is NOT the existing CRDT sync server, a remote administration API,
/// a generic command runner, or a second inference engine.
class AivexusTestBridgeServer {
  AivexusTestBridgeServer({
    required this.token,
    required this.appVersion,
    required this.runtimeSelfTest,
    required this.runtimeDiagnostics,
    required this.localModels,
    this.port = 47941,
  }) : instanceId = const Uuid().v4();

  static const _seenKey = 'chatgpt_bridge_seen_request_ids_v1';
  static const _maxRememberedIds = 512;
  static const _maxRequestBytes = 4096;

  final String token;
  final String appVersion;
  final String instanceId;
  final int port;
  final RuntimeSelfTestService runtimeSelfTest;
  final LocalRuntimeDiagnosticsService runtimeDiagnostics;
  final LocalAiRepository localModels;

  HttpServer? _server;
  SharedPreferences? _prefs;
  final Map<String, _BridgeTest> _tests = <String, _BridgeTest>{};
  final List<String> _seen = <String>[];

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    if (token.length < 32) {
      throw StateError('Bridge token must contain at least 32 characters.');
    }
    _prefs = await SharedPreferences.getInstance();
    _seen
      ..clear()
      ..addAll(_prefs!.getStringList(_seenKey) ?? const <String>[]);
    // Binding to a specific loopback address prevents exposure on the LAN.
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    for (final test in _tests.values) {
      test.cancellation.cancel();
    }
  }

  bool _authorized(HttpRequest request) {
    final actual = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final expected = 'Bearer ' + token;
    // Constant-work comparison for a fixed-length, local bearer token.
    var mismatch = actual.length ^ expected.length;
    for (var index = 0; index < expected.length; index++) {
      final unit = index < actual.length ? actual.codeUnitAt(index) : 0;
      mismatch |= unit ^ expected.codeUnitAt(index);
    }
    return mismatch == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!_authorized(request)) {
        await _send(request, HttpStatus.unauthorized, <String, Object?>{
          'error': 'unauthorized',
        });
        return;
      }
      // Browser-originated requests are not part of the local MCP transport.
      if (request.headers.value('origin') != null) {
        await _send(request, HttpStatus.forbidden, <String, Object?>{
          'error': 'browser_origin_not_allowed',
        });
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/instance') {
        await _send(request, HttpStatus.ok, await _instance());
      } else if (request.method == 'GET' &&
          path == '/v1/diagnostics') {
        final id = request.uri.queryParameters['request_id'];
        await _send(request, HttpStatus.ok, <String, Object?>{
          'instance_id': instanceId,
          'runtime_status': runtimeDiagnostics.monitor.state.status.name,
          'test': _lookup(id),
          // No raw logs: they may contain file paths or sensitive content.
          'raw_logs_exposed': false,
        });
      } else if (request.method == 'POST' && path == '/v1/tests') {
        final body = await _readJson(request);
        final id = body['request_id'];
        if (id is! String ||
            !RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(id) ||
            body['kind'] != 'runtime') {
          await _send(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'invalid_or_unsupported_test',
            'supported_kinds': <String>['runtime'],
          });
          return;
        }
        if (_seen.contains(id)) {
          await _send(request, HttpStatus.ok, _lookup(id));
          return;
        }
        if (_tests.values.any((test) =>
            test.status == 'running' || test.status == 'queued' ||
            test.status == 'cancel_requested')) {
          await _send(request, HttpStatus.conflict, <String, Object?>{
            'error': 'test_already_running',
          });
          return;
        }
        // Persist the id BEFORE dispatch. A retry after an app restart will
        // report interrupted_after_restart instead of executing a second time.
        _seen.add(id);
        if (_seen.length > _maxRememberedIds) _seen.removeAt(0);
        if (!await _prefs!.setStringList(_seenKey, _seen)) {
          _seen.remove(id);
          await _send(request, HttpStatus.serviceUnavailable,
              <String, Object?>{'error': 'idempotency_storage_unavailable'});
          return;
        }
        final test = _BridgeTest(id);
        _tests[id] = test;
        unawaited(_runTest(test));
        await _send(request, HttpStatus.accepted, test.snapshot());
      } else if (request.method == 'GET' &&
          path.startsWith('/v1/tests/')) {
        final id = path.substring('/v1/tests/'.length);
        await _send(request, HttpStatus.ok, _lookup(id));
      } else if (request.method == 'POST' &&
          path.startsWith('/v1/tests/') && path.endsWith('/cancel')) {
        final id = path.substring('/v1/tests/'.length, path.length - '/cancel'.length);
        final test = _tests[id];
        if (test == null) {
          await _send(request, HttpStatus.notFound, <String, Object?>{
            'error': 'test_not_active',
          });
          return;
        }
        if (test.status == 'running' || test.status == 'queued') {
          test.cancellation.cancel();
          test.status = 'cancel_requested';
        }
        await _send(request, HttpStatus.ok, test.snapshot());
      } else {
        await _send(request, HttpStatus.notFound,
            <String, Object?>{'error': 'not_found'});
      }
    } on FormatException {
      await _send(request, HttpStatus.badRequest,
          <String, Object?>{'error': 'invalid_request'});
    } catch (_) {
      // Never serialize exceptions or stack traces to MCP.
      await _send(request, HttpStatus.internalServerError,
          <String, Object?>{'error': 'bridge_internal_error'});
    }
  }

  Future<Map<String, Object?>> _instance() async {
    final result = await localModels.getSelectedModel();
    final selected = result.fold((_) => null, (model) => model);
    return <String, Object?>{
      'instance_id': instanceId,
      'app_version': appVersion,
      'platform': Platform.operatingSystem,
      'engine_adapter': 'app_local_runtime_provider',
      'engine_version': null, // Do not invent a llama.cpp build identifier.
      'model': selected?.effectiveRuntimeModelId,
      'runtime_status': runtimeDiagnostics.monitor.state.status.name,
      'transport': 'authenticated_loopback',
      'test_capabilities': <String>['runtime'],
      'app_pipeline_test_available': false,
    };
  }

  Map<String, Object?> _lookup(String? id) {
    if (id == null || !RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(id)) {
      return <String, Object?>{'error': 'invalid_request_id'};
    }
    final test = _tests[id];
    if (test != null) return test.snapshot();
    if (_seen.contains(id)) {
      return <String, Object?>{
        'request_id': id,
        'status': 'interrupted_after_restart',
        'restarted': false,
      };
    }
    return <String, Object?>{'request_id': id, 'status': 'unknown'};
  }

  Future<void> _runTest(_BridgeTest test) async {
    test.status = 'running';
    final watch = Stopwatch()..start();
    try {
      final result = await runtimeSelfTest.run(
        cancellationToken: test.cancellation,
      );
      if (test.cancellation.isCancelled) {
        test.status = 'cancelled';
      } else {
        test.status = result.success ? 'completed' : 'failed';
      }
      test.success = result.success && !test.cancellation.isCancelled;
      // The self-test summary contains local file paths. Do not return it.
      if (!test.success && test.status != 'cancelled') {
        final summary = result.summary.toLowerCase();
        test.errorCode = summary.contains('model') && summary.contains('missing')
            ? 'model_unavailable'
            : summary.contains('timeout') || summary.contains('timed out')
                ? 'runtime_timeout'
                : 'runtime_self_test_failed';
      }
    } catch (_) {
      test.status = test.cancellation.isCancelled ? 'cancelled' : 'failed';
      test.success = false;
      test.errorCode = 'runtime_self_test_exception';
    } finally {
      watch.stop();
      test.elapsedMs = watch.elapsedMilliseconds;
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('Expected JSON');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > _maxRequestBytes) {
        throw const FormatException('Request too large');
      }
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object');
    }
    return value;
  }

  Future<void> _send(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    response.write(jsonEncode(body));
    await response.close();
  }
}

class _BridgeTest {
  _BridgeTest(this.requestId);
  final String requestId;
  final CancellationToken cancellation = CancellationToken();
  final DateTime createdAt = DateTime.now().toUtc();
  String status = 'queued';
  bool? success;
  int? elapsedMs;
  String? errorCode;

  Map<String, Object?> snapshot() => <String, Object?>{
        'request_id': requestId,
        'kind': 'runtime',
        'status': status,
        'success': success,
        'elapsed_ms': elapsedMs,
        'error_code': errorCode,
        'created_at': createdAt.toIso8601String(),
      };
}
