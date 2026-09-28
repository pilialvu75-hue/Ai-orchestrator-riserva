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

      expect(draft.tasks, hasLength(2));
      expect(
        draft.tasks.map((task) => task.id),
        <String>[
          'task:initial-implementation',
          'task:acceptance-verification',
        ],
      );

      final implementation = draft.tasks[0];
      final acceptance = draft.tasks[1];

      expect(implementation.title, 'Funzionalità principale');
      expect(
        implementation.affectedPaths,
        <String>['lib/main.dart', 'lib/app.dart'],
      );
      expect(implementation.validationCriteria, isNotEmpty);
      expect(acceptance.affectedPaths, isNotEmpty);
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

      expect(implementation.dependencies, isEmpty);
      expect(
        acceptance.dependencies,
        <String>['task:initial-implementation'],
      );
      expect(
        draft.phases.single.taskIds,
        <String>[
          'task:initial-implementation',
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
