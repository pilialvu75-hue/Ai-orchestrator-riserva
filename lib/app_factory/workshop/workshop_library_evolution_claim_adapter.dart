import 'workshop_task_contract.dart';

final class WorkshopLibraryEvolutionClaimException implements Exception {
  const WorkshopLibraryEvolutionClaimException(this.code);
  final String code;

  @override
  String toString() => 'WorkshopLibraryEvolutionClaimException($code)';
}

/// Converts a claimed Module Library evolution envelope into the isolated
/// Workshop task contract already consumed by the Cantiere inference pipeline.
///
/// This adapter grants no apply authority. The candidate remains confined to
/// candidate_workspace/** and must later pass Engineer, Reviewer, validation
/// and WorkshopResearchLibraryHandoff before it can reach Library intake.
final class WorkshopLibraryEvolutionClaimAdapter {
  const WorkshopLibraryEvolutionClaimAdapter();

  static const String schema =
      'ai-orchestrator.evolution-cantiere-claim.v1';
  static const String mutationPolicy =
      'isolated_candidate_no_library_mutation';
  static const Set<String> requiredGates = <String>{
    'implementation_tests_pass',
    'security_gates_pass',
    'regression_tests_pass',
    'library_contract_pass',
  };
  static const Set<String> forbiddenExecutableFields = <String>{
    'source_code',
    'files',
    'payload',
    'patch',
    'diff',
    'commands',
  };

  WorkshopTaskContract fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema) {
      throw const WorkshopLibraryEvolutionClaimException('invalid-schema');
    }
    if (json['source'] != 'library_evolution_queue') {
      throw const WorkshopLibraryEvolutionClaimException('invalid-source');
    }
    for (final field in forbiddenExecutableFields) {
      if (json.containsKey(field)) {
        throw WorkshopLibraryEvolutionClaimException(
          'forbidden-executable-field-$field',
        );
      }
    }
    if (json['mutation_policy'] != mutationPolicy) {
      throw const WorkshopLibraryEvolutionClaimException(
        'unsafe-mutation-policy',
      );
    }

    final workId = _required(json, 'work_id');
    final proposalId = _required(json, 'proposal_id');
    final capabilityId = _required(json, 'capability_id');
    final objective = _required(json, 'objective');
    final delta = _strings(json['knowledge_delta']);
    final gates = _strings(json['acceptance_gates']);
    if (delta.isEmpty || gates.toSet().length != requiredGates.length ||
        !gates.toSet().containsAll(requiredGates)) {
      throw const WorkshopLibraryEvolutionClaimException(
        'invalid-acceptance-gates',
      );
    }
    final requiredOutput = json['required_output'];
    if (requiredOutput is! Map ||
        requiredOutput['type'] != 'library_intake_bundle' ||
        requiredOutput['status'] != 'discovered' ||
        requiredOutput['path_scope'] != 'intake/<asset>/<version>' ||
        requiredOutput.length != 3) {
      throw const WorkshopLibraryEvolutionClaimException(
        'invalid-required-output',
      );
    }
    if (delta.isEmpty) {
      throw const WorkshopLibraryEvolutionClaimException(
        'incomplete-evolution-claim',
      );
    }

    return WorkshopTaskContract(
      id: 'library-evolution:$workId',
      title: 'Evolve Library capability $capabilityId',
      objective: objective,
      kind: WorkshopTaskKind.codeModification,
      mode: WorkshopTaskMode.hybrid,
      preferredResource: WorkshopTaskResource.local,
      fallbackResources: const <WorkshopTaskResource>[
        WorkshopTaskResource.hybridAi,
        WorkshopTaskResource.githubActions,
      ],
      instructions: <String>[
        'Evaluate the supplied knowledge delta and implement only useful changes.',
        ...delta.map((item) => 'Consider evolution evidence: $item'),
        'Write candidate changes only under candidate_workspace/**.',
        'Return the validated candidate through the Library intake handoff.',
      ],
      constraints: const <String>[
        'Never mutate stable_library/**.',
        'Do not treat Researcher evidence as executable source code.',
        'Preserve existing behavior unless validation justifies a change.',
      ],
      acceptanceCriteria: gates
          .map(
            (gate) => WorkshopTaskAcceptanceCriterion(
              id: gate,
              description: 'Evolution acceptance gate: $gate',
            ),
          )
          .toList(growable: false),
      fileScope: const WorkshopTaskFileScope(
        allowed: <String>['candidate_workspace/**'],
        forbidden: <String>['stable_library/**'],
      ),
      requiredCheckpoints: const <String>[
        'engineer-complete',
        'review-complete',
        'validation-complete',
      ],
      tags: const <String>['researcher-v2', 'module-evolution'],
      metadata: <String, dynamic>{
        'libraryWorkId': workId,
        'proposalId': proposalId,
        'capabilityId': capabilityId,
        'mutationPolicy': mutationPolicy,
        'sourceCodeTransferred': false,
        'claimSource': 'library_evolution_queue',
      },
    );
  }

  String _required(Map<String, dynamic> json, String key) {
    final value = json[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw WorkshopLibraryEvolutionClaimException('missing-$key');
    }
    return value;
  }

  List<String> _strings(dynamic value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}
