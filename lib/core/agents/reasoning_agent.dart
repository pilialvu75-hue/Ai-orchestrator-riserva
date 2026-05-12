import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';

/// Abstract contract for the reasoning agent role.
///
/// The [ReasoningAgent] is the **problem-solving specialist** of the
/// multi-agent system.  Its responsibilities are:
///
/// - Break down ambiguous problems into discrete reasoning steps.
/// - Apply chain-of-thought or scratchpad strategies (placeholder).
/// - Evaluate multiple hypotheses and select the most plausible one.
/// - Return a well-structured [ReasoningResult] with an explanation trace.
///
/// Concrete implementations will wrap a language model with a structured
/// prompting strategy (CoT, ReAct, ToT, etc.).  No real AI logic is
/// implemented here — this is a pure architectural contract.
///
/// Dependency rule:
///   core/agents/ ← features/ reasoning implementations
///   core/agents/ → core/ only (no native/ or features/ imports here)
abstract class ReasoningAgent extends BaseAgent {
  /// Reasons over [problem] using the supplied [context] and returns a
  /// structured [ReasoningResult].
  ///
  /// The [maxSteps] parameter caps the depth of the reasoning chain to prevent
  /// runaway inference (default: 10).
  Future<ReasoningResult> reason(
    String problem,
    SharedContext context, {
    int maxSteps = 10,
  });

  /// Returns the reasoning strategy this agent uses (e.g. `'chain_of_thought'`,
  /// `'react'`, `'tree_of_thought'`).
  ///
  /// Used by the [OrchestratorAgent] to select the best reasoner for a task.
  String get strategyId;

  // TODO(future): add explainStep(int stepIndex) for step-level debugging.
  // TODO(future): add Stream<ReasoningStep> reasonStreaming() for live traces.
}

/// A single step in a [ReasoningResult] trace.
class ReasoningStep {
  const ReasoningStep({
    required this.index,
    required this.thought,
    this.action,
    this.observation,
  });

  /// Zero-based position of this step in the chain.
  final int index;

  /// The agent's internal thought at this step.
  final String thought;

  /// Optional action the agent decided to take (e.g. call a tool).
  final String? action;

  /// Optional observation produced after the action.
  final String? observation;

  @override
  String toString() => 'ReasoningStep[$index]: $thought';
}

/// Structured result produced by [ReasoningAgent.reason].
class ReasoningResult {
  const ReasoningResult({
    required this.problem,
    required this.conclusion,
    required this.steps,
    this.confidence = 1.0,
    this.success = true,
    this.error,
  });

  /// The original problem that was reasoned about.
  final String problem;

  /// The final conclusion reached after all reasoning steps.
  final String conclusion;

  /// Ordered list of intermediate reasoning steps.
  final List<ReasoningStep> steps;

  /// Confidence score in the range [0.0, 1.0] (placeholder; always 1.0 now).
  final double confidence;

  /// Whether reasoning completed without error.
  final bool success;

  /// Error description when [success] is `false`.
  final String? error;

  @override
  String toString() =>
      'ReasoningResult(steps: ${steps.length}, confidence: $confidence, '
      'success: $success)';
}
