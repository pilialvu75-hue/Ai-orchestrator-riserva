import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_projects_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final testCase in <({
    String selector,
    String goalLabel,
    String button,
    String title,
    String detailLabel,
    AivexusProjectKind kind,
    List<String> platforms,
  })>[
    (
      selector: '3D',
      goalLabel: 'Descrivi il modello 3D',
      button: 'Crea bozza Stampa 3D',
      title: 'Supporto telefono',
      detailLabel: 'Stampa 3D · bozza salvata',
      kind: AivexusProjectKind.cad,
      platforms: const <String>[],
    ),
    (
      selector: 'Game',
      goalLabel: 'Descrivi il gioco',
      button: 'Crea bozza Videogioco',
      title: 'Raccogli stelle',
      detailLabel: 'Videogiochi · bozza salvata',
      kind: AivexusProjectKind.game,
      platforms: const <String>['Web'],
    ),
  ]) {
    testWidgets(
      '${testCase.selector} creates and reopens a persistent domain draft without inference',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await WorkshopWebProjectStorage.open();
        final provider = _CountingProvider();
        final controller = WorkshopChatController(
          inferenceGateway: WorkshopInferenceGateway(provider: provider),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkshopWebProjectsPage(
                controller: controller,
                storage: storage,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Nuovo progetto'));
        await tester.pumpAndSettle();
        expect(find.text('Tipo progetto'), findsOneWidget);

        await tester.tap(find.text(testCase.selector));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, testCase.title);
        final goal = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == testCase.goalLabel,
        );
        await tester.enterText(goal, 'Descrizione dominio persistente');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.text(testCase.button),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(testCase.button));
        await tester.pumpAndSettle();

        expect(provider.calls, 0);
        expect(find.text(testCase.detailLabel), findsOneWidget);
        expect(
          find.textContaining('runner specializzato non è ancora collegato'),
          findsOneWidget,
        );

        final reopened = await WorkshopWebProjectStorage.open();
        final projects = await reopened.loadAll();
        expect(projects, hasLength(1));
        expect(projects.single.title, testCase.title);
        expect(projects.single.projectKind, testCase.kind);
        expect(projects.single.extension?.kind, testCase.kind);
        expect(projects.single.platforms, testCase.platforms);

        await tester.tap(find.byIcon(Icons.arrow_back).first);
        await tester.pumpAndSettle();
        expect(find.text(testCase.title), findsOneWidget);
        expect(find.textContaining(testCase.detailLabel.split(' · ').first),
            findsWidgets);

        await tester.tap(find.text(testCase.title));
        await tester.pumpAndSettle();
        expect(find.text(testCase.detailLabel), findsOneWidget);
        expect(provider.calls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'editing software locks project kind and preserves the existing identity',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await WorkshopWebProjectStorage.open();
      final createdAt = DateTime.utc(2026, 10, 12, 10);
      final original = await storage.saveProject(
        WorkshopWebProject(
          id: 'software-existing',
          title: 'App esistente',
          goal: 'Obiettivo iniziale',
          platforms: const <String>['Web'],
          status: WorkshopWebProjectStatus.proposalReady,
          progress: 0.10,
          currentPhase: 'Proposta pronta',
          currentItem: 'Attende approvazione del proprietario',
          createdAt: createdAt,
          updatedAt: createdAt,
          extension: AivexusProjectExtension.draft(
            AivexusProjectKind.software,
          ),
        ),
      );
      final provider = _CountingProvider();
      final controller = WorkshopChatController(
        inferenceGateway: WorkshopInferenceGateway(provider: provider),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkshopWebProjectsPage(
              controller: controller,
              storage: storage,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('App esistente'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Modifica progetto'));
      await tester.tap(find.text('Modifica progetto'));
      await tester.pumpAndSettle();

      final selector = tester.widget<SegmentedButton<AivexusProjectKind>>(
        find.byType(SegmentedButton<AivexusProjectKind>),
      );
      expect(selector.selected, <AivexusProjectKind>{AivexusProjectKind.software});
      expect(selector.onSelectionChanged, isNull);

      final goal = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Cosa deve fare?',
      );
      await tester.scrollUntilVisible(
        goal,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(goal, 'Obiettivo aggiornato');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Prepara proposta'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Prepara proposta'));
      await tester.pumpAndSettle();

      final projects = await storage.loadAll();
      expect(projects, hasLength(1));
      expect(projects.single.id, original.id);
      expect(projects.single.createdAt, original.createdAt);
      expect(projects.single.projectKind, AivexusProjectKind.software);
      expect(projects.single.goal, 'Obiettivo aggiornato');
      expect(provider.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _CountingProvider implements RuntimeInferenceProvider {
  int calls = 0;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls++;
    yield InferenceResponse.finalChunk(
      text: 'PROPOSAL: should not be used by domain drafts',
      tokensGenerated: 7,
      model: 'test-fixture',
    );
  }
}
