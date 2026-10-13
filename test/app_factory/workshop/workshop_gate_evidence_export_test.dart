import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_gate_evidence_export.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

void main() {
  const original = <String, String>{'lib/main.dart': 'void main() {}\n'};
  const staged = <String, String>{
    'lib/main.dart': "import 'star.dart';\nvoid main() {}\n",
  };

  WorkshopTaskInferenceResult rejected({
    String requestId = 'task-1',
    String proposedAfter = "import 'star.dart';\nvoid main() {}\n",
    bool reviewApproved = false,
    WorkshopValidationVerdict? validation,
    Map<String, String> before = original,
    Map<String, String> after = staged,
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
            afterContent: proposedAfter,
          ),
        ],
      ),
      review: WorkshopReviewVerdict(
        approved: reviewApproved,
        summary: 'Unexpected star.dart import',
        findings: const <String>['Unresolved source import'],
      ),
      validation: validation,
      gateEvidenceBaseline: Map<String, String>.unmodifiable(before),
      gateEvidenceStaged: Map<String, String>.unmodifiable(after),
    );
  }

  String evidence(
    WorkshopTaskInferenceResult result, {
    String taskRequestId = 'task-1',
  }) =>
      WorkshopGateEvidenceExport.encode(
        projectId: 'project-1',
        taskRequestId: taskRequestId,
        result: result,
      );

  test('exports exact rejected staged source with scoped task identity', () {
    final text = evidence(rejected());
    final data = jsonDecode(text) as Map<String, dynamic>;
    expect(data['schemaVersion'], 1);
    expect(data['source'], 'staged_virtual_workspace');
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
    expect(text, isNot(contains('promptSha256')));
  });

  test('uses staged workspace rather than untrusted Engineer proposal body', () {
    final text = evidence(rejected(proposedAfter: 'invented transport body'));
    final data = jsonDecode(text) as Map<String, dynamic>;
    final file = (data['changes'] as List<dynamic>).single
        as Map<String, dynamic>;
    expect(file['after'], "import 'star.dart';\nvoid main() {}\n");
    expect(text, isNot(contains('invented transport body')));
  });

  test('Library reuse staged before Engineer is never included in export', () {
    final text = evidence(rejected(
      before: const <String, String>{
        'lib/main.dart': 'after Library reuse, before Engineer',
      },
      after: const <String, String>{
        'lib/main.dart': "import 'star.dart';\\nvoid main() {}\\n",
      },
    ));
    final data = jsonDecode(text) as Map<String, dynamic>;
    final files = data['changes'] as List<dynamic>;
    expect(files, hasLength(1));
    final file = files.single as Map<String, dynamic>;
    expect(file['before'], 'after Library reuse, before Engineer');
    expect(text, isNot(contains('lib/reuse.dart')));
  });

  test('fails closed if evidence carries a path not owned by proposal', () {
    expect(
      () => evidence(rejected(
        before: const <String, String>{
          'lib/main.dart': 'before',
          'lib/reuse.dart': 'unrelated',
        },
        after: const <String, String>{
          'lib/main.dart': 'after',
          'lib/reuse.dart': 'unrelated',
        },
      )),
      throwsStateError,
    );
  });

  test('rejects stale task identity instead of copying unrelated source', () {
    expect(
      () => evidence(rejected(), taskRequestId: 'different-task'),
      throwsStateError,
    );
  });

  test('does not offer rejected-gate export for accepted verdicts', () {
    expect(
      () => evidence(rejected(reviewApproved: true)),
      throwsStateError,
    );
  });

  test('permits explicit evidence for rejected validation, not approval', () {
    final text = evidence(
      rejected(
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
      () => evidence(
        rejected(
          after: <String, String>{
          'lib/main.dart': List<String>.filled(
            WorkshopGateEvidenceExport.maxExportChars + 1,
            'a',
          ).join(),
        },
        ),
      ),
      throwsStateError,
    );
  });

  test('fails closed when rejected proposal has no staged changes', () {
    expect(
      () => evidence(rejected(after: original)),
      throwsStateError,
    );
  });
}
