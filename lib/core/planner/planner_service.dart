import 'package:ai_orchestrator/core/planner/plan.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// TaskWeaver-inspired planning engine.
///
/// [PlannerService] uses the configured [InferenceService] to decompose a
/// high-level user goal into an ordered sequence of [PlanStep]s, forming a
/// [Plan].  All inference is performed via the local-first [InferenceService],
/// honouring the offline-first mandate.
///
/// **Step decomposition flow:**
/// 1. Build a structured system prompt that instructs the LLM to emit a
///    numbered list.
/// 2. Infer with a short `maxTokens` budget to keep latency low.
/// 3. Parse the LLM response with [_parseSteps]; fall back to a single-step
///    plan if parsing fails.
/// 4. Return a [Plan] with [PlanStatus.created] ready for execution.
///
/// Dependency rule:
///   core/planner/ → core/runtime/  (within-core allowed)
///   core/planner/ → native/        (forbidden)
class PlannerService {
  static const _logTag = 'PLANNER';
  static const _plannerSessionId = 'planner_session';

  PlannerService({required InferenceService inferenceService})
      : _inferenceService = inferenceService;

  final InferenceService _inferenceService;
  final _uuid = const Uuid();

  /// Decomposes [goal] into a [Plan].
  ///
  /// The returned plan is in [PlanStatus.created] state; the caller is
  /// responsible for executing the steps (e.g. via [SequentialPlanningStrategy]).
  ///
  /// [isOffline] is forwarded to [InferenceService] so the local runtime is
  /// always preferred when the device has no network.
  Future<Plan> decompose(
    String goal, {
    bool isOffline = false,
  }) async {
    _log('decompose: goal="${goal.substring(0, goal.length.clamp(0, 80))}"');

    final rawResponse = await _inferenceService.infer(
      InferenceRequest(
        sessionId: _plannerSessionId,
        prompt: goal,
        systemPrompt: _buildSystemPrompt(),
        isOffline: isOffline,
        maxTokens: 512,
        temperature: 0.2,
      ),
    );

    if (rawResponse.isError) {
      _log('decompose: inference error – ${rawResponse.errorMessage}');
      return _fallbackPlan(goal);
    }

    final steps = _parseSteps(rawResponse.text);
    if (steps.isEmpty) {
      _log('decompose: no steps parsed – using fallback plan');
      return _fallbackPlan(goal);
    }

    _log('decompose: parsed ${steps.length} step(s)');
    return Plan(
      id: _uuid.v4(),
      goal: goal,
      steps: steps,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  String _buildSystemPrompt() => '''
You are a planning assistant embedded in an offline-first AI orchestrator.
Your sole task is to decompose the user's goal into an ordered list of discrete, actionable steps.

Rules:
- Output ONLY a numbered list. One step per line.
- Format: "1. <step description>"
- Maximum 10 steps.
- Each step must be concise (one sentence).
- Do NOT include explanations, headers, or any text outside the numbered list.
- For coding tasks, steps should include: understand requirements, plan solution, write code, verify logic, handle edge cases.
- For analysis tasks, steps should include: gather context, identify issues, propose fixes.
''';

  /// Parses a numbered list of steps from [text].
  ///
  /// Accepts lines matching `^\d+[.)]\s+(.+)$` (both period and parenthesis
  /// separators are handled for robustness).
  List<PlanStep> _parseSteps(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final steps = <PlanStep>[];
    final stepPattern = RegExp(r'^\s*\d+[.)]\s+(.+)$');

    for (final line in lines) {
      final match = stepPattern.firstMatch(line.trim());
      if (match != null) {
        final description = match.group(1)!.trim();
        if (description.isNotEmpty) {
          steps.add(PlanStep(index: steps.length, description: description));
        }
      }
    }
    return steps;
  }

  /// Returns a single-step fallback [Plan] when LLM decomposition fails.
  Plan _fallbackPlan(String goal) => Plan(
        id: _uuid.v4(),
        goal: goal,
        steps: [PlanStep(index: 0, description: goal)],
      );

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }
}
