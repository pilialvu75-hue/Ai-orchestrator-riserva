/// Conversation contract for the Workshop/Cantiere.
///
/// The Workshop is a programming-focused conversational environment.
/// This contract describes WHAT the user wants to do without coupling
/// the decision to:
///
/// - a specific LLM;
/// - the Assistant Chat;
/// - the UI;
/// - the repository implementation;
/// - the local/cloud runtime.
///
/// The same natural-language conversation can therefore be interpreted
/// by different models while preserving the Workshop behaviour.
library;

/// High-level interaction mode selected for a Workshop request.
enum WorkshopInteractionMode {
  /// The user delegates the construction.
  ///
  /// Example:
  /// "Fammi un'app per un meccanico."
  ///
  /// The Workshop should proceed autonomously through the construction
  /// pipeline and eventually present the result for confirmation.
  directBuild,

  /// The user wants to construct the project together.
  ///
  /// Example:
  /// "Facciamo un'app per un meccanico."
  ///
  /// The Workshop should first explain the plan and then work through
  /// the project step by step with the user.
  collaborativePlanning,

  /// The user wants to continue an already established construction.
  ///
  /// Example:
  /// "Bene, ora facciamo il prossimo file."
  continuation,

  /// The user asks the Workshop to inspect or review existing work.
  ///
  /// Example:
  /// "Controlla quello che abbiamo fatto."
  review,

  /// The user explicitly asks to modify an existing implementation.
  ///
  /// Example:
  /// "Cambia il login e aggiungi il recupero password."
  modification,

  /// The user wants an explanation rather than a code change.
  ///
  /// Example:
  /// "Perché hai scelto questa architettura?"
  explanation,

  /// The user asks the Workshop to diagnose a problem.
  ///
  /// Example:
  /// "La build è rossa, trova il problema."
  diagnosis,

  /// The request is not sufficiently clear to safely choose a workflow.
  clarification,
}

/// High-level task requested by the user.
enum WorkshopConversationAction {
  build,
  plan,
  continueWork,
  review,
  modify,
  explain,
  diagnose,
  clarify,
}

/// Result of interpreting one Workshop user message.
///
/// This object represents intent, not an LLM response.
///
/// It is deliberately deterministic and serializable so it can later be
/// persisted with a Workshop session.
final class WorkshopConversationIntent {
  const WorkshopConversationIntent({
    required this.mode,
    required this.action,
    required this.confidence,
    this.projectDescription,
    this.requestedOutcome,
    this.currentStep,
    this.reason,
  });

  /// Overall Workshop interaction mode.
  final WorkshopInteractionMode mode;

  /// Concrete action requested by the user.
  final WorkshopConversationAction action;

  /// Confidence of the interpretation in the range 0.0 - 1.0.
  final double confidence;

  /// Natural-language description of the project, when available.
  final String? projectDescription;

  /// Desired final outcome, when identifiable.
  final String? requestedOutcome;

  /// Current step being requested in an existing construction.
  final String? currentStep;

  /// Optional explanation of why this intent was selected.
  final String? reason;

  bool get isDirectBuild =>
      mode == WorkshopInteractionMode.directBuild;

  bool get isCollaborative =>
      mode == WorkshopInteractionMode.collaborativePlanning;

  bool get isContinuation =>
      mode == WorkshopInteractionMode.continuation;

  bool get isReview =>
      mode == WorkshopInteractionMode.review;

  bool get isModification =>
      mode == WorkshopInteractionMode.modification;

  bool get isExplanation =>
      mode == WorkshopInteractionMode.explanation;

  bool get isDiagnosis =>
      mode == WorkshopInteractionMode.diagnosis;

  bool get requiresClarification =>
      mode == WorkshopInteractionMode.clarification ||
      action == WorkshopConversationAction.clarify;

  bool get hasProjectDescription =>
      projectDescription != null &&
      projectDescription!.trim().isNotEmpty;

  bool get hasRequestedOutcome =>
      requestedOutcome != null &&
      requestedOutcome!.trim().isNotEmpty;

  /// Returns a safe confidence value even if an external classifier
  /// supplied a value outside the expected range.
  double get normalizedConfidence {
    if (confidence < 0.0) {
      return 0.0;
    }

    if (confidence > 1.0) {
      return 1.0;
    }

    return confidence;
  }

  WorkshopConversationIntent copyWith({
    WorkshopInteractionMode? mode,
    WorkshopConversationAction? action,
    double? confidence,
    String? projectDescription,
    String? requestedOutcome,
    String? currentStep,
    String? reason,
  }) {
    return WorkshopConversationIntent(
      mode: mode ?? this.mode,
      action: action ?? this.action,
      confidence: confidence ?? this.confidence,
      projectDescription:
          projectDescription ?? this.projectDescription,
      requestedOutcome:
          requestedOutcome ?? this.requestedOutcome,
      currentStep: currentStep ?? this.currentStep,
      reason: reason ?? this.reason,
    );
  }

  @override
  String toString() {
    return 'WorkshopConversationIntent('
        'mode: $mode, '
        'action: $action, '
        'confidence: $normalizedConfidence, '
        'projectDescription: $projectDescription, '
        'requestedOutcome: $requestedOutcome, '
        'currentStep: $currentStep'
        ')';
  }
}

/// Describes how the Workshop should respond after understanding a request.
///
/// This is intentionally separate from [WorkshopConversationIntent]:
/// intent describes what the user wants, while response strategy describes
/// how the Workshop should proceed.
enum WorkshopResponseStrategy {
  /// Explain the plan and wait for user confirmation.
  presentPlan,

  /// Start construction and return the result for confirmation.
  buildAndConfirm,

  /// Perform the next step and explain what changed.
  executeNextStep,

  /// Inspect the project and report findings.
  analyseAndReport,

  /// Explain the reasoning without changing anything.
  explainOnly,

  /// Diagnose the problem and propose a solution.
  diagnoseAndPropose,

  /// Ask the user for the missing information.
  askClarification,
}

/// Complete conversational decision produced by the Workshop.
///
/// Example 1:
///
/// User:
/// "Fammi questa applicazione."
///
/// Decision:
/// directBuild + buildAndConfirm
///
/// Example 2:
///
/// User:
/// "Facciamo un'app per un meccanico."
///
/// Decision:
/// collaborativePlanning + presentPlan
///
/// Example 3:
///
/// User:
/// "Ok, facciamo il prossimo file."
///
/// Decision:
/// continuation + executeNextStep
final class WorkshopConversationDecision {
  const WorkshopConversationDecision({
    required this.intent,
    required this.strategy,
    this.userMessage,
  });

  final WorkshopConversationIntent intent;

  final WorkshopResponseStrategy strategy;

  /// Original user message associated with this decision.
  final String? userMessage;

  bool get waitsForConfirmation =>
      strategy == WorkshopResponseStrategy.presentPlan ||
      strategy == WorkshopResponseStrategy.buildAndConfirm;

  bool get performsWork =>
      strategy == WorkshopResponseStrategy.buildAndConfirm ||
      strategy == WorkshopResponseStrategy.executeNextStep;

  bool get changesProject =>
      performsWork &&
      !intent.requiresClarification;

  bool get onlyExplains =>
      strategy == WorkshopResponseStrategy.explainOnly;

  bool get asksClarification =>
      strategy == WorkshopResponseStrategy.askClarification;

  @override
  String toString() {
    return 'WorkshopConversationDecision('
        'intent: $intent, '
        'strategy: $strategy'
        ')';
  }
}
