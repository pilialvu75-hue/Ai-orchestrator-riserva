import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/diagnostics/chatgpt_bridge/aivexus_test_bridge_server.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_self_test_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSelfTest extends Mock implements RuntimeSelfTestService {}
class _MockDiagnostics extends Mock implements LocalRuntimeDiagnosticsService {}
class _MockModels extends Mock implements LocalAiRepository {}

// Flutter's ordinary test binding intercepts HttpClient, including 127.0.0.1.
// This suite intentionally tests a real synthetic loopback HTTP boundary.
class _RealBridgeBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _RealBridgeBinding();
  setUpAll(() => registerFallbackValue(CancellationToken()));

  late AivexusTestBridgeServer server;
  late _MockSelfTest selfTest;
  late HttpClient client;

  Future<(int, Map<String, dynamic>)> request(
    String method,
    String path, {
    Object? body,
    String? secret,
  }) async {
    final uri = Uri.parse('http://127.0.0.1:' +
        server.boundPort.toString() + path);
    final req = await client.openUrl(method, uri);
    req.headers.set(HttpHeaders.authorizationHeader,
        'Bearer ' + (secret ?? ('x' * 40)));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close();
    final parsed = jsonDecode(await resp.transform(utf8.decoder).join());
    return (resp.statusCode, Map<String, dynamic>.from(parsed as Map));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    selfTest = _MockSelfTest();
    server = AivexusTestBridgeServer(
      token: 'x' * 40,
      appVersion: 'synthetic-test',
      runtimeSelfTest: selfTest,
      runtimeDiagnostics: _MockDiagnostics(),
      localModels: _MockModels(),
      port: 0,
    );
    client = HttpClient();
    await server.start();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  test('rejects unauthenticated requests, including local loopback', () async {
    final response = await request('GET', '/v1/instance', secret: 'y' * 40);
    expect(response.$1, HttpStatus.unauthorized);
    expect(response.$2['error'], 'unauthorized');
  });

  test('only fixed synthetic runtime kind is accepted', () async {
    final response = await request('POST', '/v1/tests', body: <String, Object>{
      'request_id': 'synthetic-test-1',
      'kind': 'application',
    });
    expect(response.$1, HttpStatus.badRequest);
    verifyNever(() => selfTest.run(cancellationToken: any(named: 'cancellationToken')));
  });

  test('same request ID is not executed twice', () async {
    final pending = Completer<RuntimeSelfTestResult>();
    when(() => selfTest.run(cancellationToken: any(named: 'cancellationToken')))
        .thenAnswer((_) => pending.future);
    const body = <String, String>{
      'request_id': 'synthetic-test-2',
      'kind': 'runtime',
    };
    final first = await request('POST', '/v1/tests', body: body);
    final second = await request('POST', '/v1/tests', body: body);
    expect(first.$1, HttpStatus.accepted);
    expect(second.$1, HttpStatus.ok);
    expect(first.$2['request_id'], second.$2['request_id']);
    verify(() => selfTest.run(cancellationToken: any(named: 'cancellationToken')))
        .called(1);
    pending.complete(const RuntimeSelfTestResult(success: true, summary: 'PASS'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final status = await request('GET', '/v1/tests/synthetic-test-2');
    expect(status.$2['status'], 'completed');
    expect(status.$2['elapsed_ms'], isA<int>());
  });

  test('cooperative cancellation never invents success', () async {
    final pending = Completer<RuntimeSelfTestResult>();
    CancellationToken? observed;
    when(() => selfTest.run(cancellationToken: any(named: 'cancellationToken')))
        .thenAnswer((invocation) {
      observed = invocation.namedArguments[#cancellationToken] as CancellationToken;
      return pending.future;
    });
    await request('POST', '/v1/tests', body: <String, String>{
      'request_id': 'synthetic-test-3',
      'kind': 'runtime',
    });
    final cancelled = await request(
        'POST', '/v1/tests/synthetic-test-3/cancel');
    expect(cancelled.$2['status'], 'cancel_requested');
    expect(observed!.isCancelled, isTrue);
    pending.complete(const RuntimeSelfTestResult(success: false, summary: 'cancelled'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final result = await request('GET', '/v1/tests/synthetic-test-3');
    expect(result.$2['status'], 'cancelled');
  });

  test('completed status can be recovered after restarting the server', () async {
    when(() => selfTest.run(cancellationToken: any(named: 'cancellationToken')))
        .thenAnswer((_) async => const RuntimeSelfTestResult(
            success: false,
            summary: 'Missing model at C:/private-location/models/file.gguf'));
    await request('POST', '/v1/tests', body: <String, String>{
      'request_id': 'synthetic-test-4',
      'kind': 'runtime',
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await server.stop();
    server = AivexusTestBridgeServer(
      token: 'x' * 40,
      appVersion: 'synthetic-test',
      runtimeSelfTest: selfTest,
      runtimeDiagnostics: _MockDiagnostics(),
      localModels: _MockModels(),
      port: 0,
    );
    await server.start();
    final recovered = await request('GET', '/v1/tests/synthetic-test-4');
    expect(recovered.$2['status'], 'failed');
    expect(jsonEncode(recovered.$2), isNot(contains('private-location')));
  });
}
