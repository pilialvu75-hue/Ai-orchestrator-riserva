import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_gate_evidence_export.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

void main() {
  WorkshopTaskInferenceResult rejected({
    String requestId = 'task-1',
    String after = "import 'star.dart';\nvoid main() {}\n",
    bool reviewApproved = false,
    WorkshopValidationVerdict? validation,
  }) {
    return WorkshopTaskInferenceResult(
      proposal: WorkshopChangeProposal(
        requestId: requestId,
        explanation: 'Source-only change',
        changes: <WorkspaceFileChange>[
          WorkspaceFileChange(
            path: 'lib/main.dart',
            type: WorkspaceChangeType.modification,
            beforeContent: 'void main() {}\n',
            afterContent: after,
          ),
        ],
      ),
      review: WorkshopReviewVerdict(
        approved: reviewApproved,
        summary: 'Unexpected star.dart import',
        findings: const <String>['Unresolved source import'],
      ),
      validation: validation,
    );
  }

  test('exports exact rejected code locally with scoped task identity', () {
    final evidence = WorkshopGateEvidenceExport.encode(
      projectId: 'project-1',
      taskRequestId: 'task-1',
      result: rejected(),
    );
    final data = jsonDecode(evidence) as Map<String, dynamic>;
    expect(data['schemaVersion'], 1);
    expect(data['failureGate'], 'review');
    expect(data['reviewApproved'], false);
    expect(data['projectId'], 'project-1');
    expect(data['taskRequestId'], 'task-1');
    final files = data['changes'] as List<dynamic>;
    expect(files, hasLength(1));
    final file = files.single as Map<String, dynamic>;
    expect(file['path'], 'lib/main.dart');
    expect(file['type'], 'modification');
    expect(file['before'], 'void main() {}\n');
    expect(file['after'], "import 'star.dart';\nvoid main() {}\n");
    expect(evidence, isNot(contains('promptSha256')));
  });

  test('rejects stale task identity instead of copying unrelated source', () {
    expect(
      () => WorkshopGateEvidenceExport.encode(
        projectId: 'project-1',
        taskRequestId: 'different-task',
        result: rejected(),
      ),
      throwsStateError,
    );
  });

  test('does not offer rejected-gate export for accepted verdicts', () {
    expect(
      () => WorkshopGateEvidenceExport.encode(
        projectId: 'project-1',
        taskRequestId: 'task-1',
        result: rejected(reviewApproved: true),
      ),
      throwsStateError,
    );
  });

  test('permits explicit evidence for rejected validation, not approval', () {
    final text = WorkshopGateEvidenceExport.encode(
      projectId: 'project-1',
      taskRequestId: 'task-1',
      result: rejected(
        reviewApproved: true,
        validation: const WorkshopValidationVerdict(
          valid: false,
          summary: 'Validation failed',
          checks: <String>['Source does not compile'],
        ),
      ),
    );
    final data = jsonDecode(text) as Map<String, dynamic>;
    expect(data['failureGate'], 'validation');
    expect(data['validationValid'], false);
    expect(data['validationChecks'], contains('Source does not compile'));
  });

  test('fails closed for oversized code instead of silently truncating', () {
    expect(
      () => WorkshopGateEvidenceExport.encode(
        projectId: 'project-1',
        taskRequestId: 'task-1',
        result: rejected(
          after: List<String>.filled(
            WorkshopGateEvidenceExport.maxExportChars + 1,
            'a',
          ).join(),
        ),
      ),
      throwsStateError,
    );
  });
}
