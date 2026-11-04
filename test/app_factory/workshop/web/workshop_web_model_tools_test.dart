import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_models.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Model catalogue contains only sanitized server-owned route aliases',
      () async {
    var requests = 0;
    final catalog = await WorkshopWebModelCatalogueClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((req) async {
        requests++;
        expect(req.method, 'GET');
        expect(req.url.path, '/api/cantiere/models');
        expect(req.headers.containsKey('Authorization'), isFalse);
        return http.Response(jsonEncode(<String, Object>{
          'version': 1,
          'capability': 'orchestration',
          'configStatus': 'configured',
          'models': <Map<String, Object>>[
            <String, Object>{
              'routeId': 'safe-nim',
              'model': 'nemotron-example',
              'provider': 'NVIDIA NIM',
              'bindingPresent': true,
              'testApproved': true,
              'selectable': true,
            },
            <String, Object>{
              'routeId': 'not-free',
              'model': 'another-example',
              'provider': 'Altro provider',
              'bindingPresent': true,
              'testApproved': false,
              'selectable': true, // malicious response must be rejected
            },
          ],
        }), 200);
      }),
    ).load();
    expect(requests, 1);
    expect(catalog.models, hasLength(2));
    expect(catalog.models.first.selectable, isTrue);
    expect(catalog.models.last.selectable, isFalse);
    expect(catalog.hasTestRoutes, isTrue);
  });

  test('Manual Web model choice persists but disabled choices fail closed',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final preference = WorkshopWebModelPreference(preferences: prefs);
    const allowed = WorkshopWebModelRoute(
      routeId: 'safe-nim', model: 'example', provider: 'NVIDIA NIM',
      bindingPresent: true, testApproved: true, selectable: true,
    );
    const denied = WorkshopWebModelRoute(
      routeId: 'paid', model: 'example', provider: 'Altro provider',
      bindingPresent: true, testApproved: false, selectable: false,
    );
    await preference.select(denied);
    expect(preference.automatic, isTrue);
    await preference.select(allowed);
    expect(preference.routeId, 'safe-nim');
    expect(prefs.getString(WorkshopWebModelPreference.storageKey), 'safe-nim');
    await preference.reconcile(const WorkshopWebModelCatalogue(
      configStatus: 'configured', models: <WorkshopWebModelRoute>[],
    ));
    expect(preference.automatic, isTrue);
    expect(prefs.getString(WorkshopWebModelPreference.storageKey), isNull);
  });

  test('Manual orchestration request sends route alias only', () async {
    Map<String, dynamic>? sent;
    final provider = WorkshopWebCloudRuntimeProvider(
      capability: WorkshopWebCloudCapability.orchestration,
      selectedRouteId: () => 'safe-nim',
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(<String, Object>{
          'version': 1, 'text': 'PROPOSAL: Tested',
          'model': 'server-model', 'routeId': 'safe-nim',
          'tokensGenerated': 3,
        }), 200);
      }),
    );
    final result = await provider.streamInference(
      request: const InferenceRequest(
        sessionId: 'web-model-test', prompt: 'Synthetic test',
      ),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(result.single.isFinal, isTrue);
    expect(sent!['routeId'], 'safe-nim');
    expect(sent!.containsKey('model'), isFalse);
    expect(sent!.containsKey('apiKey'), isFalse);
    expect(sent!.containsKey('endpoint'), isFalse);
  });

  test('Self-Test can target only a route alias, not an arbitrary endpoint',
      () async {
    Map<String, dynamic>? sent;
    final client = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(<String, Object>{
          'version': 1,
          'text': WorkshopWebCloudSelfTestClient.expectedMarker,
          'model': 'configured-model',
          'reportedModel': 'upstream-model',
          'provider': 'NVIDIA NIM',
          'routeId': 'safe-nim',
        }), 200);
      }),
    );
    final result = await client.run(routeId: 'safe-nim');
    expect(result.passed, isTrue);
    expect(sent!['routeId'], 'safe-nim');
    expect(sent!.containsKey('endpoint'), isFalse);
  });

  test('Server protects the manual route from unapproved and paid fallbacks',
      () {
    final source = File('functions/api/cantiere/inference.js').readAsStringSync();
    final catalogue = File('functions/api/cantiere/models.js').readAsStringSync();
    expect(source, contains("return error('route_not_authorized', 403)"));
    expect(source, contains('route.selfTestFree'));
    expect(source, contains('route.id === selectedRouteId'));
    expect(catalogue, contains("      model,"));
    expect(catalogue, contains("bindingPresent"));
    expect(catalogue, contains("testApproved"));
    expect(catalogue, isNot(contains('sk-')));
    expect(catalogue, isNot(contains('Authorization: Bearer')));
  });
}
