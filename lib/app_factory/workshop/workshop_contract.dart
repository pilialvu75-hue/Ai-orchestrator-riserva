/// Core contract for the App Factory Workshop.
///
/// The Workshop is intentionally independent from the Assistant chat.
/// It defines the language exchanged between the construction pipeline,
/// the workspace, the coding agent and the validation stages.
///
/// This file contains contracts only:
/// - no Flutter UI
/// - no repository implementation
/// - no Git implementation
/// - no network calls
/// - no LLM provider
///
/// Keeping these definitions isolated allows the Workshop to evolve
/// independently from the personal Assistant.
library;

/// Current lifecycle stage of a Workshop task.
enum WorkshopStage {
  /// Request received but not yet analysed.
  requested,

  /// Requirements and constraints are being analysed.
  analysis,

  /// Architecture and implementation plan are being prepared.
  planning,

  /// Files are being created or modified.
  implementation,

  /// Changes are being checked before validation.
  review,

  /// Build, tests or static analysis are running.
  validation,

  /// Validation completed successfully.
  completed,

  /// The task cannot continue without intervention.
  blocked,

  /// The task was explicitly cancelled.
  cancelled,
}

/// Origin of a Workshop request.
enum WorkshopRequestSource {
  /// User opened the Workshop directly.
  user,

  /// The Assistant delegated a construction task.
  assistant,

  /// Another Workshop task generated this request.
  workshop,

  /// Internal system operation.
  system,
}

/// Kind of operation requested from the Workshop.
enum WorkshopOperation {
  /// Understand the existing project before changing it.
  analyse,

  /// Create a new file or component.
  create,

  /// Modify an existing file.
  modify,

  /// Remove an obsolete component.
  remove,

  /// Refactor without intentionally changing behaviour.
  refactor,

  /// Repair an identified defect.
  fix,

  /// Improve performance without changing the intended behaviour.
  optimize,

  /// Run validation without modifying project files.
  validate,
}

/// A single construction request.
///
/// This is deliberately provider-agnostic.  The Workshop can therefore
/// work with a local model, ChatGPT, Gemini, Claude or another provider
/// without changing the contract.
class WorkshopRequest {
  const WorkshopRequest({
    required this.id,
    required this.title,
    required this.instruction,
    this.source = WorkshopRequestSource.user,
    this.operation = WorkshopOperation.analyse,
    this.projectPath,
    this.targetFiles = const <String>[],
    this.constraints = const <String>[],
    this.context = const <String>[],
  });

  /// Unique identifier for this construction request.
  final String id;

  /// Short human-readable description.
  final String title;

  /// Natural-language construction instruction.
  final String instruction;

  /// Who initiated the request.
  final WorkshopRequestSource source;

  /// Main operation requested.
  final WorkshopOperation operation;

  /// Optional workspace/project root.
  final String? projectPath;

  /// Files explicitly involved in the request.
  final List<String> targetFiles;

  /// Constraints that must never be violated.
  final List<String> constraints;

  /// Additional context supplied by the Assistant, user or Workshop.
  final List<String> context;

  WorkshopRequest copyWith({
    String? id,
    String? title,
    String? instruction,
    WorkshopRequestSource? source,
    WorkshopOperation? operation,
    String? projectPath,
    List<String>? targetFiles,
    List<String>? constraints,
    List<String>? context,
  }) {
    return WorkshopRequest(
      id: id ?? this.id,
      title: title ?? this.title,
      instruction: instruction ?? this.instruction,
      source: source ?? this.source,
      operation: operation ?? this.operation,
      projectPath: projectPath ?? this.projectPath,
      targetFiles: targetFiles ?? this.targetFiles,
      constraints: constraints ?? this.constraints,
      context: context ?? this.context,
    );
  }
}

/// Result of one Workshop operation.
///
/// A result contains information about what happened, rather than directly
/// coupling the Workshop to a UI or a specific LLM provider.
class WorkshopResult {
  const WorkshopResult({
    required this.requestId,
    required this.stage,
    required this.success,
    this.summary = '',
    this.message = '',
    this.changedFiles = const <String>[],
    this.warnings = const <String>[],
    this.errors = const <String>[],
    this.nextActions = const <String>[],
  });

  final String requestId;
  final WorkshopStage stage;
  final bool success;

  /// Short description suitable for the user or Assistant.
  final String summary;

  /// Detailed human-readable information.
  final String message;

  /// Files actually changed by the operation.
  final List<String> changedFiles;

  /// Non-fatal issues discovered during the operation.
  final List<String> warnings;

  /// Fatal or blocking issues.
  final List<String> errors;

  /// Suggested next steps for the pipeline.
  final List<String> nextActions;

  bool get hasChanges => changedFiles.isNotEmpty;
  bool get hasWarnings => warnings.isNotEmpty;
  bool get hasErrors => errors.isNotEmpty;
}

/// A constraint that the Workshop must preserve.
///
/// This provides an explicit place for the safety rules that are especially
/// important for this project: build stability, existing functionality and
/// controlled modifications.
class WorkshopConstraint {
  const WorkshopConstraint({
    required this.id,
    required this.description,
    this.mandatory = true,
  });

  final String id;
  final String description;
  final bool mandatory;
}

/// Standard construction constraints.
///
/// These are intentionally conservative.  The Workshop should improve the
/// application without silently destroying existing working subsystems.
abstract final class WorkshopConstraints {
  static const WorkshopConstraint preserveBuild = WorkshopConstraint(
    id: 'preserve_build',
    description: 'Do not knowingly leave the project in a non-building state.',
  );

  static const WorkshopConstraint preserveExistingBehaviour = WorkshopConstraint(
    id: 'preserve_existing_behaviour',
    description:
        'Do not remove working functionality unless the request explicitly requires it.',
  );

  static const WorkshopConstraint preserveAssistant = WorkshopConstraint(
    id: 'preserve_assistant',
    description:
        'Keep the personal Assistant pipeline independent from Workshop-specific code.',
  );

  static const WorkshopConstraint preserveInternet = WorkshopConstraint(
    id: 'preserve_internet',
    description:
        'Do not disable or remove Internet capabilities that are already part of the application.',
  );

  static const WorkshopConstraint controlledChanges = WorkshopConstraint(
    id: 'controlled_changes',
    description:
        'Prefer small, reviewable changes and avoid unrelated modifications.',
  );

  static const WorkshopConstraint validateBeforeComplete = WorkshopConstraint(
    id: 'validate_before_complete',
    description:
        'A construction task is not considered complete until the relevant validation has been performed.',
  );

  static const List<WorkshopConstraint> defaults = <WorkshopConstraint>[
    preserveBuild,
    preserveExistingBehaviour,
    preserveAssistant,
    preserveInternet,
    controlledChanges,
    validateBeforeComplete,
  ];
}

/// A lightweight hand-off from the Assistant to the Workshop.
///
/// The Assistant can provide architectural guidance without taking ownership
/// of the Workshop implementation.
class WorkshopBrief {
  const WorkshopBrief({
    required this.requestId,
    required this.objective,
    this.architecturalGuidance = const <String>[],
    this.engineeringGuidance = const <String>[],
    this.acceptanceCriteria = const <String>[],
    this.context = const <String>[],
  });

  final String requestId;
  final String objective;

  /// Guidance originating from the architectural role.
  final List<String> architecturalGuidance;

  /// Guidance originating from the engineering role.
  final List<String> engineeringGuidance;

  /// Conditions that must be satisfied before the task is accepted.
  final List<String> acceptanceCriteria;

  /// Additional context supplied to the Workshop.
  final List<String> context;
}
