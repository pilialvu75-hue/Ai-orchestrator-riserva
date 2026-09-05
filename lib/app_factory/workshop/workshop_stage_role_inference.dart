import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Resolves Workshop lifecycle stages to the logical brain responsible for
/// producing inference for that phase.
///
/// This belongs to the Workshop orchestration layer. It does not create a
/// runtime, downloader, storage or Assistant dependency.
final class WorkshopStageRoleResolver {
  const WorkshopStageRoleResolver._();

  static AppAiRole roleFor(WorkshopStage stage) {
    switch (stage) {
      case WorkshopStage.requested:
      case WorkshopStage.analysis:
        return AppAiRole.workshopOrchestrator;
      case WorkshopStage.planning:
        return AppAiRole.architect;
      case WorkshopStage.implementation:
        return AppAiRole.engineer;
      case WorkshopStage.review:
      case WorkshopStage.validation:
        return AppAiRole.reviewer;
      case WorkshopStage.completed:
      case WorkshopStage.blocked:
      case WorkshopStage.cancelled:
        throw StateError(
          'Workshop stage ${stage.name} cannot start inference.',
        );
    }
  }
}

/// Executes one Workshop stage through the gateway assigned to that stage's
/// role.
///
/// Calls are deliberately single-shot and awaitable. Higher orchestration
/// layers can therefore run the local brains sequentially on constrained
/// devices instead of keeping multiple local models active concurrently.
final class WorkshopStageRoleInference {
  const WorkshopStageRoleInference({
    required WorkshopRoleInferenceExecutor executor,
  }) : _executor = executor;

  final WorkshopRoleInferenceExecutor _executor;

  Future<WorkshopInferenceResult> complete({
    required WorkshopStage stage,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    CancellationToken? cancellationToken,
  }) {
    final role = WorkshopStageRoleResolver.roleFor(stage);

    if (role == AppAiRole.assistantOrchestrator) {
      throw StateError(
        'Assistant role cannot be used by Workshop stage inference.',
      );
    }

    return _executor.complete(
      role: role,
      prompt: prompt,
      systemPrompt: systemPrompt,
      context: context,
      sessionId: sessionId,
      isOffline: isOffline,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      repeatPenalty: repeatPenalty,
      cancellationToken: cancellationToken,
    );
  }
}
