import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_device_acceptance.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('classifies malformed model output separately from runtime failure', () {
    final parsing = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.failed,
      executionError: const FormatException('bad json'),
      inferenceResult: null,
      buildResult: null,
      buildVerified: false,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );
    final runtime = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.failed,
      executionError: StateError('runtime unavailable'),
      inferenceResult: null,
      buildResult: null,
      buildVerified: false,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );

    expect(parsing.status, WorkshopDeviceAcceptanceStatus.failed);
    expect(
      parsing.failureStage,
      WorkshopDeviceAcceptanceFailureStage.parsing,
    );
    expect(
      runtime.failureStage,
      WorkshopDeviceAcceptanceFailureStage.modelRuntime,
    );
  });

  test('distinguishes review and validation rejection', () {
    final reviewFailure = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(reviewApproved: false),
      buildResult: null,
      buildVerified: false,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );
    final validationFailure = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(
        reviewApproved: true,
        validationValid: false,
      ),
      buildResult: null,
      buildVerified: false,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );

    expect(
      reviewFailure.failureStage,
      WorkshopDeviceAcceptanceFailureStage.review,
    );
    expect(
      validationFailure.failureStage,
      WorkshopDeviceAcceptanceFailureStage.validation,
    );
  });

  test('distinguishes build, installer and physical launch failure', () {
    final failedBuild = _build(WorkshopBuildStatus.failed);
    final buildFailure = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(),
      buildResult: failedBuild,
      buildVerified: false,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );
    final installFailure = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(),
      buildResult: _build(WorkshopBuildStatus.succeeded),
      buildVerified: true,
      installAttempted: true,
      installerOpened: false,
      generatedAppOpened: null,
    );
    final launchFailure = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(),
      buildResult: _build(WorkshopBuildStatus.succeeded),
      buildVerified: true,
      installAttempted: true,
      installerOpened: true,
      generatedAppOpened: false,
    );

    expect(
      buildFailure.failureStage,
      WorkshopDeviceAcceptanceFailureStage.build,
    );
    expect(
      installFailure.failureStage,
      WorkshopDeviceAcceptanceFailureStage.install,
    );
    expect(
      launchFailure.failureStage,
      WorkshopDeviceAcceptanceFailureStage.launch,
    );
  });

  test('passes only after explicit generated-app launch confirmation', () {
    final pending = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(),
      buildResult: _build(WorkshopBuildStatus.succeeded),
      buildVerified: true,
      installAttempted: true,
      installerOpened: true,
      generatedAppOpened: null,
    );
    final passed = WorkshopDeviceAcceptanceClassifier.classify(
      executionStatus: WorkshopProductionExecutionStatus.succeeded,
      executionError: null,
      inferenceResult: _inference(),
      buildResult: _build(WorkshopBuildStatus.succeeded),
      buildVerified: true,
      installAttempted: true,
      installerOpened: true,
      generatedAppOpened: true,
    );

    expect(pending.status, WorkshopDeviceAcceptanceStatus.pending);
    expect(passed.status, WorkshopDeviceAcceptanceStatus.passed);
    expect(
      passed.failureStage,
      WorkshopDeviceAcceptanceFailureStage.none,
    );
  });

  test('receipt round-trips through persistent store without prompt text',
      () async {
    final receipt = WorkshopDeviceAcceptanceReceipt(
      recordedAtUtc: DateTime.utc(2026, 9, 28),
      status: WorkshopDeviceAcceptanceStatus.passed,
      failureStage: WorkshopDeviceAcceptanceFailureStage.none,
      hostVersion: '1.0.12+2583',
      hostCommitSha: List<String>.filled(40, 'a').join(),
      platform: 'android',
      projectId: 'project:counter',
      requestId: 'request:counter',
      modelAssignments: const <String, String>{
        'workshopOrchestrator': 'phi3_5_mini',
        'architect': 'phi3_5_mini',
        'engineer': 'phi3_5_mini',
        'reviewer': 'phi3_5_mini',
      },
      promptSha256: WorkshopAcceptanceFingerprint.sha256Text(
        'Create a counter app.',
      ),
      completedTasks: 3,
      totalTasks: 3,
      executionStatus: 'succeeded',
      reviewApproved: true,
      reviewSummary: 'review passed',
      reviewFindings: const <String>['bounded finding'],
      reviewWarnings: const <String>['bounded warning'],
      stagedDiffSha256: List<String>.filled(64, 'c').join(),
      validationValid: true,
      buildStatus: 'succeeded',
      formatPassed: true,
      analysisPassed: true,
      testsPassed: true,
      artifactSha256: List<String>.filled(64, 'b').join(),
      installAttempted: true,
      installerOpened: true,
      generatedAppOpened: true,
    );

    final store = await WorkshopDeviceAcceptanceStore.open();
    await store.save(receipt);
    final restored = store.loadLatest();

    expect(restored, isNotNull);
    expect(restored!.toJson(), receipt.toJson());
    expect(restored.toPrettyJson(), contains('"promptSha256"'));
    expect(restored!.reviewSummary, 'review passed');
    expect(restored.reviewFindings, <String>['bounded finding']);
    expect(restored.reviewWarnings, <String>['bounded warning']);
    expect(restored.stagedDiffSha256, hasLength(64));
    expect(
      restored.toPrettyJson(),
      isNot(contains('Create a counter app.')),
    );
    expect(restored.toPrettyJson(), isNot(contains('/data/user/')));
  });

  test('acceptance receipt fallback is scoped to the current project', () {
    final prior = WorkshopDeviceAcceptanceReceipt(
      recordedAtUtc: DateTime.utc(2026, 10, 7),
      status: WorkshopDeviceAcceptanceStatus.failed,
      failureStage: WorkshopDeviceAcceptanceFailureStage.review,
      hostVersion: '1.0.12+3039',
      hostCommitSha: List<String>.filled(40, 'a').join(),
      platform: 'android',
      projectId: 'project:manga-bigs',
      requestId: 'request:manga-bigs',
      modelAssignments: const <String, String>{
        'engineer': 'qwen2_5_3b_instruct',
        'reviewer': 'qwen2_5_3b_instruct',
      },
      promptSha256: List<String>.filled(64, 'b').join(),
      completedTasks: 0,
      totalTasks: 1,
      executionStatus: 'succeeded',
      reviewApproved: false,
      reviewSummary: 'old Manga Bigs review',
      reviewFindings: const <String>['old finding'],
      reviewWarnings: const <String>[],
      stagedDiffSha256: List<String>.filled(64, 'c').join(),
      validationValid: null,
      buildStatus: null,
      formatPassed: null,
      analysisPassed: null,
      testsPassed: null,
      artifactSha256: null,
      installAttempted: false,
      installerOpened: false,
      generatedAppOpened: null,
    );

    expect(
      WorkshopDeviceAcceptanceScope.forProject(
        receipt: prior,
        projectId: 'project:manga-bigs',
      ),
      same(prior),
    );
    expect(
      WorkshopDeviceAcceptanceScope.forProject(
        receipt: prior,
        projectId: 'project:lista-spesa-lite',
      ),
      isNull,
    );
    expect(
      WorkshopDeviceAcceptanceScope.forProject(
        receipt: prior,
        projectId: null,
      ),
      isNull,
    );
  });

  test('prompt fingerprint is stable without exposing prompt text', () {
    final first = WorkshopAcceptanceFingerprint.sha256Text(
      'Create a counter app.',
    );
    final second = WorkshopAcceptanceFingerprint.sha256Text(
      '  Create a counter app.  ',
    );

    expect(first, isNotNull);
    expect(first, second);
    expect(first, hasLength(64));
    expect(first, isNot(contains('counter')));
  });

  test('host commit identity rejects missing or malformed values', () {
    expect(
      WorkshopHostBuildIdentity.normalizeCommitSha(List<String>.filled(40, 'A').join()),
      List<String>.filled(40, 'a').join(),
    );
    expect(
      WorkshopHostBuildIdentity.normalizeCommitSha('not-a-sha'),
      'unknown',
    );
  });
}

WorkshopTaskInferenceResult _inference({
  bool reviewApproved = true,
  bool validationValid = true,
}) {
  return WorkshopTaskInferenceResult(
    proposal: const WorkshopChangeProposal(
      requestId: 'request',
      explanation: 'bounded fixture',
      changes: [],
    ),
    review: WorkshopReviewVerdict(
      approved: reviewApproved,
      summary: reviewApproved ? 'review passed' : 'review rejected',
    ),
    validation: reviewApproved
        ? WorkshopValidationVerdict(
            valid: validationValid,
            summary: validationValid
                ? 'validation passed'
                : 'validation rejected',
          )
        : null,
  );
}

WorkshopBuildResult _build(WorkshopBuildStatus status) {
  final now = DateTime.utc(2026, 9, 28);
  return WorkshopBuildResult(
    requestId: 'build',
    target: WorkshopBuildTarget.android,
    status: status,
    startedAt: now,
    finishedAt: now,
    artifactPath: status == WorkshopBuildStatus.succeeded
        ? '/tmp/app.apk'
        : null,
    formatPassed: status == WorkshopBuildStatus.succeeded,
    analysisPassed: status == WorkshopBuildStatus.succeeded,
    testsPassed: status == WorkshopBuildStatus.succeeded,
  );
}
