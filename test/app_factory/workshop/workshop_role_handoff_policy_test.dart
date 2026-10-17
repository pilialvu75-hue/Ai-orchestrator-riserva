import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_handoff_policy.dart';

void main() {
  test('ordinary code rejection remains Engineer-owned', () {
    const verdict = WorkshopReviewVerdict(
      approved: false,
      summary: 'Invalid import',
      findings: <String>['Fix unresolved import'],
    );
    expect(WorkshopRoleHandoffPolicy.forRejectedReview(verdict),
        WorkshopRoleHandoffTarget.engineer);
  });

  test('explicit architecture marker requests Architect advisory', () {
    const verdict = WorkshopReviewVerdict(
      approved: false,
      summary: 'Wrong component structure',
      findings: <String>['HANDOFF:ARCHITECT'],
    );
    expect(WorkshopRoleHandoffPolicy.forRejectedReview(verdict),
        WorkshopRoleHandoffTarget.architect);
  });

  test('owner requirement conflict routes via Orchestrator first', () {
    const verdict = WorkshopReviewVerdict(
      approved: false,
      summary: 'Scope conflict',
      findings: <String>['HANDOFF:ARCHITECT', 'HANDOFF:ORCHESTRATOR'],
    );
    expect(WorkshopRoleHandoffPolicy.forRejectedReview(verdict),
        WorkshopRoleHandoffTarget.orchestrator);
  });

  test('ordinary text mentioning a role never authorizes escalation', () {
    const verdict = WorkshopReviewVerdict(
      approved: false,
      summary: 'Needs architect advice',
      findings: <String>['Maybe ask HANDOFF:ARCHITECT in future'],
    );
    expect(WorkshopRoleHandoffPolicy.forRejectedReview(verdict),
        WorkshopRoleHandoffTarget.engineer);
  });

  test('approved review never performs a specialist handoff', () {
    const verdict = WorkshopReviewVerdict(
      approved: true,
      summary: 'Approved',
      findings: <String>['HANDOFF:ORCHESTRATOR'],
    );
    expect(WorkshopRoleHandoffPolicy.forRejectedReview(verdict),
        WorkshopRoleHandoffTarget.engineer);
  });
}
