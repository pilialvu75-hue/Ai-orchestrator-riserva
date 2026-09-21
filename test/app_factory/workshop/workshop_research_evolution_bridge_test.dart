import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
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
    expect(session.context.request.context, contains('Forbidden scope: stable_library/**'));
    expect(identical(executor.sessionForTask(task.id), session), isTrue);
    expect(session.hasChanges, isFalse);
    expect(gateway.writeCalls, 0);
    expect(gateway.deleteCalls, 0);
  });
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
