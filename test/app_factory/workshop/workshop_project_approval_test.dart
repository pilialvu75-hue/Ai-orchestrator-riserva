import 'package:flutter_test/flutter_test.dart';

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
}
