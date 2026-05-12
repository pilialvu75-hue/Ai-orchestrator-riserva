/// Status of an individual [PlanStep].
enum StepStatus {
  /// The step has not been started yet.
  pending,

  /// The step is currently being executed.
  running,

  /// The step completed successfully.
  done,

  /// The step failed; see [PlanStep.error].
  failed,

  /// The step was skipped (e.g. because a prior step failed).
  skipped,
}

/// Status of a [Plan] as a whole.
enum PlanStatus {
  /// The plan has been created but execution has not started.
  created,

  /// At least one step is running or pending.
  running,

  /// All steps completed successfully.
  completed,

  /// One or more steps failed and execution was halted.
  failed,
}

/// A single, discrete step within a [Plan].
///
/// Each step has a natural-language [description] and is executed
/// sequentially by the planning engine.
class PlanStep {
  PlanStep({
    required this.index,
    required this.description,
    this.status = StepStatus.pending,
    this.output,
    this.error,
  });

  /// Zero-based position of this step in the plan.
  final int index;

  /// Human-readable description of what this step does.
  final String description;

  /// Execution status of this step.
  StepStatus status;

  /// The output produced when this step completed successfully.
  String? output;

  /// Error message when [status] is [StepStatus.failed].
  String? error;

  /// Returns a copy of this step with the given fields replaced.
  PlanStep copyWith({
    StepStatus? status,
    String? output,
    String? error,
  }) {
    return PlanStep(
      index: index,
      description: description,
      status: status ?? this.status,
      output: output ?? this.output,
      error: error ?? this.error,
    );
  }

  @override
  String toString() => 'PlanStep[$index](${status.name}): $description';
}

/// A structured decomposition of a high-level goal into ordered [PlanStep]s.
///
/// Inspired by the TaskWeaver Planner: the goal is analysed by an LLM and
/// broken into discrete, executable steps.  The [PlannerService] creates
/// and owns [Plan] instances; downstream components read them.
class Plan {
  Plan({
    required this.id,
    required this.goal,
    required this.steps,
    this.status = PlanStatus.created,
    this.summary,
  });

  /// Unique identifier for this plan (a UUID or short hash).
  final String id;

  /// The original high-level goal that triggered plan creation.
  final String goal;

  /// Ordered list of steps to be executed.
  final List<PlanStep> steps;

  /// Overall execution status.
  PlanStatus status;

  /// Optional human-readable summary of the plan outcome, populated after
  /// all steps have been executed.
  String? summary;

  /// `true` when every step has [StepStatus.done].
  bool get isComplete => steps.every((s) => s.status == StepStatus.done);

  /// `true` when any step has [StepStatus.failed].
  bool get hasFailed => steps.any((s) => s.status == StepStatus.failed);

  /// Concatenates all step outputs, separated by newlines.
  String get combinedOutput =>
      steps.map((s) => s.output ?? '').where((o) => o.isNotEmpty).join('\n');

  @override
  String toString() =>
      'Plan(id: $id, steps: ${steps.length}, status: ${status.name})';
}
