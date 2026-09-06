import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference_composer.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopStageRoleInferenceComposer', () {
    test('composes every Workshop brain without Assistant fallback', () async {
      final gateways = <AppAiRole, _RecordingGateway>{};

      final stageInference = WorkshopStageRoleInferenceComposer.compose(
        gatewayFactory: (role) {
          final gateway = _RecordingGateway(role);
          gateways[role] = gateway;
          return gateway;
        },
      );

      expect(gateways.length, 4);
      expect(gateways.containsKey(AppAiRole.assistantOrchestrator), isFalse);

      final planning = await stageInference.complete(
        stage: WorkshopStage.planning,
        prompt: 'prepare architecture',
      );
      final implementation = await stageInference.complete(
        stage: WorkshopStage.implementation,
        prompt: 'implement the task',
      );
      final review = await stageInference.complete(
        stage: WorkshopStage.review,
        prompt: 'review the change',
      );

      expect(planning.text, AppAiRole.architect.id);
      expect(implementation.text, AppAiRole.engineer.id);
      expect(review.text, AppAiRole.reviewer.id);
      expect(gateways[AppAiRole.workshopOrchestrator]!.calls, 0);
      expect(gateways[AppAiRole.architect]!.calls, 1);
      expect(gateways[AppAiRole.engineer]!.calls, 1);
      expect(gateways[AppAiRole.reviewer]!.calls, 1);
    });
  });
}

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway(this.role) : super(provider: _NoopProvider());

  final AppAiRole role;
  int calls = 0;

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
