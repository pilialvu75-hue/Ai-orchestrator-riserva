import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Web Self-Test sends only the synthetic orchestration marker request',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls += 1;
      expect(request.method, 'POST');
      expect(request.headers['x-requested-with'], 'XMLHttpRequest');
      expect(request.url.path, '/api/cantiere/inference');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload, <String, dynamic>{
        'version': 1,
        'capability': 'orchestration',
        'selfTest': true,
      });
      expect(payload.containsKey('model'), isFalse);
      expect(payload.containsKey('apiKey'), isFalse);
      expect(payload.containsKey('messages'), isFalse);
      return http.Response(
        jsonEncode(<String, Object?>{
          'version': 1,
          'text': WorkshopWebCloudSelfTestClient.expectedMarker,
          'model': 'configured-model',
          'reportedModel': 'provider-reported-model',
          'provider': 'NVIDIA NIM',
          'routeId': 'free-route',
          'tokensGenerated': 12,
        }),
        200,
      );
    });
    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();

    expect(calls, 1);
    expect(result.passed, isTrue);
    expect(result.statusCode, 200);
    expect(result.provider, 'NVIDIA NIM');
    expect(result.configuredModel, 'configured-model');
    expect(result.reportedModel, 'provider-reported-model');
    expect(result.routeId, 'free-route');
    expect(result.tokensGenerated, 12);
    expect(result.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
  });

  test('Web Self-Test refuses routes not explicitly approved as free', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, Object>{
            'version': 1,
            'error': <String, String>{'code': 'self_test_not_configured'},
          }),
          503,
        ));

    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();

    expect(result.passed, isFalse);
    expect(result.statusCode, 503);
    expect(result.detail, contains('costo zero'));
  });

  test('Web Self-Test rejects HTTP 200 with incorrect generated text', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, Object>{
            'version': 1,
            'text': 'An unrelated answer.',
            'model': 'configured-model',
            'reportedModel': 'provider-reported-model',
            'provider': 'Groq',
            'routeId': 'free-route',
          }),
          200,
        ));

    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();

    expect(result.passed, isFalse);
    expect(result.detail, contains('esattamente'));
  });

  test('Web Self-Test does not accept an unverified model attribution', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, Object>{
            'version': 1,
            'text': WorkshopWebCloudSelfTestClient.expectedMarker,
            'model': 'configured-model',
            'routeId': 'free-route',
          }),
          200,
        ));

    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();

    expect(result.passed, isFalse);
    expect(result.detail, contains('attribuibili'));
  });

  test('Web Self-Test reports an Access denial without exposing its body',
      () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, Object>{
            'version': 1,
            'error': <String, String>{'code': 'denied'},
          }),
          403,
        ));

    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();

    expect(result.passed, isFalse);
    expect(result.statusCode, 403);
    expect(result.detail, contains('403'));
  });

  test('Web Self-Test reports browser transport exceptions', () async {
    final client = MockClient((_) async {
      throw http.ClientException('synthetic network failure');
    });
    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run();
    expect(result.passed, isFalse);
    expect(result.statusCode, isNull);
    expect(result.detail, contains('browser'));
  });
  test('Expired Cloudflare Access session returns a clear login warning',
      () async {
    final client = MockClient((request) async {
      expect(request.headers['x-requested-with'], 'XMLHttpRequest');
      return http.Response(
        '<html>Cloudflare Access sign in</html>',
        401,
        headers: const <String, String>{'content-type': 'text/html'},
      );
    });
    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run(selectedRouteId: 'kimi-k26-orchestrator');
    expect(result.passed, isFalse);
    expect(result.statusCode, 401);
    expect(result.errorCode, 'access_login_required');
    expect(result.detail, contains('login'));
  });

  test('Redirected Access HTML is not mistaken for NVIDIA inference', () async {
    final client = MockClient((_) async => http.Response(
          '<html>Cloudflare Access</html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        ));
    final result = await WorkshopWebCloudSelfTestClient(
      client: client,
      baseUri: Uri.parse('https://example.invalid/'),
    ).run(selectedRouteId: 'deepseek-v41-flash-orchestrator');
    expect(result.passed, isFalse);
    expect(result.statusCode, 200);
    expect(result.errorCode, 'possible_access_login');
    expect(result.reportedModel, isNull);
    expect(result.detail, contains('Cloudflare Access'));
  });

}
