import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_task_projection.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

void main() {
  test('projection reuses canonical task graph and completion criteria', () {
    final task = WorkshopTaskContract(
      id: 'build-android',
      title: 'Build Android',
      objective: 'Produce a validated APK.',
      kind: WorkshopTaskKind.build,
      status: WorkshopTaskStatus.checkpointed,
      dependsOn: const <String>['generate-code'],
      acceptanceCriteria: const <WorkshopTaskAcceptanceCriterion>[
        WorkshopTaskAcceptanceCriterion(
          id: 'apk.exists',
          description: 'APK exists.',
        ),
        WorkshopTaskAcceptanceCriterion(
          id: 'optional.note',
          description: 'Optional note.',
          required: false,
        ),
      ],
      checkpoint: WorkshopTaskCheckpoint(
        id: 'checkpoint-1',
        createdAt: DateTime.utc(2026, 9, 22),
        phase: 'build',
        metadata: const <String, dynamic>{
          'artifacts': <String>['apk-1', 'apk-1', 'log-1'],
        },
      ),
      createdAt: DateTime.utc(2026, 9, 22),
      updatedAt: DateTime.utc(2026, 9, 22, 8),
    );

    final projected = WorkshopDurableTaskProjection.fromContract(
      task,
      capabilityResolver: (_) => 'build.android',
      retryPolicy: const WorkshopDurableRetryPolicy(maxAttempts: 2),
    );

    expect(projected.taskId, task.id);
    expect(projected.dependencies, task.dependsOn);
    expect(projected.capability, 'build.android');
    expect(projected.state, WorkshopDurableState.ready);
    expect(projected.completionCriterionIds, const <String>['apk.exists']);
    expect(projected.artifactIds, const <String>['apk-1', 'log-1']);
    expect(projected.retryPolicy.maxAttempts, 2);
  });

  test('waiting approval projects to human-gated blocked state', () {
    final task = WorkshopTaskContract(
      id: 'apply',
      title: 'Apply',
      objective: 'Apply validated changes.',
      kind: WorkshopTaskKind.integration,
      status: WorkshopTaskStatus.waitingApproval,
    );

    final projected = WorkshopDurableTaskProjection.fromContract(
      task,
      capabilityResolver: (_) => 'artifact.validate',
    );

    expect(projected.state, WorkshopDurableState.blocked);
    expect(projected.blockedReasonCode, 'owner_approval_required');
  });

  test('projection rejects provider-specific empty capability', () {
    final task = WorkshopTaskContract(
      id: 'review',
      title: 'Review',
      objective: 'Review changes.',
      kind: WorkshopTaskKind.review,
    );

    expect(
      () => WorkshopDurableTaskProjection.fromContract(
        task,
        capabilityResolver: (_) => '   ',
      ),
      throwsStateError,
    );
  });
}
