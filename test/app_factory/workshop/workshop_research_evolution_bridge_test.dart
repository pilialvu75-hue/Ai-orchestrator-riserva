import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_multi_role_pipeline_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_approval_controller.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_research_evolution_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

void main() {
  test('maps Researcher delta to isolated agent-ready Cantiere task', () {
    const adapter = WorkshopResearchEvolutionTaskAdapter();
    final task = adapter.toTask(
      const WorkshopResearchEvolutionRequest(
        proposalId: 'p-42',
        capabilityId: 'network.http',
        knowledgeDelta: <String>['topic:retry', 'topic:backoff'],
        acceptanceGates: <String>[
          'implementation_tests_pass',
          'security_gates_pass',
        ],
        mutationPolicy: 'isolated_candidate_no_library_mutation',
      ),
    );

    expect(task.id, 'research-evolution:p-42');
    expect(task.kind, WorkshopTaskKind.codeModification);
    expect(task.fileScope.allowed, contains('candidate_workspace/**'));
    expect(task.fileScope.forbidden, contains('stable_library/**'));
    expect(task.metadata['researcherProposalId'], 'p-42');
    expect(task.metadata['sourceCodeTransferred'], isFalse);
    expect(task.acceptanceCriteria, hasLength(2));
    expect(task.requiredCheckpoints, contains('validation_completed'));
    expect(task.isAgentReady, isTrue);
  });

  test('rejects a request that could mutate the stable Library', () {
    const adapter = WorkshopResearchEvolutionTaskAdapter();
    expect(
      () => adapter.toTask(
        const WorkshopResearchEvolutionRequest(
          proposalId: 'p-unsafe',
          capabilityId: 'voice.stt',
          knowledgeDelta: <String>['topic:streaming'],
          acceptanceGates: <String>['regression_tests_pass'],
          mutationPolicy: 'direct_library_mutation',
        ),
      ),
      throwsFormatException,
    );
  });


  test('Researcher task maps to one isolated Cantiere project task', () {
    const request = WorkshopResearchEvolutionRequest(
      proposalId: 'proposal-42',
      capabilityId: 'ai.model_storage',
      knowledgeDelta: <String>['practice:tests_present'],
      acceptanceGates: <String>['tests', 'license'],
      mutationPolicy: 'isolated_candidate_no_library_mutation',
    );
    final task = const WorkshopResearchEvolutionTaskAdapter().toTask(request);
    final plan = const WorkshopResearchEvolutionProjectAdapter().toProject(task);

    expect(plan.tasks, hasLength(1));
    expect(plan.tasks.single.id, task.id);
    expect(plan.tasks.single.affectedPaths, <String>['candidate_workspace/**']);
    expect(plan.validationCriteria, hasLength(2));
    expect(plan.constraints, contains('Never mutate the stable Library during implementation.'));
    expect(plan.status, WorkshopProjectStatus.planned);
  });

  test('Researcher project adapter rejects a contract without isolation evidence', () {
    final unsafe = WorkshopTaskContract(
      id: 'research-evolution:unsafe',
      title: 'Unsafe',
      objective: 'Unsafe task',
      kind: WorkshopTaskKind.codeModification,
      mode: WorkshopTaskMode.hybrid,
      preferredResource: WorkshopTaskResource.local,
      acceptanceCriteria: const <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(id: 'tests', description: 'tests'),
      ],
      fileScope: const WorkshopTaskFileScope(allowed: <String>['candidate_workspace/**']),
      tags: const <String>['researcher-v2'],
      metadata: const <String, dynamic>{
        'mutationPolicy': 'isolated_candidate_no_library_mutation',
        'sourceCodeTransferred': false,
      },
    );

    expect(
      () => const WorkshopResearchEvolutionProjectAdapter().toProject(unsafe),
      throwsFormatException,
    );
  });

  test('Researcher intake prepares the authoritative session without mutation', () async {
    final gateway = _ResearchIntakeGateway();
    final executor = WorkshopProjectExecutor(gateway: gateway);
    final engine = WorkshopEngine(projectExecutor: executor);
    final task = const WorkshopResearchEvolutionTaskAdapter().toTask(
      const WorkshopResearchEvolutionRequest(
        proposalId: 'proposal-session', capabilityId: 'network.http',
        knowledgeDelta: <String>['practice:retry_backoff'],
        acceptanceGates: <String>['tests', 'security'],
        mutationPolicy: 'isolated_candidate_no_library_mutation',
      ),
    );

    final session = await WorkshopResearchEvolutionSessionIntake(engine: engine).prepare(task);

    expect(session.status, WorkspaceSessionStatus.ready);
    expect(session.context.request.targetFiles, <String>['candidate_workspace/**']);
    expect(session.context.request.constraints, contains('Never mutate the stable Library during implementation.'));
    expect(session.context.request.constraints, contains('Researcher read-only scope: library_baseline/** | research_knowledge/**'));
    expect(session.context.request.constraints, contains('Researcher forbidden scope: stable_library/**'));
    expect(identical(executor.sessionForTask(task.id), session), isTrue);
    expect(session.hasChanges, isFalse);
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
  });
  test('Researcher validation runs Engineer and Reviewer without applying', () async {
    final gateway = _ResearchIntakeGateway();
    final executor = WorkshopProjectExecutor(gateway: gateway);
    final engine = WorkshopEngine(projectExecutor: executor);
    final calls = <AppAiRole>[];
    final lifecycle = WorkshopPreparedTaskLifecycle(
      inferenceRunner: WorkshopMultiRolePipelineFactory.createPreparedTaskRunner(
        executor: executor,
        gateways: _researchGateways(calls),
      ),
      approvalController: WorkshopTaskApprovalController(executor: executor),
    );
    final task = const WorkshopResearchEvolutionTaskAdapter().toTask(
      const WorkshopResearchEvolutionRequest(
        proposalId: 'proposal-validation', capabilityId: 'network.http',
        knowledgeDelta: <String>['practice:retry_backoff'],
        acceptanceGates: <String>['tests', 'security'],
        mutationPolicy: 'isolated_candidate_no_library_mutation',
      ),
    );

    final result = await WorkshopResearchEvolutionValidationRunner(
      intake: WorkshopResearchEvolutionSessionIntake(engine: engine),
      lifecycle: lifecycle,
    ).prepareAndValidate(task: task);

    expect(result.readyForApproval, isTrue);
    expect(calls, <AppAiRole>[
      AppAiRole.engineer, AppAiRole.reviewer, AppAiRole.reviewer,
    ]);
    final session = executor.sessionForTask(task.id)!;
    expect(session.status, WorkspaceSessionStatus.validation);
    expect(session.isApplyApproved, isFalse);
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
  });

}

const _researchProposal = '{"summary":"Candidate","explanation":"Improve candidate",'
    '"changes":[{"path":"candidate_workspace/module.dart","type":"creation",'
    '"content":"candidate"}],"validationNotes":[],"warnings":[]}';
const _researchReview = '{"approved":true,"summary":"Review passed",'
    '"findings":[],"warnings":[]}';
const _researchValidation = '{"valid":true,"summary":"Validation passed",'
    '"checks":["tests","security"],"warnings":[]}';

Map<AppAiRole, WorkshopInferenceGateway> _researchGateways(List<AppAiRole> calls) =>
    <AppAiRole, WorkshopInferenceGateway>{
      AppAiRole.engineer: _ResearchQueueGateway(AppAiRole.engineer, calls, <String>[_researchProposal]),
      AppAiRole.reviewer: _ResearchQueueGateway(AppAiRole.reviewer, calls, <String>[_researchReview, _researchValidation]),
    };

final class _ResearchQueueGateway extends WorkshopInferenceGateway {
  _ResearchQueueGateway(this.role, this.calls, List<String> values)
      : _values = List<String>.from(values), super(provider: _ResearchNoopProvider());
  final AppAiRole role;
  final List<AppAiRole> calls;
  final List<String> _values;
  @override
  Future<WorkshopInferenceResult> complete({required String prompt, String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[], String sessionId = 'workshop',
    bool isOffline = true, int? maxTokens, double? temperature, double topP = 0.9,
    double repeatPenalty = 1.1, String? modelId, String? modelPath,
    CancellationToken? cancellationToken}) async {
    calls.add(role);
    return WorkshopInferenceResult(text: _values.removeAt(0), terminalState: InferenceTerminalState.success);
  }
}
final class _ResearchNoopProvider implements RuntimeInferenceProvider {
  @override TokenStream streamInference({required InferenceRequest request,
    required CancellationToken cancellationToken}) => const Stream.empty();
}

final class _ResearchIntakeGateway implements GitWorkspaceGateway {
  int writeCalls = 0;
  int deleteCalls = 0;
  @override Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(repository: 'research/test', branch: 'main');
  @override Future<String?> readFile(String path) async => null;
  @override Future<bool> fileExists(String path) async => false;
  @override Future<List<String>> listFiles({String? directory}) async => const <String>[];
  @override Future<void> createBranch(String branchName) async {}
  @override Future<void> writeFile({required String path, required String content}) async { writeCalls++; }
  @override Future<void> deleteFile(String path) async { deleteCalls++; }
  @override Future<GitWorkspaceDiff> getDiff() async => const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);
  @override Future<String> commit(String message) async => 'unused';
  @override Future<void> push() async {}
  @override Future<String> createPullRequest({required String title, required String body, required String headBranch, required String baseBranch}) async => 'unused';
}
