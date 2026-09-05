import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_phase_policy.dart';

void main() {
  group('WorkshopRolePhasePolicy', () {
    test('maps every inference phase to its dedicated Workshop role', () {
      expect(
        WorkshopRolePhasePolicy.roleFor(
          WorkshopInferencePhase.orchestration,
        ),
        AppAiRole.workshopOrchestrator,
      );
      expect(
        WorkshopRolePhasePolicy.roleFor(
          WorkshopInferencePhase.architecture,
        ),
        AppAiRole.architect,
      );
      expect(
        WorkshopRolePhasePolicy.roleFor(
          WorkshopInferencePhase.implementation,
        ),
        AppAiRole.engineer,
      );
      expect(
        WorkshopRolePhasePolicy.roleFor(
          WorkshopInferencePhase.review,
        ),
        AppAiRole.reviewer,
      );
    });

    test('covers exactly the four Workshop roles', () {
      final routedRoles = WorkshopInferencePhase.values
          .map(WorkshopRolePhasePolicy.roleFor)
          .toSet();

      expect(routedRoles, WorkshopRolePhasePolicy.workshopRoles);
      expect(
        routedRoles,
        isNot(contains(AppAiRole.assistantOrchestrator)),
      );
    });
  });
}
