import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Executes Workshop inference through the gateway assigned to a logical role.
///
/// This is the role-aware execution boundary consumed by higher Workshop
/// orchestration layers. It does not create a runtime, model store, downloader,
/// memory subsystem or Assistant dependency. Those concerns stay below the
/// existing Workshop gateways.
final class WorkshopRoleInferenceExecutor {
  const WorkshopRoleInferenceExecutor({
    required WorkshopRoleInferenceRouter router,
  }) : _router = router;

  final WorkshopRoleInferenceRouter _router;

  Set<AppAiRole> get roles => _router.roles;

  WorkshopInferenceGateway gatewayFor(AppAiRole role) =>
      _router.gatewayFor(role);

  Future<WorkshopInferenceResult> complete({
    required AppAiRole role,
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
    final gateway = _router.gatewayFor(role);

    return gateway.complete(
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
