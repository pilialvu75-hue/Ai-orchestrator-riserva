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
}
