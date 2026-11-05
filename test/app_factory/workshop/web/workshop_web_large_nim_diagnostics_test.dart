import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('NVIDIA upstream 422 shows sanitized failure and selected route',
      () async {
    final client = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((request) async {
        final sent = jsonDecode(request.body) as Map<String, dynamic>;
        expect(sent['selfTest'], true);
        expect(sent['routeId'], 'kimi-k26-orchestrator');
        expect(sent.containsKey('apiKey'), isFalse);
        return http.Response(jsonEncode(<String, dynamic>{
          'version': 1,
          'error': <String, dynamic>{
            'code': 'upstream_unavailable',
            'upstreamStatus': 422,
            'failureKind': 'upstream_http_rejection',
            'routeId': 'kimi-k26-orchestrator',
          },
        }), 422);
      }),
    );
    final result = await client.run(selectedRouteId: 'kimi-k26-orchestrator');
    expect(result.passed, isFalse);
    expect(result.statusCode, 422);
    expect(result.upstreamStatus, 422);
    expect(result.failureKind, 'upstream_http_rejection');
    expect(result.routeId, 'kimi-k26-orchestrator');
  });

  test('NVIDIA 200 with text but wrong marker is not an unavailable model',
      () async {
    final client = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((_) async {
        return http.Response(jsonEncode(<String, dynamic>{
          'version': 1,
          'text': 'A response other than the exact marker',
          'provider': 'NVIDIA NIM',
          'model': 'moonshotai/kimi-k2.6',
          'reportedModel': 'moonshotai/kimi-k2.6',
          'routeId': 'kimi-k26-orchestrator',
          'tokensGenerated': 80,
        }), 200);
      }),
    );
    final result = await client.run(selectedRouteId: 'kimi-k26-orchestrator');
    expect(result.statusCode, 200);
    expect(result.passed, isFalse);
    expect(result.detail, contains('inferenza presente'));
    expect(result.reportedModel, 'moonshotai/kimi-k2.6');
  });

  test('NVIDIA 502 without final text has a separate failure category',
      () async {
    final client = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((_) async {
        return http.Response(jsonEncode(<String, dynamic>{
          'version': 1,
          'error': <String, dynamic>{
            'code': 'upstream_unavailable',
            'upstreamStatus': 502,
            'failureKind': 'no_final_text',
            'routeId': 'deepseek-v41-flash-orchestrator',
          },
        }), 502);
      }),
    );
    final result = await client.run(
      selectedRouteId: 'deepseek-v41-flash-orchestrator',
    );
    expect(result.passed, isFalse);
    expect(result.failureKind, 'no_final_text');
    expect(result.routeId, 'deepseek-v41-flash-orchestrator');
  });

  test('unexpected upstream error text is never reflected as diagnostics',
      () async {
    final client = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((_) async {
        return http.Response(jsonEncode(<String, dynamic>{
          'version': 1,
          'error': <String, dynamic>{
            'code': 'upstream_unavailable',
            'upstreamStatus': 422,
            'failureKind': 'PRIVATE-SERVER-DETAIL',
            'routeId': 'bad/route',
          },
        }), 422);
      }),
    );
    final result = await client.run(selectedRouteId: 'kimi-k26-orchestrator');
    expect(result.failureKind, isNull);
    expect(result.routeId, isNull);
    expect(result.detail, isNot(contains('PRIVATE-SERVER-DETAIL')));
  });
}
