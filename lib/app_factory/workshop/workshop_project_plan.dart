/// Project planning model for the Workshop/Cantiere.
///
/// The Workshop is primarily a software-engineering environment, but the
/// project model is intentionally broader so that it can later support:
///
/// - software;
/// - embedded systems;
/// - electronics;
/// - robotics;
/// - 3D printing;
/// - mechanical prototyping;
/// - IoT;
/// - multidisciplinary projects.
///
/// The project plan describes WHAT has to be built and HOW the work is
/// organised. It does not itself modify files, hardware or repositories.
library;

/// Broad technical domain of a Workshop project.
enum WorkshopProjectDomain {
  software,
  embedded,
  electronics,
  robotics,
  threeDPrinting,
  mechanical,
  iot,
  multidisciplinary,
  research,
  other,
}

/// Current lifecycle state of a Workshop project.
enum WorkshopProjectStatus {
  draft,
  planned,
  inProgress,
  blocked,
  review,
  validation,
  completed,
  cancelled,
}

/// State of an individual project phase.
enum WorkshopProjectPhaseStatus {
  pending,
  inProgress,
  blocked,
  completed,
  skipped,
}

/// Priority assigned to a project phase or task.
enum WorkshopProjectPriority {
  low,
  normal,
  high,
  critical,
}

/// A single phase in the Workshop project plan.
final class WorkshopProjectPhase {
  WorkshopProjectPhase({
    required this.id,
    required this.title,
    required this.description,
    this.status = WorkshopProjectPhaseStatus.pending,
    this.priority = WorkshopProjectPriority.normal,
    List<String> taskIds = const <String>[],
    List<String> dependencies = const <String>[],
    List<String> affectedPaths = const <String>[],
    List<String> validationCriteria = const <String>[],
  })  : taskIds = List.unmodifiable(taskIds),
        dependencies = List.unmodifiable(dependencies),
        affectedPaths = List.unmodifiable(affectedPaths),
        validationCriteria = List.unmodifiable(validationCriteria);

  final String id;
  final String title;
  final String description;

  WorkshopProjectPhaseStatus status;
  WorkshopProjectPriority priority;

  final List<String> taskIds;
  final List<String> dependencies;
  final List<String> affectedPaths;
  final List<String> validationCriteria;

  bool get isComplete =>
      status == WorkshopProjectPhaseStatus.completed;

  bool get isBlocked =>
      status == WorkshopProjectPhaseStatus.blocked;

  WorkshopProjectPhase copyWith({
    String? id,
    String? title,
    String? description,
    WorkshopProjectPhaseStatus? status,
    WorkshopProjectPriority? priority,
    List<String>? taskIds,
    List<String>? dependencies,
    List<String>? affectedPaths,
    List<String>? validationCriteria,
  }) {
    return WorkshopProjectPhase(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      taskIds: taskIds ?? this.taskIds,
      dependencies: dependencies ?? this.dependencies,
      affectedPaths: affectedPaths ?? this.affectedPaths,
      validationCriteria:
          validationCriteria ?? this.validationCriteria,
    );
  }

  @override
  String toString() {
    return 'WorkshopProjectPhase('
        'id: $id, '
        'title: $title, '
        'status: $status'
        ')';
  }
}

/// A concrete task belonging to a Workshop project.
final class WorkshopProjectTask {
  WorkshopProjectTask({
    required this.id,
    required this.title,
    required this.description,
    required this.phaseId,
    this.priority = WorkshopProjectPriority.normal,
    this.completed = false,
    List<String> dependencies = const <String>[],
    List<String> affectedPaths = const <String>[],
    List<String> validationCriteria = const <String>[],
  })  : dependencies = List.unmodifiable(dependencies),
        affectedPaths = List.unmodifiable(affectedPaths),
        validationCriteria = List.unmodifiable(validationCriteria);

  final String id;
  final String title;
  final String description;
  final String phaseId;

  final WorkshopProjectPriority priority;

  bool completed;

  final List<String> dependencies;
  final List<String> affectedPaths;
  final List<String> validationCriteria;

  /// Indicates that this task has dependencies.
  ///
  /// The authoritative dependency state is calculated by
  /// [WorkshopProjectPlan.isTaskBlocked], because only the complete
  /// project graph can determine whether those dependencies are complete.
  bool get hasDependencies => dependencies.isNotEmpty;

  WorkshopProjectTask copyWith({
    String? id,
    String? title,
    String? description,
    String? phaseId,
    WorkshopProjectPriority? priority,
    bool? completed,
    List<String>? dependencies,
    List<String>? affectedPaths,
    List<String>? validationCriteria,
  }) {
    return WorkshopProjectTask(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      phaseId: phaseId ?? this.phaseId,
      priority: priority ?? this.priority,
      completed: completed ?? this.completed,
      dependencies: dependencies ?? this.dependencies,
      affectedPaths: affectedPaths ?? this.affectedPaths,
      validationCriteria:
          validationCriteria ?? this.validationCriteria,
    );
  }

  @override
  String toString() {
    return 'WorkshopProjectTask('
        'id: $id, '
        'phaseId: $phaseId, '
        'completed: $completed'
        ')';
  }
}

/// Main project plan used by the Workshop.
///
/// The plan is deliberately independent from the repository implementation.
///
/// A project can therefore exist before any code is written.
final class WorkshopProjectPlan {
  WorkshopProjectPlan({
    required this.id,
    required this.title,
    required this.goal,
    this.domain = WorkshopProjectDomain.software,
    this.status = WorkshopProjectStatus.draft,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> assumptions = const <String>[],
    List<String> technologies = const <String>[],
    List<String> hardware = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
    List<String> risks = const <String>[],
    List<WorkshopProjectPhase> phases =
        const <WorkshopProjectPhase>[],
    List<WorkshopProjectTask> tasks =
        const <WorkshopProjectTask>[],
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        requirements = List.unmodifiable(requirements),
        constraints = List.unmodifiable(constraints),
        assumptions = List.unmodifiable(assumptions),
        technologies = List.unmodifiable(technologies),
        hardware = List.unmodifiable(hardware),
        deliverables = List.unmodifiable(deliverables),
        validationCriteria = List.unmodifiable(validationCriteria),
        risks = List.unmodifiable(risks),
        phases = List.unmodifiable(phases),
        tasks = List.unmodifiable(tasks);

  final String id;
  final String title;
  final String goal;

  final WorkshopProjectDomain domain;
  WorkshopProjectStatus status;

  final DateTime createdAt;
  DateTime updatedAt;

  final List<String> requirements;
  final List<String> constraints;
  final List<String> assumptions;
  final List<String> technologies;
  final List<String> hardware;
  final List<String> deliverables;
  final List<String> validationCriteria;
  final List<String> risks;

  final List<WorkshopProjectPhase> phases;
  final List<WorkshopProjectTask> tasks;

  int get completedTasks =>
      tasks.where((task) => task.completed).length;

  int get totalTasks => tasks.length;

  double get progress {
    if (totalTasks == 0) {
      return 0.0;
    }

    return completedTasks / totalTasks;
  }

  bool get isComplete =>
      status == WorkshopProjectStatus.completed;

  WorkshopProjectPhase? phaseById(String phaseId) {
    for (final phase in phases) {
      if (phase.id == phaseId) {
        return phase;
      }
    }

    return null;
  }

  WorkshopProjectTask? taskById(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) {
        return task;
      }
    }

    return null;
  }

  List<WorkshopProjectTask> tasksForPhase(
    String phaseId,
  ) {
    return List.unmodifiable(
      tasks.where((task) => task.phaseId == phaseId),
    );
  }

  List<WorkshopProjectPhase> get incompletePhases {
    return List.unmodifiable(
      phases.where((phase) => !phase.isComplete),
    );
  }

  bool arePhaseDependenciesComplete(
    WorkshopProjectPhase phase,
  ) {
    return phase.dependencies.every(
      (dependencyId) =>
          phaseById(dependencyId)?.isComplete ?? false,
    );
  }

  bool areTaskDependenciesComplete(
    WorkshopProjectTask task,
  ) {
    return task.dependencies.every(
      (dependencyId) =>
          taskById(dependencyId)?.completed ?? false,
    );
  }

  bool isTaskBlocked(
    WorkshopProjectTask task,
  ) {
    if (task.completed) {
      return false;
    }

    return !areTaskDependenciesComplete(task);
  }

  WorkshopProjectPhase? get nextAvailablePhase {
    for (final phase in phases) {
      if (phase.status != WorkshopProjectPhaseStatus.pending) {
        continue;
      }

      if (arePhaseDependenciesComplete(phase)) {
        return phase;
      }
    }

    return null;
  }

  WorkshopProjectTask? get nextAvailableTask {
    for (final task in tasks) {
      if (task.completed) {
        continue;
      }

      if (areTaskDependenciesComplete(task)) {
        return task;
      }
    }

    return null;
  }

  WorkshopProjectPlan copyWith({
    String? id,
    String? title,
    String? goal,
    WorkshopProjectDomain? domain,
    WorkshopProjectStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? requirements,
    List<String>? constraints,
    List<String>? assumptions,
    List<String>? technologies,
    List<String>? hardware,
    List<String>? deliverables,
    List<String>? validationCriteria,
    List<String>? risks,
    List<WorkshopProjectPhase>? phases,
    List<WorkshopProjectTask>? tasks,
  }) {
    return WorkshopProjectPlan(
      id: id ?? this.id,
      title: title ?? this.title,
      goal: goal ?? this.goal,
      domain: domain ?? this.domain,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      requirements: requirements ?? this.requirements,
      constraints: constraints ?? this.constraints,
      assumptions: assumptions ?? this.assumptions,
      technologies: technologies ?? this.technologies,
      hardware: hardware ?? this.hardware,
      deliverables: deliverables ?? this.deliverables,
      validationCriteria:
          validationCriteria ?? this.validationCriteria,
      risks: risks ?? this.risks,
      phases: phases ?? this.phases,
      tasks: tasks ?? this.tasks,
    );
  }

  @override
  String toString() {
    return 'WorkshopProjectPlan('
        'id: $id, '
        'title: $title, '
        'domain: $domain, '
        'status: $status, '
        'progress: ${(progress * 100).toStringAsFixed(1)}%'
        ')';
  }
}
