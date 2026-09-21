import 'workshop_task_contract.dart';

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
