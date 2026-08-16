import 'workshop_task_contract.dart';

/// Piano di lavoro prodotto dal Task Planner.
///
/// Il planner non esegue nessuna task e non modifica il repository.
/// Trasforma un obiettivo in una sequenza di unità di lavoro
/// verificabili.
final class WorkshopTaskPlan {
  WorkshopTaskPlan({
    required this.id,
    required this.projectObjective,
    required this.tasks,
    this.createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String projectObjective;
  final List<WorkshopTaskContract> tasks;
  final DateTime createdAt;

  bool get isEmpty => tasks.isEmpty;

  bool get isReadyForApproval {
    if (tasks.isEmpty) {
      return false;
    }

    return tasks.every(
      (task) =>
          task.objective.trim().isNotEmpty &&
          task.acceptanceCriteria.isNotEmpty,
    );
  }

  List<WorkshopTaskContract> get rootTasks {
    return List.unmodifiable(
      tasks.where(
        (task) => task.parentTaskId == null,
      ),
    );
  }

  List<WorkshopTaskContract> get blockingTasks {
    return List.unmodifiable(
      tasks.where(
        (task) =>
            task.priority == WorkshopTaskPriority.critical ||
            task.priority == WorkshopTaskPriority.high,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'projectObjective': projectObjective,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'tasks': tasks
          .map((task) => task.toJson())
          .toList(growable: false),
    };
  }
}

/// Regole utilizzate dal planner.
///
/// Queste regole sono volutamente semplici e prevedibili.
/// L'intelligenza artificiale potrà successivamente produrre
/// una pianificazione più sofisticata senza cambiare il contratto.
final class WorkshopTaskPlanningPolicy {
  const WorkshopTaskPlanningPolicy({
    this.createAnalysisTask = true,
    this.createArchitectureTask = true,
    this.createImplementationTask = true,
    this.createVerificationTask = true,
    this.createBuildTask = true,
  });

  final bool createAnalysisTask;
  final bool createArchitectureTask;
  final bool createImplementationTask;
  final bool createVerificationTask;
  final bool createBuildTask;
}

/// Planner deterministico del Cantiere.
///
/// Responsabilità:
///
/// - trasformare un obiettivo in task;
/// - assegnare dipendenze;
/// - definire criteri di accettazione;
/// - applicare limiti di scope;
/// - indicare la risorsa preferita.
///
/// NON:
///
/// - esegue LLM;
/// - chiama GitHub Agent;
/// - esegue build;
/// - modifica file;
/// - decide autonomamente di consumare crediti.
///
/// Questa separazione permette di introdurre successivamente
/// un AI planner senza trasformare il WorkshopEngine in un
/// secondo orchestratore.
final class WorkshopTaskPlanner {
  const WorkshopTaskPlanner({
    this.policy = const WorkshopTaskPlanningPolicy(),
  });

  final WorkshopTaskPlanningPolicy policy;

  WorkshopTaskPlan plan({
    required String projectObjective,
    String? projectId,
    WorkshopTaskMode mode = WorkshopTaskMode.local,
    WorkshopTaskResource preferredResource =
        WorkshopTaskResource.local,
    List<WorkshopTaskResource> fallbackResources =
        const <WorkshopTaskResource>[],
    List<String> initialFiles = const <String>[],
    List<String> constraints = const <String>[],
  }) {
    final normalizedObjective =
        projectObjective.trim();

    if (normalizedObjective.isEmpty) {
      throw ArgumentError.value(
        projectObjective,
        'projectObjective',
        'Project objective cannot be empty.',
      );
    }

    final normalizedProjectId =
        projectId?.trim().isNotEmpty == true
            ? projectId!.trim()
            : _createProjectId(normalizedObjective);

    final tasks = <WorkshopTaskContract>[];

    String? previousTaskId;

    if (policy.createAnalysisTask) {
      final task = _analysisTask(
        projectId: normalizedProjectId,
        objective: normalizedObjective,
        mode: mode,
        preferredResource: preferredResource,
        fallbackResources: fallbackResources,
        constraints: constraints,
      );

      tasks.add(task);
      previousTaskId = task.id;
    }

    if (policy.createArchitectureTask) {
      final task = _architectureTask(
        projectId: normalizedProjectId,
        objective: normalizedObjective,
        mode: mode,
        preferredResource: preferredResource,
        fallbackResources: fallbackResources,
        dependsOn: previousTaskId,
        constraints: constraints,
      );

      tasks.add(task);
      previousTaskId = task.id;
    }

    if (policy.createImplementationTask) {
      final task = _implementationTask(
        projectId: normalizedProjectId,
        objective: normalizedObjective,
        mode: mode,
        preferredResource: preferredResource,
        fallbackResources: fallbackResources,
        dependsOn: previousTaskId,
        initialFiles: initialFiles,
        constraints: constraints,
      );

      tasks.add(task);
      previousTaskId = task.id;
    }

    if (policy.createVerificationTask) {
      final task = _verificationTask(
        projectId: normalizedProjectId,
        objective: normalizedObjective,
        mode: mode,
        preferredResource: preferredResource,
        fallbackResources: fallbackResources,
        dependsOn: previousTaskId,
        constraints: constraints,
      );

      tasks.add(task);
      previousTaskId = task.id;
    }

    if (policy.createBuildTask) {
      final task = _buildTask(
        projectId: normalizedProjectId,
        objective: normalizedObjective,
        mode: mode,
        preferredResource: preferredResource,
        fallbackResources: fallbackResources,
        dependsOn: previousTaskId,
        constraints: constraints,
      );

      tasks.add(task);
    }

    return WorkshopTaskPlan(
      id: '$normalizedProjectId-plan',
      projectObjective: normalizedObjective,
      tasks: List.unmodifiable(tasks),
    );
  }

  WorkshopTaskContract _analysisTask({
    required String projectId,
    required String objective,
    required WorkshopTaskMode mode,
    required WorkshopTaskResource preferredResource,
    required List<WorkshopTaskResource> fallbackResources,
    required List<String> constraints,
  }) {
    return WorkshopTaskContract(
      id: '$projectId-task-analysis',
      title: 'Analyze project requirements',
      objective:
          'Analyze the requested project and identify its '
          'functional, technical, platform and resource requirements.',
      kind: WorkshopTaskKind.analysis,
      mode: mode,
      preferredResource: preferredResource,
      fallbackResources: fallbackResources,
      priority: WorkshopTaskPriority.high,
      instructions: <String>[
        'Understand the requested project before implementation.',
        'Identify required platforms and external dependencies.',
        'Identify which parts can be performed locally.',
        'Identify which parts may require cloud or GitHub resources.',
        'Do not modify project files.',
      ],
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'requirements-understood',
          description:
              'The main functional requirements are explicitly identified.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'resources-identified',
          description:
              'Required local, cloud and remote resources are identified.',
        ),
      ],
      fileScope: const WorkshopTaskFileScope(),
      requiredCheckpoints: const <String>[
        'analysis-complete',
      ],
      tags: <String>[
        'planning',
        'analysis',
      ],
    );
  }

  WorkshopTaskContract _architectureTask({
    required String projectId,
    required String objective,
    required WorkshopTaskMode mode,
    required WorkshopTaskResource preferredResource,
    required List<WorkshopTaskResource> fallbackResources,
    required String? dependsOn,
    required List<String> constraints,
  }) {
    return WorkshopTaskContract(
      id: '$projectId-task-architecture',
      title: 'Define project architecture',
      objective:
          'Define a maintainable architecture for the requested '
          'project before implementation begins.',
      kind: WorkshopTaskKind.planning,
      mode: mode,
      preferredResource: preferredResource,
      fallbackResources: fallbackResources,
      priority: WorkshopTaskPriority.high,
      instructions: <String>[
        'Respect the existing repository architecture.',
        'Define modules and their responsibilities.',
        'Define important interfaces before implementation.',
        'Keep UI, domain and infrastructure responsibilities separated.',
        'Do not implement unrelated features.',
      ],
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'architecture-defined',
          description:
              'The major modules and responsibilities are defined.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'interfaces-defined',
          description:
              'Important boundaries between modules are identified.',
        ),
      ],
      fileScope: const WorkshopTaskFileScope(),
      requiredCheckpoints: const <String>[
        'architecture-approved-for-implementation',
      ],
      dependsOn: dependsOn == null
          ? const <String>[]
          : <String>[dependsOn],
      tags: <String>[
        'architecture',
        'planning',
      ],
    );
  }

  WorkshopTaskContract _implementationTask({
    required String projectId,
    required String objective,
    required WorkshopTaskMode mode,
    required WorkshopTaskResource preferredResource,
    required List<WorkshopTaskResource> fallbackResources,
    required String? dependsOn,
    required List<String> initialFiles,
    required List<String> constraints,
  }) {
    final allowedFiles = <String>[
      ...initialFiles,
    ];

    return WorkshopTaskContract(
      id: '$projectId-task-implementation',
      title: 'Implement project foundation',
      objective:
          'Implement the first bounded project increment according '
          'to the approved architecture and requirements.',
      kind: WorkshopTaskKind.codeGeneration,
      mode: mode,
      preferredResource: preferredResource,
      fallbackResources: fallbackResources,
      priority: WorkshopTaskPriority.high,
      instructions: <String>[
        'Implement only the approved project foundation.',
        'Keep changes limited to the task scope.',
        'Add tests for newly introduced behavior.',
        'Do not begin unrelated features.',
        'Create a checkpoint before moving to another task.',
      ],
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'implementation-complete',
          description:
              'The requested foundation is implemented.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'tests-added',
          description:
              'Relevant tests exist for the implemented behavior.',
        ),
      ],
      fileScope: WorkshopTaskFileScope(
        allowed: allowedFiles,
      ),
      budget: const WorkshopTaskBudget(
        estimatedCredits: 1,
        minimumReserveCredits: 0.25,
      ),
      requiredCheckpoints: const <String>[
        'implementation-complete',
        'tests-complete',
      ],
      dependsOn: dependsOn == null
          ? const <String>[]
          : <String>[dependsOn],
      tags: <String>[
        'implementation',
        'code',
      ],
    );
  }

  WorkshopTaskContract _verificationTask({
    required String projectId,
    required String objective,
    required WorkshopTaskMode mode,
    required WorkshopTaskResource preferredResource,
    required List<WorkshopTaskResource> fallbackResources,
    required String? dependsOn,
    required List<String> constraints,
  }) {
    return WorkshopTaskContract(
      id: '$projectId-task-verification',
      title: 'Verify implementation',
      objective:
          'Verify the implementation using tests, static analysis '
          'and repository constraints before a build is requested.',
      kind: WorkshopTaskKind.review,
      mode: mode,
      preferredResource: preferredResource,
      fallbackResources: fallbackResources,
      priority: WorkshopTaskPriority.high,
      instructions: <String>[
        'Run the narrowest useful verification first.',
        'Check for analyzer and test failures.',
        'Check that forbidden files were not modified.',
        'Do not silently repair unrelated problems.',
        'Report every remaining failure.',
      ],
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'tests-pass',
          description:
              'Relevant tests pass.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'analysis-pass',
          description:
              'Static analysis does not report blocking errors.',
        ),
      ],
      fileScope: const WorkshopTaskFileScope(),
      requiredCheckpoints: const <String>[
        'verification-complete',
      ],
      dependsOn: dependsOn == null
          ? const <String>[]
          : <String>[dependsOn],
      tags: <String>[
        'verification',
        'quality',
      ],
    );
  }

  WorkshopTaskContract _buildTask({
    required String projectId,
    required String objective,
    required WorkshopTaskMode mode,
    required WorkshopTaskResource preferredResource,
    required List<WorkshopTaskResource> fallbackResources,
    required String? dependsOn,
    required List<String> constraints,
  }) {
    return WorkshopTaskContract(
      id: '$projectId-task-build',
      title: 'Build project artifact',
      objective:
          'Build the project using the most appropriate available '
          'local or remote build resource.',
      kind: WorkshopTaskKind.build,
      mode: mode,
      preferredResource: preferredResource,
      fallbackResources: fallbackResources,
      priority: WorkshopTaskPriority.normal,
      instructions: <String>[
        'Use the local toolchain when it is available and suitable.',
        'Use GitHub Actions when the required platform is unavailable locally.',
        'Do not start a costly remote build without a verified reason.',
        'Preserve the build result as an artifact.',
      ],
      constraints: constraints,
      acceptanceCriteria: <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'build-complete',
          description:
              'The requested build completes successfully.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'artifact-available',
          description:
              'The generated artifact is available for review.',
        ),
      ],
      fileScope: const WorkshopTaskFileScope(),
      budget: const WorkshopTaskBudget(
        estimatedCredits: 0,
        minimumReserveCredits: 0,
      ),
      requiredCheckpoints: const <String>[
        'build-complete',
        'artifact-ready',
      ],
      dependsOn: dependsOn == null
          ? const <String>[]
          : <String>[dependsOn],
      tags: <String>[
        'build',
        'artifact',
      ],
    );
  }

  String _createProjectId(String objective) {
    final normalized = objective
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');

    final prefix = normalized.isEmpty
        ? 'workshop-project'
        : normalized.length > 32
            ? normalized.substring(0, 32)
            : normalized;

    return '$prefix-${DateTime.now().millisecondsSinceEpoch}';
  }
}
