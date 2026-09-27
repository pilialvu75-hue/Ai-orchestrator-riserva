import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_planner.dart';

void main() {
  group('WorkshopProductionTaskPlanner', () {
    test('decomposes a normal app request into bounded sequential tasks', () {
      final draft = const WorkshopProductionTaskPlanner().build(
        instruction: 'Create a counter app with increment and reset controls.',
        requirements: const <String>[
          'Increment the visible count.',
          'Reset the count to zero.',
        ],
        validationCriteria: const <String>[
          'The counter updates visibly.',
          'flutter analyze e flutter test terminano senza errori.',
          'La build produce un APK Android reale.',
        ],
      );

      expect(draft.tasks, hasLength(3));
      expect(
        draft.tasks.map((task) => task.id),
        <String>[
          'task:initial-implementation',
          'task:core-behavior',
          'task:acceptance-verification',
        ],
      );

      final foundation = draft.tasks[0];
      final core = draft.tasks[1];
      final acceptance = draft.tasks[2];

      expect(foundation.affectedPaths, isNotEmpty);
      expect(core.affectedPaths, isNotEmpty);
      expect(acceptance.affectedPaths, isNotEmpty);
      expect(foundation.validationCriteria, isNotEmpty);
      expect(core.validationCriteria, isNotEmpty);
      expect(acceptance.validationCriteria, isNotEmpty);
      expect(
        acceptance.validationCriteria,
        contains('The counter updates visibly.'),
      );
      expect(
        acceptance.validationCriteria.any(
          (criterion) => criterion.toLowerCase().contains('apk'),
        ),
        isFalse,
      );
      expect(
        acceptance.validationCriteria.any(
          (criterion) => criterion.toLowerCase().contains('flutter analyze'),
        ),
        isFalse,
      );

      expect(core.dependencies, <String>['task:initial-implementation']);
      expect(acceptance.dependencies, <String>['task:core-behavior']);
      expect(
        draft.phases.single.taskIds,
        <String>[
          'task:initial-implementation',
          'task:core-behavior',
          'task:acceptance-verification',
        ],
      );

      for (final task in draft.tasks) {
        expect(
          task.description.length,
          lessThanOrEqualTo(
            WorkshopProductionTaskPlanner.maxTaskDescriptionChars,
          ),
        );
        expect(
          task.affectedPaths.length,
          lessThanOrEqualTo(
            WorkshopProductionTaskPlanner.maxTargetFilesPerTask,
          ),
        );
        expect(
          task.validationCriteria.length,
          lessThanOrEqualTo(
            WorkshopProductionTaskPlanner.maxCriteriaPerTask,
          ),
        );
      }
    });

    test('keeps an explicit build repair as one bounded correction task', () {
      final draft = const WorkshopProductionTaskPlanner().build(
        instruction: 'BUILD REPAIR ATTEMPT: 1\nFix the analyzer failure only.',
        validationCriteria: const <String>[
          'Analyzer passes.',
        ],
      );

      expect(draft.tasks, hasLength(1));
      expect(draft.tasks.single.id, 'task:initial-implementation');
      expect(draft.tasks.single.dependencies, isEmpty);
      expect(draft.tasks.single.affectedPaths, isEmpty);
      expect(
        draft.tasks.single.validationCriteria,
        contains('Analyzer passes.'),
      );
    });
  });
}
