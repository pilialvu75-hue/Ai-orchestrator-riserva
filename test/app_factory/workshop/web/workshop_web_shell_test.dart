import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('W1 shell exposes Cantiere only', (tester) async {
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
}
