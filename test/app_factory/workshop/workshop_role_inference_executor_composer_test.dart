import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopRoleInferenceExecutorComposer', () {
    test('composes exactly one gateway for each Workshop role', () {
      final requestedRoles = <AppAiRole>[];

      final executor = WorkshopRoleInferenceExecutorComposer.compose(
        gatewayFactory: (role) {
          requestedRoles.add(role);
          return _RecordingGateway(role);
        },
      );

      expect(
        requestedRoles.toSet(),
        WorkshopRoleInferenceRouter.workshopRoles,
      );
      expect(
        executor.roles,
        WorkshopRoleInferenceRouter.workshopRoles,
      );
      expect(
        executor.roles,
        isNot(contains(AppAiRole.assistantOrchestrator)),
      );
    });

    test('routes completed inference through the composed role gateway',
        () async {
      final gateways = <AppAiRole, _RecordingGateway>{};

      final executor = WorkshopRoleInferenceExecutorComposer.compose(
        gatewayFactory: (role) {
          final gateway = _RecordingGateway(role);
          gateways[role] = gateway;
          return gateway;
        },
      );

      final result = await executor.complete(
        role: AppAiRole.engineer,
        prompt: 'implement task',
        sessionId: 'workshop:engineer:test',
      );

      expect(result.text, AppAiRole.engineer.id);
      expect(gateways[AppAiRole.engineer]!.calls, 1);
      expect(gateways[AppAiRole.engineer]!.lastPrompt, 'implement task');
      expect(gateways[AppAiRole.architect]!.calls, 0);
      expect(gateways[AppAiRole.reviewer]!.calls, 0);
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
    });
  });
}

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway(this.role) : super(provider: _NoopProvider());

  final AppAiRole role;
  int calls = 0;
  String? lastPrompt;

  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    calls += 1;
    lastPrompt = prompt;
    return WorkshopInferenceResult(text: role.id);
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}
