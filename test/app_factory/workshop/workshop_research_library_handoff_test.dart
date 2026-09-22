import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_transport.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_research_evolution_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_research_library_handoff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validated Researcher candidate reaches discovered Library intake only', () async {
    WorkshopLibraryIntakeBundle? transmitted;
    final handoff = WorkshopResearchLibraryHandoff(
      submissionService: WorkshopLibrarySubmissionService(
        submitBundle: (bundle) async {
          transmitted = bundle;
          return const WorkshopLibraryGitHubSubmissionReceipt(
            repository: 'test/library',
            branch: 'intake/test',
            alreadyOnMain: false,
            pullRequestNumber: 1,
          );
        },
      ),
    );
    final task = _task();
    final files = <WorkshopLibraryIntakePayloadFile>[
      WorkshopLibraryIntakePayloadFile(
        path: 'module.dart',
        bytes: 'candidate'.codeUnits,
      ),
    ];
    final evidence = _evidence(
      taskId: task.id,
      sha: WorkshopLibraryIntakeBundle.computePayloadSha256(files),
    );

    final result = await handoff.submitValidatedCandidate(
      task: task,
      result: _result(valid: true),
      evidence: evidence,
    );

    expect(result.transmitted, isTrue);
    expect(transmitted, isNotNull);
    expect(transmitted!.manifestPath, startsWith('intake/'));
    expect(transmitted!.manifestPath, isNot(startsWith('modules/')));
    expect(transmitted!.manifest['status'], 'discovered');
  });

  test('unvalidated Researcher candidate never reaches Library transport', () async {
    var calls = 0;
    final handoff = WorkshopResearchLibraryHandoff(
      submissionService: WorkshopLibrarySubmissionService(
        submitBundle: (bundle) async {
          calls++;
          return const WorkshopLibraryGitHubSubmissionReceipt(
            repository: 'test/library',
            branch: 'unused',
            alreadyOnMain: false,
          );
        },
      ),
    );
    final task = _task();

    final result = await handoff.submitValidatedCandidate(
      task: task,
      result: _result(valid: false),
      evidence: _evidence(taskId: task.id, sha: List.filled(64, '0').join()),
    );

    expect(result.transmitted, isFalse);
    expect(result.reasons, contains('research-candidate-not-validated'));
    expect(calls, 0);
  });

  test('Researcher task identity mismatch fails closed before Library transport', () async {
    var calls = 0;
    final handoff = WorkshopResearchLibraryHandoff(
      submissionService: WorkshopLibrarySubmissionService(
        submitBundle: (bundle) async {
          calls++;
          return const WorkshopLibraryGitHubSubmissionReceipt(
            repository: 'test/library',
            branch: 'unused',
            alreadyOnMain: false,
          );
        },
      ),
    );

    final result = await handoff.submitValidatedCandidate(
      task: _task(),
      result: _result(valid: true),
      evidence: _evidence(taskId: 'different-task', sha: List.filled(64, '0').join()),
    );

    expect(result.transmitted, isFalse);
    expect(result.reasons, contains('research-candidate-task-traceability-mismatch'));
    expect(calls, 0);
  });
}

WorkshopTaskContract _task() =>
    const WorkshopResearchEvolutionTaskAdapter().toTask(
      const WorkshopResearchEvolutionRequest(
        proposalId: 'handoff-1',
        capabilityId: 'network.http',
        knowledgeDelta: <String>['practice:retry'],
        acceptanceGates: <String>['tests', 'security'],
        mutationPolicy: 'isolated_candidate_no_library_mutation',
      ),
    );

WorkshopTaskInferenceResult _result({required bool valid}) =>
    WorkshopTaskInferenceResult(
      proposal: const WorkshopChangeProposal(
        requestId: 'research-intake:research-evolution:handoff-1',
        explanation: 'candidate',
        changes: <WorkspaceFileChange>[
          WorkspaceFileChange(
            path: 'candidate_workspace/module.dart',
            type: WorkspaceChangeType.addition,
            afterContent: 'candidate',
          ),
        ],
      ),
      review: const WorkshopReviewVerdict(
        approved: true,
        summary: 'review passed',
      ),
      validation: WorkshopValidationVerdict(
        valid: valid,
        summary: valid ? 'validation passed' : 'validation failed',
      ),
    );

WorkshopLibraryCaptureEvidence _evidence({
  required String taskId,
  required String sha,
}) =>
    WorkshopLibraryCaptureEvidence(
      assetId: 'network.http',
      name: 'HTTP Network',
      version: '1.0.0',
      kind: WorkshopLibraryAssetKind.module,
      description: 'Validated Researcher HTTP candidate.',
      capabilities: const <String>['network.http'],
      platforms: const <String>['android'],
      sourceProjectId: 'project:research-evolution:handoff-1',
      sourceTaskId: taskId,
      license: 'Apache-2.0',
      validationScore: 1,
      testsPassed: true,
      validatedAt: DateTime.utc(2026, 9, 22),
      securityReviewed: true,
      securityReviewedAt: DateTime.utc(2026, 9, 22),
      knownVulnerabilities: 0,
      integrationEffort: WorkshopLibrarySubmissionIntegrationEffort.low,
      adaptationAllowed: true,
      connector: const WorkshopLibraryConnectorEvidence(
        provides: <WorkshopLibraryLegoProvide>[
          WorkshopLibraryLegoProvide(
            capabilityId: 'network.http',
            contractId: 'network.http.v1',
            contractVersion: '1.0',
          ),
        ],
      ),
      payload: WorkshopLibraryPayloadEvidence(
        type: WorkshopLibraryPayloadType.archive,
        path: 'payload/candidate.json',
        sha256: sha,
      ),
      entryPaths: const <String>['module.dart'],
      generatedAt: DateTime.utc(2026, 9, 22),
    );
