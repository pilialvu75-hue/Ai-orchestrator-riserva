import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

/// Evidence produced after the isolated Researcher candidate has completed
/// implementation and validation. This gate never applies or promotes code.
final class WorkshopResearchEvolutionEvidence {
  const WorkshopResearchEvolutionEvidence({
    required this.reviewerApproved,
    required this.validationPassed,
    required this.testsPassed,
    required this.regressionsPassed,
    required this.securityPassed,
    required this.provenancePassed,
    required this.licensePassed,
    required this.passedAcceptanceGates,
  });

  final bool reviewerApproved;
  final bool validationPassed;
  final bool testsPassed;
  final bool regressionsPassed;
  final bool securityPassed;
  final bool provenancePassed;
  final bool licensePassed;
  final Set<String> passedAcceptanceGates;
}

final class WorkshopResearchEvolutionPolicyDecision {
  const WorkshopResearchEvolutionPolicyDecision._({
    required this.approved,
    required this.reasons,
  });

  final bool approved;
  final List<String> reasons;

  factory WorkshopResearchEvolutionPolicyDecision.approved() =>
      const WorkshopResearchEvolutionPolicyDecision._(
        approved: true,
        reasons: <String>[],
      );

  factory WorkshopResearchEvolutionPolicyDecision.rejected(
    List<String> reasons,
  ) => WorkshopResearchEvolutionPolicyDecision._(
        approved: false,
        reasons: List<String>.unmodifiable(reasons),
      );
}

/// Machine-policy boundary for autonomous Researcher evolution.
///
/// This is deliberately separate from owner approval. Passing this policy
/// only means the isolated candidate is eligible for the later controlled
/// promotion path; it never calls WorkshopPreparedTaskLifecycle.decide(),
/// applies workspace changes, or mutates the stable Library.
final class WorkshopResearchEvolutionPolicyGate {
  const WorkshopResearchEvolutionPolicyGate();

  WorkshopResearchEvolutionPolicyDecision evaluate({
    required WorkshopTaskContract task,
    required WorkshopResearchEvolutionEvidence evidence,
  }) {
    final failures = <String>[];

    if (!task.tags.contains('researcher-v2') ||
        !task.tags.contains('module-evolution')) {
      failures.add('researcher_identity');
    }
    if (task.metadata['mutationPolicy'] !=
            'isolated_candidate_no_library_mutation' ||
        task.metadata['sourceCodeTransferred'] != false ||
        task.fileScope.allowed.length != 1 ||
        task.fileScope.allowed.single != 'candidate_workspace/**' ||
        !task.fileScope.readOnly.contains('library_baseline/**') ||
        !task.fileScope.readOnly.contains('research_knowledge/**') ||
        !task.fileScope.forbidden.contains('stable_library/**')) {
      failures.add('isolation');
    }
    if (!evidence.reviewerApproved) failures.add('review');
    if (!evidence.validationPassed) failures.add('validation');
    if (!evidence.testsPassed) failures.add('tests');
    if (!evidence.regressionsPassed) failures.add('regressions');
    if (!evidence.securityPassed) failures.add('security');
    if (!evidence.provenancePassed) failures.add('provenance');
    if (!evidence.licensePassed) failures.add('license');

    final requiredGates = task.acceptanceCriteria
        .where((criterion) => criterion.required)
        .map((criterion) => criterion.id)
        .where((id) => id.trim().isNotEmpty)
        .toSet();
    if (!evidence.passedAcceptanceGates.containsAll(requiredGates)) {
      failures.add('acceptance_gates');
    }

    return failures.isEmpty
        ? WorkshopResearchEvolutionPolicyDecision.approved()
        : WorkshopResearchEvolutionPolicyDecision.rejected(failures);
  }
}
