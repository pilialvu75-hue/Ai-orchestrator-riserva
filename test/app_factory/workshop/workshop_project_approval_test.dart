import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';

void main() {
  test('project approval is explicit, idempotent and scoped to current project',
      () {
    final controller = WorkshopDashboardController(
      engine: WorkshopEngine(),
    );
    addTearDown(controller.dispose);

    controller.startProduction(
      title: 'Contatore',
      instruction: 'Crea una semplice app contatore.',
    );

    expect(controller.state.isProjectApproved, isFalse);

    final first = controller.approveCurrentProject();
    final second = controller.approveCurrentProject();

    expect(controller.state.isProjectApproved, isTrue);
    expect(first.approvalId, second.approvalId);
    expect(first.projectId, controller.state.projectId);

    controller.cancelProduction();

    expect(controller.state.isProjectApproved, isFalse);
  });
  test('recovery rejects project approval bound to another project', () async {
    final source = WorkshopDashboardController(
      engine: WorkshopEngine(),
    );
    final restored = WorkshopDashboardController(
      engine: WorkshopEngine(),
    );
    addTearDown(source.dispose);
    addTearDown(restored.dispose);

    source.startProduction(
      title: 'Contatore',
      instruction: 'Crea una semplice app contatore.',
    );

    final requestId = source.state.requestId!;
    final request = source.engine.requestOf(requestId)!;
    final plan = source.engine.planOf(requestId)!;

    final foreignApproval = WorkshopProjectApprovalEvidence(
      projectId: 'project:foreign-request',
      approvalId: 'approval:foreign',
      approvedAt: DateTime.utc(2026, 9, 19),
      approvedBy: 'owner',
    );

    await expectLater(
      restored.restoreProduction(
        request: request,
        plan: plan,
        projectApproval: foreignApproval,
      ),
      throwsStateError,
    );
  });

}
