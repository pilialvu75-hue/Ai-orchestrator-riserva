import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_claim_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Evolution runner stages validated candidate without real writes', () async {
    const adapter = WorkshopLibraryEvolutionClaimAdapter();
    final task = adapter.fromJson(_claim());
    final gateway = _RecordingGateway();
    final engineer = _QueueGateway(AppAiRole.engineer, <String>[
      '{"summary":"candidate","explanation":"bounded",'
      '"changes":[{"path":"candidate_workspace/module.md","type":"addition",'
      '"content":"candidate"}],"validationNotes":[],"warnings":[]}'
    ]);
    final reviewer = _QueueGateway(AppAiRole.reviewer, <String>[
      '{"approved":true,"summary":"ok","findings":[],"warnings":[]}',
      '{"valid":true,"summary":"ok","checks":["bounded"],"warnings":[]}'
    ]);
    final idle = _QueueGateway(AppAiRole.workshopOrchestrator, <String>['{}']);
    final architect = _QueueGateway(AppAiRole.architect, <String>['{}']);
    final inference = WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(gateways: {
          AppAiRole.workshopOrchestrator: idle,
          AppAiRole.architect: architect,
          AppAiRole.engineer: engineer,
          AppAiRole.reviewer: reviewer,
        }),
      ),
    );
    final runner = WorkshopLibraryEvolutionInferenceRunner(
      pipeline: WorkshopTaskInferencePipeline(inference: inference),
    );

    final result = await runner.run(task: task, gateway: gateway, isOffline: true);

    expect(result.readyForApproval, isTrue);
    expect(result.proposal.affectedPaths, <String>['candidate_workspace/module.md']);
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
    expect(gateway.commitCalls, 0);
    expect(gateway.pushCalls, 0);
    expect(gateway.prCalls, 0);
  });
  test('Evolution runner blocks proposal outside candidate workspace', () async {
    const adapter = WorkshopLibraryEvolutionClaimAdapter();
    final task = adapter.fromJson(_claim());
    final gateway = _RecordingGateway();
    final engineer = _QueueGateway(AppAiRole.engineer, <String>[
      '{"summary":"escape","explanation":"unsafe",'
      '"changes":[{"path":"stable_library/module.md","type":"addition",'
      '"content":"unsafe"}],"validationNotes":[],"warnings":[]}'
    ]);
    final reviewer = _QueueGateway(AppAiRole.reviewer, <String>[
      '{"approved":true,"summary":"ok","findings":[],"warnings":[]}',
      '{"valid":true,"summary":"ok","checks":["bounded"],"warnings":[]}'
    ]);
    final inference = WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(gateways: {
          AppAiRole.workshopOrchestrator:
              _QueueGateway(AppAiRole.workshopOrchestrator, <String>['{}']),
          AppAiRole.architect:
              _QueueGateway(AppAiRole.architect, <String>['{}']),
          AppAiRole.engineer: engineer,
          AppAiRole.reviewer: reviewer,
        }),
      ),
    );
    final runner = WorkshopLibraryEvolutionInferenceRunner(
      pipeline: WorkshopTaskInferencePipeline(inference: inference),
    );

    await expectLater(
      runner.run(task: task, gateway: gateway, isOffline: true),
      throwsA(isA<StateError>()),
    );
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
    expect(gateway.commitCalls, 0);
    expect(gateway.pushCalls, 0);
    expect(gateway.prCalls, 0);
  });

}

Map<String, dynamic> _claim() => <String, dynamic>{
  'schema':'ai-orchestrator.evolution-cantiere-claim.v1',
  'source':'library_evolution_queue',
  'work_id':'evo-a18f2c13c19927904ced0bbd',
  'proposal_id':'46d3210c343113b4c5831284dcc3f1ff78add85561f6a06c636bcd1883a1553d',
  'capability_id':'ai.acceleration_backend',
  'objective':'Evaluate and implement only the useful capability delta.',
  'knowledge_delta':<String>['practice:readme_present'],
  'acceptance_gates':<String>['implementation_tests_pass','security_gates_pass','regression_tests_pass','library_contract_pass'],
  'mutation_policy':'isolated_candidate_no_library_mutation',
  'required_output':<String,dynamic>{'type':'library_intake_bundle','status':'discovered','path_scope':'intake/<asset>/<version>'},
};

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway(this.role, List<String> values)
      : _values = List<String>.from(values), super(provider: _NoopProvider());
  final AppAiRole role;
  final List<String> _values;
  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt, String? systemPrompt, List<ChatTurn> context=const [],
    String sessionId='workshop', bool isOffline=true, int? maxTokens,
    double? temperature, double topP=.9, double repeatPenalty=1.1,
    String? modelId, String? modelPath, CancellationToken? cancellationToken,
  }) async => WorkshopInferenceResult(
    text: _values.removeAt(0), terminalState: InferenceTerminalState.success);
}
final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({required InferenceRequest request, required CancellationToken cancellationToken}) => const Stream.empty();
}
final class _RecordingGateway implements GitWorkspaceGateway {
  int writeCalls=0,deleteCalls=0,commitCalls=0,pushCalls=0,prCalls=0;
  @override Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(repository:'evolution-test',branch:'isolated');
  @override Future<String?> readFile(String path) async => null;
  @override Future<bool> fileExists(String path) async => false;
  @override Future<List<String>> listFiles({String? directory}) async => const [];
  @override Future<void> createBranch(String branchName) async {}
  @override Future<void> writeFile({required String path,required String content}) async {writeCalls++;}
  @override Future<void> deleteFile(String path) async {deleteCalls++;}
  @override Future<GitWorkspaceDiff> getDiff() async => const GitWorkspaceDiff(files:[]);
  @override Future<String> commit(String message) async {commitCalls++;return 'x';}
  @override Future<void> push() async {pushCalls++;}
  @override Future<String> createPullRequest({required String title,required String body,required String headBranch,required String baseBranch}) async {prCalls++;return 'x';}
}
