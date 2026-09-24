import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_task_plan_projection.dart';

void main() {
  group('WorkshopTaskPlanProjection', () {
    test('preserves Architect scope and trailing acceptance criteria', () {
      final plan = <String>[
        'SCOPE: implement walking tracking and a minimal walking session UI.',
        List<String>.filled(1400, 'middle-detail').join(' '),
        'ACCEPTANCE: user receives visible feedback when progress changes.',
      ].join('\n');

      final projected = WorkshopTaskPlanProjection.project(plan);

      expect(projected.length, lessThanOrEqualTo(WorkshopTaskPlanProjection.maxChars));
      expect(projected, startsWith('SCOPE: implement walking tracking'));
      expect(
        projected,
        contains('ACCEPTANCE: user receives visible feedback when progress changes.'),
      );
      expect(projected, contains('[bounded middle omitted]'));
    });

    test('keeps short plans unchanged', () {
      const plan = 'Implement a minimal walking app and show user feedback.';

      expect(WorkshopTaskPlanProjection.project(plan), plan);
    });
  });
}
