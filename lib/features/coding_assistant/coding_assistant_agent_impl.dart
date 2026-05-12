import 'package:ai_orchestrator/core/agents/agent_lifecycle.dart';
import 'package:ai_orchestrator/core/agents/agent_message.dart';
import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/reasoning_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/planner/plan.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/tools/code_interpreter_tool.dart';
import 'package:flutter/foundation.dart';

/// Concrete implementation of [ReasoningAgent] for coding and planning tasks.
///
/// [CodingAssistantAgentImpl] orchestrates the full TaskWeaver-inspired loop:
///
/// 1. **Plan** – uses [PlannerService] to decompose the coding problem into
///    ordered [PlanStep]s.
/// 2. **Execute** – iterates over each step, calling [InferenceService] with a
///    step-specific prompt and the accumulated context from prior steps.
/// 3. **Interpret** – routes any step whose output looks like a code snippet
///    through [CodeInterpreterTool] for safety analysis.
/// 4. **Aggregate** – merges all step outputs into a final [ReasoningResult].
///
/// The agent is a *silent observer* for system-level operations: it never
/// writes to the file system or executes processes autonomously.  Code flagged
/// `[REQUIRES CONFIRMATION]` by [CodeInterpreterTool] is surfaced as-is so
/// the UI can request explicit user consent before running it.
class CodingAssistantAgentImpl implements ReasoningAgent {
  CodingAssistantAgentImpl({
    required PlannerService plannerService,
    required InferenceService inferenceService,
  })  : _plannerService = plannerService,
        _inferenceService = inferenceService;

  static const _logTag = 'CODING_AGENT';

  final PlannerService _plannerService;
  final InferenceService _inferenceService;
  final CodeInterpreterTool _codeInterpreter = const CodeInterpreterTool();

  AgentLifecycleState _lifecycleState = AgentLifecycleState.created;

  // ── BaseAgent identity ────────────────────────────────────────────────────

  @override
  String get id => 'coding_assistant';

  @override
  String get name => 'Coding Assistant';

  @override
  String get description =>
      'Plans and executes coding tasks using a TaskWeaver-inspired '
      'decompose-execute loop backed by the local inference engine.';

  @override
  String get strategyId => 'chain_of_thought';

  @override
  AgentLifecycleState get lifecycleState => _lifecycleState;

  @override
  bool get isRunning => _lifecycleState == AgentLifecycleState.active;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    _lifecycleState = AgentLifecycleState.idle;
    _log('initialized');
  }

  @override
  Future<void> activate() async {
    _lifecycleState = AgentLifecycleState.active;
    _log('activated');
  }

  @override
  Future<void> suspend() async {
    _lifecycleState = AgentLifecycleState.suspended;
    _log('suspended');
  }

  @override
  Future<void> shutdown() async {
    _lifecycleState = AgentLifecycleState.shutdown;
    _log('shutdown');
  }

  // ── Communication ─────────────────────────────────────────────────────────

  @override
  Future<void> communicate(AgentMessage message) async {
    // No inter-agent messaging in this milestone; silently ignored.
    _log('communicate: message type=${message.type} from=${message.senderId}');
  }

  // ── Task execution ────────────────────────────────────────────────────────

  @override
  Future<TaskExecutionResult> executeTask(
    String taskId,
    String instruction,
    SharedContext context,
  ) async {
    _log('executeTask: id=$taskId');
    final result = await reason(instruction, context);
    return TaskExecutionResult(
      taskId: taskId,
      agentId: id,
      output: result.conclusion,
      success: result.success,
      error: result.error,
    );
  }

  // ── ReasoningAgent ────────────────────────────────────────────────────────

  @override
  Future<ReasoningResult> reason(
    String problem,
    SharedContext context, {
    int maxSteps = 10,
  }) async {
    _log('reason: problem="${_truncate(problem)}"');

    // 1. Decompose the problem into a plan.
    final plan = await _plannerService.decompose(problem, isOffline: true);
    plan.status = PlanStatus.running;

    final reasoningSteps = <ReasoningStep>[];
    final contextBuffer = StringBuffer();

    // 2. Execute each plan step.
    final effectiveSteps = plan.steps.take(maxSteps).toList();
    for (final step in effectiveSteps) {
      step.status = StepStatus.running;

      // Build a focused prompt for this step, enriched with prior context.
      final stepPrompt = _buildStepPrompt(
        originalProblem: problem,
        step: step,
        priorContext: contextBuffer.toString(),
      );

      final response = await _inferenceService.infer(
        InferenceRequest(
          sessionId: '${context.sessionId}_step_${step.index}',
          prompt: stepPrompt,
          systemPrompt: _codingSystemPrompt,
          isOffline: true,
          maxTokens: 512,
          temperature: 0.3,
        ),
      );

      if (response.isError) {
        step.status = StepStatus.failed;
        step.error = response.errorMessage;
        plan.status = PlanStatus.failed;

        reasoningSteps.add(ReasoningStep(
          index: step.index,
          thought: 'Execute: ${step.description}',
          action: 'inference',
          observation: 'ERROR: ${response.errorMessage}',
        ));
        break;
      }

      // 3. Run code snippets through the safety interpreter.
      final stepOutput = await _interpretOutput(response.text);
      step.status = StepStatus.done;
      step.output = stepOutput;

      // Accumulate context for subsequent steps.
      contextBuffer
        ..writeln('Step ${step.index + 1}: ${step.description}')
        ..writeln('Result: $stepOutput')
        ..writeln();

      reasoningSteps.add(ReasoningStep(
        index: step.index,
        thought: 'Execute: ${step.description}',
        action: 'inference + code_interpreter',
        observation: stepOutput,
      ));
    }

    final allDone = plan.steps.every((s) => s.status == StepStatus.done);
    if (allDone) plan.status = PlanStatus.completed;

    final conclusion = allDone
        ? plan.combinedOutput
        : 'Planning incomplete. ${plan.steps.where((s) => s.status == StepStatus.failed).length} step(s) failed.';

    plan.summary = conclusion;

    _log('reason: done steps=${reasoningSteps.length} success=$allDone');

    return ReasoningResult(
      problem: problem,
      conclusion: conclusion,
      steps: reasoningSteps,
      success: allDone,
      error: allDone ? null : plan.summary,
    );
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  String _buildStepPrompt({
    required String originalProblem,
    required PlanStep step,
    required String priorContext,
  }) {
    final buffer = StringBuffer()
      ..writeln('Original goal: $originalProblem')
      ..writeln();
    if (priorContext.isNotEmpty) {
      buffer
        ..writeln('Context from previous steps:')
        ..writeln(priorContext);
    }
    buffer
      ..writeln('Current step (${step.index + 1}): ${step.description}')
      ..writeln()
      ..writeln('Provide a focused, concise response for this step only.');
    return buffer.toString();
  }

  /// Routes [text] through [CodeInterpreterTool] if it contains a code fence,
  /// otherwise returns [text] unchanged.
  Future<String> _interpretOutput(String text) async {
    if (!_looksLikeCode(text)) return text;

    final result = await _codeInterpreter.execute({
      'code': text,
      'language': _detectLanguage(text),
    });

    return result.success ? result.output : text;
  }

  static bool _looksLikeCode(String text) =>
      text.contains('```') ||
      text.contains('def ') ||
      text.contains('void ') ||
      text.contains('fun ') ||
      text.contains('import ');

  static String _detectLanguage(String text) {
    // Use multiple indicators per language to reduce false positives.
    var pythonScore = 0;
    var dartScore = 0;

    if (text.contains('```python')) pythonScore += 3;
    if (text.contains('def ') && text.contains(':')) pythonScore += 2;
    if (text.contains('import os') || text.contains('import sys')) pythonScore += 2;
    if (RegExp(r'\bprint\s*\(').hasMatch(text) && !text.contains('debugPrint')) {
      pythonScore += 1;
    }

    if (text.contains('```dart')) dartScore += 3;
    if (text.contains('void main') || text.contains('Future<')) dartScore += 2;
    if (text.contains('debugPrint') || text.contains('setState')) dartScore += 2;
    if (text.contains('final ') || text.contains('const ')) dartScore += 1;

    return dartScore >= pythonScore ? 'dart' : 'python';
  }

  static const String _codingSystemPrompt =
      'You are a senior software engineer assistant. '
      'Provide concise, precise technical responses. '
      'For code, use proper formatting with language-tagged fences (```dart or ```python). '
      'For analysis, use bullet points. '
      'Never include explanations outside of what is directly asked.';

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }

  static String _truncate(String text, [int maxLength = 80]) =>
      text.substring(0, text.length.clamp(0, maxLength));
}
