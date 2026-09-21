import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_prepared_task_lifecycle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

final class WorkshopResearchEvolutionRequest {
  const WorkshopResearchEvolutionRequest({
    required this.proposalId,
    required this.capabilityId,
    required this.knowledgeDelta,
    required this.acceptanceGates,
    required this.mutationPolicy,
  });

  final String proposalId;
  final String capabilityId;
  final List<String> knowledgeDelta;
  final List<String> acceptanceGates;
  final String mutationPolicy;

  factory WorkshopResearchEvolutionRequest.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) {
      final value = json[key];
      if (value is! List) return const <String>[];
      return List.unmodifiable(value.map((item) => item.toString()).where((item) => item.isNotEmpty));
    }
    return WorkshopResearchEvolutionRequest(
      proposalId: json['proposal_id']?.toString() ?? '',
      capabilityId: json['capability_id']?.toString() ?? '',
      knowledgeDelta: strings('knowledge_delta'),
      acceptanceGates: strings('acceptance_gates'),
      mutationPolicy: json['mutation_policy']?.toString() ?? '',
    );
  }

  void validate() {
    if (proposalId.trim().isEmpty || capabilityId.trim().isEmpty) {
      throw const FormatException('Research evolution request requires proposal and capability identity.');
    }
    if (knowledgeDelta.isEmpty || acceptanceGates.isEmpty) {
      throw const FormatException('Research evolution request requires knowledge delta and acceptance gates.');
    }
    if (mutationPolicy != 'isolated_candidate_no_library_mutation') {
      throw const FormatException('Research evolution request must use isolated candidate mutation policy.');
    }
  }
}

final class WorkshopResearchEvolutionTaskAdapter {
  const WorkshopResearchEvolutionTaskAdapter();

  WorkshopTaskContract toTask(WorkshopResearchEvolutionRequest request) {
    request.validate();
    return WorkshopTaskContract(
      id: 'research-evolution:${request.proposalId}',
      title: 'Evolve ${request.capabilityId}',
      objective: 'Create or improve our independently maintained module for ${request.capabilityId} using only the normalized Researcher knowledge delta. Produce an isolated candidate; do not mutate the stable Library.',
      kind: WorkshopTaskKind.codeModification,
      mode: WorkshopTaskMode.hybrid,
      preferredResource: WorkshopTaskResource.local,
      fallbackResources: const <WorkshopTaskResource>[
        WorkshopTaskResource.githubAgent,
        WorkshopTaskResource.githubActions,
        WorkshopTaskResource.hybridAi,
      ],
      instructions: <String>[
        'Use the current in-house module as the baseline when one exists.',
        'Apply only technically useful knowledge deltas.',
        'Prefer the best correct implementation; do not introduce artificial differences.',
        'Do not copy research-only upstream source code.',
        'Create a candidate version in an isolated workspace.',
        'Run the required validation gates before requesting promotion.',
        ...request.knowledgeDelta.map((delta) => 'Knowledge delta: $delta'),
      ],
      constraints: const <String>[
        'Never mutate the stable Library during implementation.',
        'Never bypass license, security, regression, or Library contract gates.',
        'Never execute untrusted discovered source code as part of synthesis.',
      ],
      acceptanceCriteria: request.acceptanceGates.map((gate) => WorkshopTaskAcceptanceCriterion(id: gate, description: 'Researcher gate $gate must pass.')).toList(growable: false),
      fileScope: const WorkshopTaskFileScope(
        allowed: <String>['candidate_workspace/**'],
        readOnly: <String>['library_baseline/**', 'research_knowledge/**'],
        forbidden: <String>['stable_library/**'],
      ),
      requiredCheckpoints: const <String>['candidate_created', 'tests_completed', 'validation_completed'],
      tags: <String>['researcher-v2', 'module-evolution', request.capabilityId],
      metadata: <String, dynamic>{
        'researcherProposalId': request.proposalId,
        'capabilityId': request.capabilityId,
        'mutationPolicy': request.mutationPolicy,
        'sourceCodeTransferred': false,
      },
    );
  }
}


/// Deterministic bridge from a validated Researcher task contract to the
/// authoritative Cantiere project model. It does not run inference, approve,
/// apply, or mutate the stable Library.
final class WorkshopResearchEvolutionProjectAdapter {
  const WorkshopResearchEvolutionProjectAdapter();

  WorkshopProjectPlan toProject(WorkshopTaskContract task) {
    _validate(task);
    const phaseId = 'phase:research-evolution';
    final criteria = task.acceptanceCriteria
        .map((item) => item.description.trim().isEmpty ? item.id : item.description.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final description = <String>[
      task.objective.trim(),
      ...task.instructions.map((item) => item.trim()).where((item) => item.isNotEmpty),
    ].join('\n');

    return WorkshopProjectPlan(
      id: 'project:${task.id}',
      title: task.title,
      goal: task.objective,
      domain: WorkshopProjectDomain.software,
      status: WorkshopProjectStatus.planned,
      requirements: task.instructions,
      constraints: task.constraints,
      deliverables: const <String>['isolated candidate workspace'],
      validationCriteria: criteria,
      phases: <WorkshopProjectPhase>[
        WorkshopProjectPhase(
          id: phaseId,
          title: 'Research evolution',
          description: 'Implement and validate one isolated Researcher evolution candidate.',
          taskIds: <String>[task.id],
          validationCriteria: criteria,
        ),
      ],
      tasks: <WorkshopProjectTask>[
        WorkshopProjectTask(
          id: task.id,
          title: task.title,
          description: description,
          phaseId: phaseId,
          affectedPaths: task.fileScope.allowed,
          validationCriteria: criteria,
        ),
      ],
    );
  }

  void _validate(WorkshopTaskContract task) {
    if (!task.tags.contains('researcher-v2') ||
        task.metadata['mutationPolicy'] != 'isolated_candidate_no_library_mutation' ||
        task.metadata['sourceCodeTransferred'] != false) {
      throw const FormatException('Unsafe Researcher evolution task contract.');
    }
    if (task.fileScope.allowed.isEmpty ||
        !task.fileScope.forbidden.contains('stable_library/**')) {
      throw const FormatException('Researcher evolution task must isolate writable scope from the stable Library.');
    }
    if (task.acceptanceCriteria.isEmpty) {
      throw const FormatException('Researcher evolution task requires validation criteria.');
    }
  }
}


/// Registers a validated Researcher contract in the authoritative Cantiere
/// engine and prepares the exact task through WorkshopProjectExecutor.
/// This stops at WorkspaceSession preparation: it never approves or applies.
final class WorkshopResearchEvolutionSessionIntake {
  const WorkshopResearchEvolutionSessionIntake({
    required WorkshopEngine engine,
    this.projectAdapter = const WorkshopResearchEvolutionProjectAdapter(),
  }) : _engine = engine;

  final WorkshopEngine _engine;
  final WorkshopResearchEvolutionProjectAdapter projectAdapter;

  Future<WorkspaceSession> prepare(WorkshopTaskContract task) async {
    final mapped = projectAdapter.toProject(task);
    final requestId = 'research-intake:${task.id}';
    final request = WorkshopRequest(
      id: requestId,
      title: mapped.title,
      instruction: mapped.goal,
      source: WorkshopRequestSource.workshop,
      operation: WorkshopOperation.modify,
      targetFiles: task.fileScope.allowed,
      constraints: mapped.constraints,
      context: <String>[
        'Researcher proposal: ${task.metadata['researcherProposalId']}',
        'Capability: ${task.metadata['capabilityId']}',
        'Mutation policy: ${task.metadata['mutationPolicy']}',
        'Read-only scope: ${task.fileScope.readOnly.join(' | ')}',
        'Forbidden scope: ${task.fileScope.forbidden.join(' | ')}',
      ],
    );

    final registered = _engine.createProjectPlan(
      request,
      domain: mapped.domain,
      phases: mapped.phases,
      tasks: mapped.tasks,
      requirements: mapped.requirements,
      constraints: <String>[
        ...mapped.constraints,
        'Researcher read-only scope: ${task.fileScope.readOnly.join(' | ')}',
        'Researcher forbidden scope: ${task.fileScope.forbidden.join(' | ')}',
      ],
      technologies: mapped.technologies,
      hardware: mapped.hardware,
      deliverables: mapped.deliverables,
      validationCriteria: mapped.validationCriteria,
    );
    if (registered.tasks.length != 1 || registered.tasks.single.id != task.id) {
      throw StateError('Research evolution intake must register exactly one authoritative task.');
    }
    return _engine.prepareProjectTask(requestId, task.id);
  }
}


/// Runs one validated Researcher evolution contract through the existing
/// productive Cantiere inference lifecycle. Preparation remains authoritative
/// and successful inference stops before owner approval/apply, so this bridge
/// cannot mutate the stable Library by itself.
final class WorkshopResearchEvolutionValidationLifecycle {
  const WorkshopResearchEvolutionValidationLifecycle({
    required WorkshopResearchEvolutionSessionIntake intake,
    required WorkshopPreparedTaskLifecycle preparedLifecycle,
  })  : _intake = intake,
        _preparedLifecycle = preparedLifecycle;

  final WorkshopResearchEvolutionSessionIntake _intake;
  final WorkshopPreparedTaskLifecycle _preparedLifecycle;

  Future<WorkshopTaskInferenceResult> prepareAndValidate({
    required WorkshopTaskContract task,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final session = await _intake.prepare(task);
    if (session.taskId != task.id) {
      throw StateError(
        'Research evolution intake returned a non-authoritative task session.',
      );
    }
    return _preparedLifecycle.runPrepared(
      taskId: task.id,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );
  }
}
