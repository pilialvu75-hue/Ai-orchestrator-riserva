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
