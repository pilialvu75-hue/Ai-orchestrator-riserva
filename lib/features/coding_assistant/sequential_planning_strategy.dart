import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/orchestrator_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';
import 'package:ai_orchestrator/core/agents/task_dispatcher.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestration_strategy.dart';
import 'package:ai_orchestrator/core/planner/plan.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Concrete [OrchestrationStrategy] that executes plan steps sequentially.
///
/// Inspired by TaskWeaver's sequential execution mode, this strategy:
///
/// 1. Calls [PlannerService.decompose] to break the [goal] into a [Plan].
/// 2. Dispatches each [PlanStep] as an [AgentTask] via [TaskDispatcher] in order.
/// 3. Fails fast: if any step's [TaskResult.success] is `false`, execution stops
///    and remaining steps are marked [StepStatus.skipped].
/// 4. Returns an [OrchestrationResult] with per-step details.
///
/// **Safety guarantee**: this strategy only dispatches to registered [agents];
/// it never executes system-level code autonomously.  Code tasks flagged
/// `[REQUIRES CONFIRMATION]` by [CodeInterpreterTool] surface in the step
/// output; the UI layer is responsible for gating execution.
class SequentialPlanningStrategy implements OrchestrationStrategy {
  SequentialPlanningStrategy({required PlannerService plannerService})
      : _plannerService = plannerService;

  static const _logTag = 'SEQ_STRATEGY';

  final PlannerService _plannerService;
  final _uuid = const Uuid();

  @override
  String get id => 'sequential';

  @override
  String get name => 'Sequential Planning';

  @override
  Future<OrchestrationResult> execute(
    String goal,
    List<BaseAgent> agents,
    SharedContext context,
    TaskDispatcher dispatcher,
  ) async {
    _log('execute: goal="${goal.substring(0, goal.length.clamp(0, 80))}"');

    final runId = _uuid.v4();

    if (agents.isEmpty || !dispatcher.hasAvailableAgent) {
      return OrchestrationResult(
        runId: runId,
        goal: goal,
        taskResults: const [],
        success: false,
        error: 'No agents available to execute the plan.',
      );
    }

    // 1. Decompose goal into a plan.
    final plan = await _plannerService.decompose(goal, isOffline: true);
    plan.status = PlanStatus.running;
    _log('execute: plan id=${plan.id} steps=${plan.steps.length}');

    final taskResults = <TaskResult>[];
    bool overallSuccess = true;

    // 2. Execute each step sequentially.
    for (final step in plan.steps) {
      step.status = StepStatus.running;

      final task = AgentTask(
        id: '${runId}_step_${step.index}',
        instruction: step.description,
        priority: TaskPriority.normal,
        metadata: {
          'plan_id': plan.id,
          'step_index': step.index,
          'original_goal': goal,
        },
      );

      final result = await dispatcher.dispatch(task);
      taskResults.add(result);

      if (result.success) {
        step.status = StepStatus.done;
        step.output = result.output;
        // Persist step output in shared context for downstream steps.
        context.set('step_${step.index}_output', result.output);
      } else {
        step.status = StepStatus.failed;
        step.error = result.error;
        overallSuccess = false;
        _log('execute: step ${step.index} failed – ${result.error}');
        // Skip remaining steps on failure.
        for (var remaining = step.index + 1;
            remaining < plan.steps.length;
            remaining++) {
          plan.steps[remaining].status = StepStatus.skipped;
        }
        break;
      }
    }

    plan.status =
        overallSuccess ? PlanStatus.completed : PlanStatus.failed;
    plan.summary = overallSuccess
        ? 'All ${plan.steps.length} step(s) completed successfully.'
        : 'Execution halted: ${plan.steps.where((s) => s.status == StepStatus.failed).length} step(s) failed.';

    _log('execute: done runId=$runId success=$overallSuccess');

    return OrchestrationResult(
      runId: runId,
      goal: goal,
      taskResults: taskResults,
      success: overallSuccess,
      summary: plan.summary,
    );
  }

  static void _log(String message) {
    debugPrint('[$_logTag] $message');
  }
}
