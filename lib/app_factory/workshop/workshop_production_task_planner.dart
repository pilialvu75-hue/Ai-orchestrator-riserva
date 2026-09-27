import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

/// Deterministic production-plan builder for the first real Cantiere workflow.
///
/// The planner deliberately keeps each AI-facing task small before inference:
/// bounded instructions, explicit target files, explicit acceptance criteria
/// and a strict dependency chain. The full project goal remains available on
/// [WorkshopProjectPlan], so bounding one task never discards the owner goal.
final class WorkshopProductionTaskPlanDraft {
  const WorkshopProductionTaskPlanDraft({
    required this.phases,
    required this.tasks,
  });

  final List<WorkshopProjectPhase> phases;
  final List<WorkshopProjectTask> tasks;
}

final class WorkshopProductionTaskPlanner {
  const WorkshopProductionTaskPlanner();

  static const int maxTaskDescriptionChars = 900;
  static const int maxCriteriaPerTask = 8;
  static const int maxTargetFilesPerTask = 3;

  WorkshopProductionTaskPlanDraft build({
    required String instruction,
    List<String> requirements = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
  }) {
    final normalizedInstruction = instruction.trim();
    if (normalizedInstruction.isEmpty) {
      throw ArgumentError.value(
        instruction,
        'instruction',
        'Production instruction cannot be empty.',
      );
    }

    final criteria = _normalized(validationCriteria);
    final normalizedRequirements = _normalized(requirements);
    if (_isBuildRepair(normalizedInstruction)) {
      return _singleRepairTask(
        instruction: normalizedInstruction,
        validationCriteria: criteria,
      );
    }

    final coreCriteria = <String>[
      ...normalizedRequirements.map((value) => 'Requirement: $value'),
    ];
    final taskLevelAcceptance = criteria
        .where((value) => !_isPostTaskBuildCriterion(value))
        .toList(growable: false);

    const foundationId = 'task:initial-implementation';
    const coreId = 'task:core-behavior';
    const acceptanceId = 'task:acceptance-verification';

    final tasks = <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: foundationId,
        title: 'Fondazione applicazione',
        description: _boundedTaskDescription(
          'Prepare the smallest runnable SDK-only project foundation required '
          'for the approved goal. Establish or correct the application entry '
          'point only; do not add third-party dependencies here. Defer the '
          'requested business behavior and acceptance polishing to later tasks. '
          'Project goal: '
          '$normalizedInstruction',
        ),
        phaseId: 'phase:implementation',
        affectedPaths: const <String>[
          'lib/main.dart',
        ],
        validationCriteria: _boundedCriteria(<String>[
          'The application has a coherent runnable foundation for the approved goal.',
          'The entry point is internally consistent and uses only declared SDK capabilities.',
        ]),
      ),
      WorkshopProjectTask(
        id: coreId,
        title: 'Funzionalità principale',
        description: _boundedTaskDescription(
          'Update the existing foundation with the requested core behavior as '
          'one bounded increment. Keep lib/main.dart as a small bootstrap and '
          'put the product UI/behavior in lib/app.dart when that keeps the task '
          'safer and easier to review. Preserve the approved project goal and '
          'avoid unrelated features. Project goal: $normalizedInstruction',
        ),
        phaseId: 'phase:implementation',
        dependencies: const <String>[foundationId],
        affectedPaths: const <String>[
          'lib/main.dart',
          'lib/app.dart',
        ],
        validationCriteria: _boundedCriteria(<String>[
          'The requested core behavior is implemented without placeholder output.',
          ...coreCriteria,
        ]),
      ),
      WorkshopProjectTask(
        id: acceptanceId,
        title: 'Verifica e rifinitura',
        description: _boundedTaskDescription(
          'Add or update focused verification for the implemented behavior and '
          'make only the minimal corrections required by the approved acceptance '
          'criteria. Final artifact/build checks remain owned by Build Lab '
          'after all bounded tasks complete. Do not expand product scope.',
        ),
        phaseId: 'phase:implementation',
        dependencies: const <String>[coreId],
        affectedPaths: const <String>[
          'test/widget_test.dart',
        ],
        validationCriteria: _boundedCriteria(<String>[
          ...taskLevelAcceptance,
          'Focused tests or equivalent checks cover the requested behavior.',
          'No known analyzer or test regression is intentionally introduced.',
        ]),
      ),
    ];

    _validateFeasibility(tasks);

    return WorkshopProductionTaskPlanDraft(
      phases: <WorkshopProjectPhase>[
        WorkshopProjectPhase(
          id: 'phase:implementation',
          title: 'Implementazione',
          description:
              'Esecuzione incrementale di unità verificabili del progetto.',
          taskIds: tasks.map((task) => task.id).toList(growable: false),
          validationCriteria: criteria,
        ),
      ],
      tasks: List<WorkshopProjectTask>.unmodifiable(tasks),
    );
  }

  WorkshopProductionTaskPlanDraft _singleRepairTask({
    required String instruction,
    required List<String> validationCriteria,
  }) {
    final task = WorkshopProjectTask(
      id: 'task:initial-implementation',
      title: 'Correzione build mirata',
      description: _boundedTaskDescription(instruction),
      phaseId: 'phase:implementation',
      // Build diagnostics may point to any project file. Preserve the previous
      // dynamic target behavior instead of forcing a possibly unrelated or
      // oversized file into the Engineer prompt.
      affectedPaths: const <String>[],
      validationCriteria: _boundedCriteria(<String>[
        ...validationCriteria,
        'The previously failing build stage is corrected without disabling safety gates.',
      ]),
    );

    _validateFeasibility(
      <WorkshopProjectTask>[task],
      allowUnscopedTarget: true,
    );

    return WorkshopProductionTaskPlanDraft(
      phases: <WorkshopProjectPhase>[
        WorkshopProjectPhase(
          id: 'phase:implementation',
          title: 'Correzione build',
          description: 'Correzione minima del fallimento di build osservato.',
          taskIds: const <String>['task:initial-implementation'],
          validationCriteria: task.validationCriteria,
        ),
      ],
      tasks: <WorkshopProjectTask>[task],
    );
  }

  static bool _isBuildRepair(String instruction) =>
      instruction.toUpperCase().startsWith('BUILD REPAIR ATTEMPT:');

  static bool _isPostTaskBuildCriterion(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('apk') ||
        normalized.contains('aab') ||
        normalized.contains('build') ||
        normalized.contains('artifact') ||
        normalized.contains('installer') ||
        normalized.contains('flutter analyze') ||
        normalized.contains('flutter test');
  }

  static List<String> _normalized(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }

  static String _boundedTaskDescription(String value) {
    final normalized = value.trim();
    if (normalized.length <= maxTaskDescriptionChars) {
      return normalized;
    }

    const marker = ' ...[bounded task context]... ';
    final remaining = maxTaskDescriptionChars - marker.length;
    final headChars = (remaining * 3) ~/ 5;
    final tailChars = remaining - headChars;
    return normalized.substring(0, headChars) +
        marker +
        normalized.substring(normalized.length - tailChars);
  }

  static List<String> _boundedCriteria(Iterable<String> values) {
    final normalized = _normalized(values);
    if (normalized.isNotEmpty) {
      return List<String>.unmodifiable(
        normalized.take(maxCriteriaPerTask),
      );
    }
    return const <String>[
      'The bounded task is complete and does not introduce a known regression.',
    ];
  }

  static void _validateFeasibility(
    List<WorkshopProjectTask> tasks, {
    bool allowUnscopedTarget = false,
  }) {
    final knownIds = <String>{};

    for (final task in tasks) {
      if (!knownIds.add(task.id)) {
        throw StateError('Duplicate Workshop production task id: ${task.id}.');
      }
      if (task.description.length > maxTaskDescriptionChars) {
        throw StateError(
          'Workshop production task "${task.id}" exceeds the task prompt budget.',
        );
      }
      if ((!allowUnscopedTarget && task.affectedPaths.isEmpty) ||
          task.affectedPaths.length > maxTargetFilesPerTask) {
        throw StateError(
          'Workshop production task "${task.id}" has an infeasible target-file scope.',
        );
      }
      if (task.validationCriteria.isEmpty ||
          task.validationCriteria.length > maxCriteriaPerTask) {
        throw StateError(
          'Workshop production task "${task.id}" has an infeasible acceptance scope.',
        );
      }
      for (final dependency in task.dependencies) {
        if (!knownIds.contains(dependency)) {
          throw StateError(
            'Workshop production task "${task.id}" depends on a task that is '
            'not an earlier bounded unit: $dependency.',
          );
        }
      }
    }
  }
}
