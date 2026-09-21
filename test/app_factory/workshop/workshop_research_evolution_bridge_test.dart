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

}
