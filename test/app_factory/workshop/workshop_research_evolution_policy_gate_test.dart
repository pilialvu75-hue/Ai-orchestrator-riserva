import 'package:ai_orchestrator/app_factory/workshop/workshop_research_evolution_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_research_evolution_policy_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gate = WorkshopResearchEvolutionPolicyGate();

  test('approves eligibility only when every autonomous safety gate passes', () {
    final task = _task();
    final decision = gate.evaluate(
      task: task,
      evidence: const WorkshopResearchEvolutionEvidence(
        reviewerApproved: true,
        validationPassed: true,
        testsPassed: true,
        regressionsPassed: true,
        securityPassed: true,
        provenancePassed: true,
        licensePassed: true,
        passedAcceptanceGates: <String>{'tests', 'security'},
      ),
    );

    expect(decision.approved, isTrue);
    expect(decision.reasons, isEmpty);
  });

  test('fails closed when security or required acceptance evidence is missing', () {
    final task = _task();
    final decision = gate.evaluate(
      task: task,
      evidence: const WorkshopResearchEvolutionEvidence(
        reviewerApproved: true,
        validationPassed: true,
        testsPassed: true,
        regressionsPassed: true,
        securityPassed: false,
        provenancePassed: true,
        licensePassed: true,
        passedAcceptanceGates: <String>{'tests'},
      ),
    );

    expect(decision.approved, isFalse);
    expect(decision.reasons, containsAll(<String>['security', 'acceptance_gates']));
  });

  test('rejects a task that can write outside the isolated candidate', () {
    final safe = _task();
    final unsafe = safe.copyWith(
      fileScope: const WorkshopTaskFileScope(
        allowed: <String>['candidate_workspace/**', 'stable_library/**'],
        readOnly: <String>['library_baseline/**', 'research_knowledge/**'],
        forbidden: <String>['stable_library/**'],
      ),
    );
    final decision = gate.evaluate(task: unsafe, evidence: _passingEvidence());

    expect(decision.approved, isFalse);
    expect(decision.reasons, contains('isolation'));
  });
}

WorkshopTaskContract _task() => const WorkshopResearchEvolutionTaskAdapter().toTask(
      const WorkshopResearchEvolutionRequest(
        proposalId: 'proposal-policy',
        capabilityId: 'network.http',
        knowledgeDelta: <String>['practice:tests_present'],
        acceptanceGates: <String>['tests', 'security'],
        mutationPolicy: 'isolated_candidate_no_library_mutation',
      ),
    );

WorkshopResearchEvolutionEvidence _passingEvidence() =>
    const WorkshopResearchEvolutionEvidence(
      reviewerApproved: true,
      validationPassed: true,
      testsPassed: true,
      regressionsPassed: true,
      securityPassed: true,
      provenancePassed: true,
      licensePassed: true,
      passedAcceptanceGates: <String>{'tests', 'security'},
    );
