import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Web W1 capability matrix fails native features closed', () {
    expect(
      WorkshopWebCapabilities.state(
        WorkshopWebCapability.cantiereShell,
      ),
      WorkshopWebCapabilityState.available,
    );
    expect(
      WorkshopWebCapabilities.state(
        WorkshopWebCapability.durableStorage,
      ),
      WorkshopWebCapabilityState.available,
    );
    expect(
      WorkshopWebCapabilities.state(
        WorkshopWebCapability.cloudAuto,
      ),
      WorkshopWebCapabilityState.available,
    );
    expect(
      WorkshopWebCapabilities.state(
        WorkshopWebCapability.nativeLocalInference,
      ),
      WorkshopWebCapabilityState.unavailable,
    );
    expect(
      WorkshopWebCapabilities.state(
        WorkshopWebCapability.nativeProcessExecution,
      ),
      WorkshopWebCapabilityState.unavailable,
    );
  });

  testWidgets('W1 shell exposes Aivexus Cantiere only', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkshopWebShell(
          checkpointStore: Future<WorkshopCheckpointStore>.value(
            InMemoryWorkshopCheckpointStore(),
          ),
          cloudHealth: Future<WorkshopWebCloudBrokerHealth>.value(
            const WorkshopWebCloudBrokerHealth(
              capabilities:
                  WorkshopWebCloudBrokerHealth.requiredWorkshopCapabilities,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aivexus'), findsOneWidget);
    expect(find.text('Cantiere Web'), findsOneWidget);
    expect(find.textContaining('Browser startup ready'), findsOneWidget);
    expect(find.text('Durable browser storage'), findsOneWidget);
    expect(find.textContaining('0 saved checkpoint(s)'), findsOneWidget);
    expect(find.text('Cloud / AUTO execution'), findsOneWidget);
    expect(
      find.textContaining('Server-side AUTO routing ready'),
      findsOneWidget,
    );

    // The capability cards live in a real scrollable product shell. On the
    // default widget-test viewport the native capability rows are legitimately
    // below the first frame and are not built yet.
    await tester.drag(
      find.byType(ListView),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();

    expect(find.text('Native local inference'), findsOneWidget);
    expect(find.textContaining('general Assistant'), findsNothing);
  });
  testWidgets('Web Status self-test shows verified model and elapsed time',
      (tester) async {
    var calls = 0;
    final probeClient = WorkshopWebCloudSelfTestClient(
      baseUri: Uri.parse('https://example.invalid/'),
      client: MockClient((request) async {
        calls += 1;
        expect(jsonDecode(request.body)['selfTest'], true);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'version': 1,
            'text': WorkshopWebCloudSelfTestClient.expectedMarker,
            'model': 'configured-model',
            'reportedModel': 'returned-model',
            'provider': 'NVIDIA NIM',
            'routeId': 'authorized-free-route',
            'tokensGenerated': 8,
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WorkshopWebShell(
          checkpointStore: Future<WorkshopCheckpointStore>.value(
            InMemoryWorkshopCheckpointStore(),
          ),
          cloudHealth: Future<WorkshopWebCloudBrokerHealth>.value(
            const WorkshopWebCloudBrokerHealth(
              capabilities:
                  WorkshopWebCloudBrokerHealth.requiredWorkshopCapabilities,
            ),
          ),
          selfTestClient: probeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final runButton = find.text('Esegui Self-Test Cloud');
    await tester.ensureVisible(runButton);
    expect(calls, 0, reason: 'The test must never run automatically.');
    await tester.tap(runButton);
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Cloud Self-Test Passed'), findsOneWidget);
    expect(find.text('Provider (endpoint): NVIDIA NIM'), findsOneWidget);
    expect(find.text('Modello dichiarato dal provider: returned-model'),
        findsOneWidget);
    expect(find.textContaining('Tempo:'), findsOneWidget);
    expect(find.text('Testo generato: AIVEXUS_WEB_SELF_TEST_OK'),
        findsOneWidget);
  });

}
