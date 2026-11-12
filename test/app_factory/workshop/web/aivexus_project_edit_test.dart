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

import 'aivexus_test_fixtures.dart';

void main() {
  for (final withExtension in [false, true]) {
    testWidgets(
      'editing software keeps identity and response revision (extension: $withExtension)',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = await WorkshopWebProjectStorage.open();
        final original = await store.saveProject(
          aivexusProject(
            'keep-this-id',
            extension: withExtension
                ? AivexusProjectExtension.draft(AivexusProjectKind.software)
                : null,
          ),
        );
        final provider = _ProposalProvider();
        final controller = WorkshopChatController(
          inferenceGateway: WorkshopInferenceGateway(provider: provider),
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkshopWebProjectsPage(
                controller: controller,
                storage: store,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('keep-this-id'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Modifica progetto'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Modifica progetto'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Revised title');
        final goalField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Cosa deve fare?',
        );
        await tester.scrollUntilVisible(
          goalField,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(goalField, 'Revised requirements');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Prepara proposta'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Prepara proposta'));
        await tester.pumpAndSettle();
        final projects = await store.loadAll();
        expect(projects, hasLength(1));
        expect(projects.single.id, original.id);
        expect(projects.single.createdAt, original.createdAt);
        expect(projects.single.goal, 'Revised requirements');
        expect(projects.single.storageRevision, 3);
        expect(
          projects.single.extension?.specRevision,
          withExtension ? 2 : null,
        );
        expect(projects.single.status, WorkshopWebProjectStatus.proposalReady);
        expect(provider.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('approved Web proposal survives reopening without inference', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final firstStore = await WorkshopWebProjectStorage.open();
    final original = await firstStore.saveProject(
      aivexusProject('approval-persisted').copyWith(
        status: WorkshopWebProjectStatus.proposalReady,
        progress: 0.10,
        currentPhase: 'Proposta pronta',
        currentItem: 'Attende approvazione del proprietario',
        proposal: 'PROPOSAL: Web counter without external services.',
      ),
    );
    final provider = _ProposalProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );
    addTearDown(controller.dispose);

    Widget page(WorkshopWebProjectStorage store) => MaterialApp(
      home: Scaffold(
        body: WorkshopWebProjectsPage(
          controller: controller,
          storage: store,
        ),
      ),
    );

    await tester.pumpWidget(page(firstStore));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approval-persisted'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approva progetto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();

    final approved = (await firstStore.loadAll()).single;
    expect(approved.id, original.id);
    expect(approved.createdAt, original.createdAt);
    expect(approved.status, WorkshopWebProjectStatus.approved);
    expect(approved.progress, 0.15);
    expect(approved.storageRevision, original.storageRevision + 1);
    expect(approved.proposal, original.proposal);
    expect(provider.calls, 0);

    // A fresh store and a remounted page simulate reopening the Web UI,
    // without claiming a real authenticated production browser refresh.
    await tester.pumpWidget(const SizedBox.shrink());
    final reopenedStore = await WorkshopWebProjectStorage.open();
    expect((await reopenedStore.loadAll()).single.status,
        WorkshopWebProjectStatus.approved);
    await tester.pumpWidget(page(reopenedStore));
    await tester.pumpAndSettle();
    await tester.tap(find.text('approval-persisted'));
    await tester.pumpAndSettle();

    expect(find.text('15%'), findsOneWidget);
    expect(find.text('Inizia creazione'), findsOneWidget);
    expect(find.textContaining('non è ancora collegato'), findsOneWidget);
    expect(find.text('Approva progetto'), findsNothing);
    expect(provider.calls, 0);
    expect(tester.takeException(), isNull);
  });
}

final class _ProposalProvider implements RuntimeInferenceProvider {
  int calls = 0;
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls++;
    yield InferenceResponse.finalChunk(
      text: 'PROPOSAL: Proposta di prova.',
      tokensGenerated: 6,
      model: 'test-fixture',
    );
  }
}
