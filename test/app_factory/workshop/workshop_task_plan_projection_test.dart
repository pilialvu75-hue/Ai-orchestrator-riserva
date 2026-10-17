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

      expect(
        projected.length,
        lessThanOrEqualTo(WorkshopTaskPlanProjection.maxChars),
      );
      expect(projected, startsWith('SCOPE: implement walking tracking'));
      expect(
        projected,
        contains(
          'ACCEPTANCE: user receives visible feedback when progress changes.',
        ),
      );
      expect(projected, contains('[bounded middle omitted]'));
    });

    test('preserves bounded acceptance lines from the omitted middle', () {
      final plan = <String>[
        'SCOPE: Implement the project.',
        'introductory design considerations ' * 35,
        'REQUIREMENT: Tap changes only the visible star color.',
        'ACCEPTANCE: Black background remains unchanged after each tap.',
        'implementation background and notes ' * 40,
        'END: Do not add unrelated features.',
      ].join('\n');

      final projected = WorkshopTaskPlanProjection.project(plan);

      expect(projected.length, lessThanOrEqualTo(WorkshopTaskPlanProjection.maxChars));
      expect(projected, startsWith('SCOPE: Implement the project.'));
      expect(projected, contains('REQUIREMENT: Tap changes only the visible star color.'));
      expect(projected,
          contains('ACCEPTANCE: Black background remains unchanged after each tap.'));
      expect(projected, contains('END: Do not add unrelated features.'));
      expect(projected, contains('[middle requirements]'));
    });

    test('cannot exceed budget when several long priorities compete', () {
      final plan = [
        'HEADER',
        'context ' * 130,
        for (var i = 0; i < 12; i++) 'REQUIREMENT: ${'details ' * 30} $i',
        'footer ' * 120,
        'TAIL END',
      ].join('\n');
      expect(WorkshopTaskPlanProjection.project(plan).length,
          lessThanOrEqualTo(WorkshopTaskPlanProjection.maxChars));
    });

    test('keeps short plans unchanged', () {
      const plan = 'Implement a minimal walking app and show user feedback.';

      expect(WorkshopTaskPlanProjection.project(plan), plan);
    });
  });
}
