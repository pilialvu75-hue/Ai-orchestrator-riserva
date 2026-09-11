import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strong verified reuse skips Orchestrator and keeps Architect gate', () async {
    final calls = <AppAiRole>[];
    final orchestrator = _RecordingGateway(
      role: AppAiRole.workshopOrchestrator,
      callOrder: calls,
      result: _success('must not run'),
    );
    final architect = _RecordingGateway(
      role: AppAiRole.architect,
      callOrder: calls,
      result: _success('adapt verified invoice foundation'),
    );
    final library = WorkshopReuseLibrary(
      initialAssets: <WorkshopReusableAsset>[
        WorkshopReusableAsset(
          id: 'invoice-template',
          name: 'Invoice billing application',
          kind: WorkshopReusableAssetKind.projectTemplate,
          origin: WorkshopReusableAssetOrigin.completedProject,
          description:
              'Invoice billing application for customers and invoices',
          tags: const <String>['invoice', 'billing', 'customers'],
          capabilities: const <String>['customers', 'invoices'],
          entryPaths: const <String>['lib/main.dart'],
          target: 'android',
          artifactPath: 'build/app.apk',
          validationScore: 0.99,
          reuseCount: 2,
        ),
      ],
    );

    final pipeline = WorkshopPreflightInferencePipeline(
      inference: _stageInference(
        orchestrator: orchestrator,
        architect: architect,
        calls: calls,
      ),
      reuseLibrary: library,
    );

    final result = await pipeline.run(
      request: const WorkshopRequest(
        id: 'invoice-new',
        title: 'Invoice billing application',
        instruction: 'Create invoice billing application for customers.',
      ),
      requiredCapabilities: const <String>['customers', 'invoices'],
      target: 'android',
    );

    expect(result.readyForImplementation, isTrue);
    expect(result.reusedLocalKnowledge, isTrue);
    expect(result.reusedAsset?.id, 'invoice-template');
    expect(result.analysis.model, 'workshop-reuse-library');
    expect(orchestrator.calls, 0);
    expect(architect.calls, 1);
    expect(calls, <AppAiRole>[AppAiRole.architect]);
    expect(architect.lastPrompt, contains('invoice-template'));
    expect(architect.lastPrompt, contains('smallest safe implementation plan'));
    expect(library.findById('invoice-template')?.reuseCount, 3);
  });

  test('weak local candidate preserves normal two-call preflight', () async {
    final calls = <AppAiRole>[];
    final orchestrator = _RecordingGateway(
      role: AppAiRole.workshopOrchestrator,
      callOrder: calls,
      result: _success('fresh analysis'),
    );
    final architect = _RecordingGateway(
      role: AppAiRole.architect,
      callOrder: calls,
      result: _success('fresh plan'),
    );
    final library = WorkshopReuseLibrary(
      initialAssets: <WorkshopReusableAsset>[
        WorkshopReusableAsset(
          id: 'weather-template',
          name: 'Weather dashboard',
          kind: WorkshopReusableAssetKind.projectTemplate,
          origin: WorkshopReusableAssetOrigin.completedProject,
          description: 'Weather forecast application',
          capabilities: const <String>['forecast'],
          validationScore: 1,
        ),
      ],
    );

    final result = await WorkshopPreflightInferencePipeline(
      inference: _stageInference(
        orchestrator: orchestrator,
        architect: architect,
        calls: calls,
      ),
      reuseLibrary: library,
    ).run(
      request: const WorkshopRequest(
        id: 'invoice-fresh',
        title: 'Invoice application',
        instruction: 'Create customer invoices and billing.',
      ),
      requiredCapabilities: const <String>['customers', 'invoices'],
    );

    expect(result.readyForImplementation, isTrue);
    expect(result.reusedLocalKnowledge, isFalse);
    expect(orchestrator.calls, 1);
    expect(architect.calls, 1);
    expect(
      calls,
      <AppAiRole>[
        AppAiRole.workshopOrchestrator,
        AppAiRole.architect,
      ],
    );
  });
}

WorkshopStageRoleInference _stageInference({
  required _RecordingGateway orchestrator,
  required _RecordingGateway architect,
  required List<AppAiRole> calls,
}) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(
        gateways: <AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _RecordingGateway(
            role: AppAiRole.engineer,
            callOrder: calls,
            result: _success('unused'),
          ),
          AppAiRole.reviewer: _RecordingGateway(
            role: AppAiRole.reviewer,
            callOrder: calls,
            result: _success('unused'),
          ),
        },
      ),
    ),
  );
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway({
    required this.role,
    required this.callOrder,
    required this.result,
  }) : super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> callOrder;
  final WorkshopInferenceResult result;
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
    callOrder.add(role);
    lastPrompt = prompt;
    return result;
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream<InferenceResponse>.empty();
  }
}
