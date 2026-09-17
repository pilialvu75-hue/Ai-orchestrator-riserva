import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkshopExecution', () {
    test('serializes distinct execution and attempt identities', () {
      final now = DateTime.utc(2026, 9, 5, 16, 30);
      final attemptStartedAt = now.add(const Duration(minutes: 5));
      final execution = WorkshopExecution(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project-1',
        taskId: 'task-1',
        sessionId: 'session-1',
        allocationId: 'allocation-1',
        executorId: 'cloud-openai',
        resource: WorkshopTaskResource.cloud,
        providerId: 'openAi',
        modelId: 'model-1',
        accountId: 'account-1',
        status: WorkshopExecutionStatus.checkpointed,
        startedAt: now,
        attemptStartedAt: attemptStartedAt,
        updatedAt: attemptStartedAt,
        checkpointId: 'checkpoint-1',
        resumePhase: 'implementation',
        inputTokens: 100,
        outputTokens: 50,
        estimatedCredits: 2.5,
      );

      final restored = WorkshopExecution.fromJson(execution.toJson());

      expect(restored.executionId, 'execution-1');
      expect(restored.attemptId, 'attempt-1');
      expect(restored.projectId, 'project-1');
      expect(restored.taskId, 'task-1');
      expect(restored.sessionId, 'session-1');
      expect(restored.providerId, 'openAi');
      expect(restored.modelId, 'model-1');
      expect(restored.accountId, 'account-1');
      expect(restored.checkpointId, 'checkpoint-1');
      expect(restored.totalTokens, 150);
      expect(restored.isTerminal, isFalse);
      expect(restored.effectiveAttemptStartedAt, attemptStartedAt);
    });

    test('legacy records recover execution start as attempt start', () {
      final now = DateTime.utc(2026, 9, 5, 16, 30);
      final restored = WorkshopExecution.fromJson(<String, dynamic>{
        'executionId': 'legacy-execution',
        'projectId': 'project-1',
        'taskId': 'task-1',
        'sessionId': 'session-1',
        'resource': 'cloud',
        'status': 'checkpointed',
        'startedAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'checkpointId': 'checkpoint-1',
      });

      expect(restored.executionId, 'legacy-execution');
      expect(restored.attemptId, 'legacy-execution');
      expect(restored.checkpointId, 'checkpoint-1');
      expect(restored.attemptStartedAt, isNull);
      expect(restored.effectiveAttemptStartedAt, now);
    });

    test('store persists executions and finds latest resumable execution', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopExecutionStore(preferences: preferences);

      final created = await store.create(
        projectId: 'project-1',
        taskId: 'task-1',
        sessionId: 'session-1',
        resource: WorkshopTaskResource.cloud,
        providerId: 'claude',
        modelId: 'claude-model',
      );

      expect(created.executionId, isNotEmpty);
      expect(created.attemptId, isNotEmpty);
      expect(created.attemptId, isNot(created.executionId));
      expect(created.attemptStartedAt, isNotNull);

      final checkpointed = created.copyWith(
        status: WorkshopExecutionStatus.checkpointed,
        checkpointId: 'checkpoint-1',
        resumePhase: 'review',
      );
      await store.save(checkpointed);

      final recovered = await store.latestResumableForTask('task-1');

      expect(recovered, isNotNull);
      expect(recovered!.executionId, created.executionId);
      expect(recovered.attemptId, created.attemptId);
      expect(recovered.projectId, 'project-1');
      expect(recovered.checkpointId, 'checkpoint-1');
      expect(recovered.resumePhase, 'review');

      final attempts = await store.loadAttempts(created.executionId);
      expect(attempts, hasLength(1));
      expect(attempts.single.attemptId, created.attemptId);
    });

    test('provider failover preserves old attempt and resets new usage', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopExecutionStore(preferences: preferences);

      final created = await store.create(
        projectId: 'project-1',
        taskId: 'task-1',
        sessionId: 'session-1',
        resource: WorkshopTaskResource.cloud,
        allocationId: 'allocation-a',
        executorId: 'executor-a',
        providerId: 'openAi',
        modelId: 'model-a',
        accountId: 'account-a',
        estimatedCredits: 4,
      );
      final checkpointed = created.copyWith(
        status: WorkshopExecutionStatus.checkpointed,
        checkpointId: 'checkpoint-7',
        resumePhase: 'implementation',
        inputTokens: 120,
        outputTokens: 30,
        actualCost: 0.12,
      );
      await store.save(checkpointed);

      final resumed = await store.beginNextAttempt(
        execution: checkpointed,
        allocationId: 'allocation-b',
        executorId: 'executor-b',
        providerId: 'gemini',
        modelId: 'model-b',
        accountId: 'account-b',
        estimatedCredits: 1.5,
      );

      expect(resumed.executionId, checkpointed.executionId);
      expect(resumed.attemptId, isNot(checkpointed.attemptId));
      expect(resumed.projectId, checkpointed.projectId);
      expect(resumed.taskId, checkpointed.taskId);
      expect(resumed.sessionId, checkpointed.sessionId);
      expect(resumed.checkpointId, 'checkpoint-7');
      expect(resumed.resumePhase, 'implementation');
      expect(resumed.providerId, 'gemini');
      expect(resumed.modelId, 'model-b');
      expect(resumed.accountId, 'account-b');
      expect(resumed.executorId, 'executor-b');
      expect(resumed.allocationId, 'allocation-b');
      expect(resumed.status, WorkshopExecutionStatus.created);
      expect(resumed.inputTokens, 0);
      expect(resumed.outputTokens, 0);
      expect(resumed.estimatedCredits, 1.5);
      expect(resumed.actualCost, isNull);
      expect(resumed.startedAt, checkpointed.startedAt);
      expect(
        resumed.effectiveAttemptStartedAt
            .isBefore(checkpointed.effectiveAttemptStartedAt),
        isFalse,
      );

      final stored = await store.load(checkpointed.executionId);
      expect(stored, isNotNull);
      expect(stored!.attemptId, resumed.attemptId);
      expect(stored.providerId, 'gemini');
      expect(stored.checkpointId, 'checkpoint-7');

      var attempts = await store.loadAttempts(checkpointed.executionId);
      expect(attempts, hasLength(2));
      expect(attempts.first.attemptId, checkpointed.attemptId);
      expect(attempts.first.providerId, 'openAi');
      expect(attempts.first.inputTokens, 120);
      expect(attempts.first.outputTokens, 30);
      expect(attempts.first.actualCost, 0.12);
      expect(attempts.last.attemptId, resumed.attemptId);
      expect(attempts.last.providerId, 'gemini');

      final completedSecondAttempt = resumed.copyWith(
        status: WorkshopExecutionStatus.completed,
        inputTokens: 20,
        outputTokens: 10,
        actualCost: 0.03,
      );
      await store.save(completedSecondAttempt);

      attempts = await store.loadAttempts(checkpointed.executionId);
      expect(attempts, hasLength(2));
      expect(attempts.last.status, WorkshopExecutionStatus.completed);

      final usage = await store.usageForExecution(checkpointed.executionId);
      expect(usage.attemptCount, 2);
      expect(usage.inputTokens, 140);
      expect(usage.outputTokens, 40);
      expect(usage.totalTokens, 180);
      expect(usage.estimatedCredits, 5.5);
      expect(usage.actualCost, closeTo(0.15, 0.000001));
    });

    test('historical v1 current record becomes first attempt audit entry',
        () async {
      final now = DateTime.utc(2026, 9, 5, 16, 30);
      final legacy = <String, dynamic>{
        'executionId': 'execution-legacy',
        'attemptId': 'attempt-legacy',
        'projectId': 'project-1',
        'taskId': 'task-1',
        'sessionId': 'session-1',
        'resource': 'cloud',
        'providerId': 'claude',
        'status': 'checkpointed',
        'startedAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'checkpointId': 'checkpoint-legacy',
        'inputTokens': 11,
        'outputTokens': 7,
        'estimatedCredits': 1.25,
        'actualCost': 0.02,
      };
      SharedPreferences.setMockInitialValues(<String, Object>{
        'workshop.executions.v1': jsonEncode(<String, dynamic>{
          'version': 1,
          'items': <String, dynamic>{
            'execution-legacy': legacy,
          },
        }),
      });
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopExecutionStore(preferences: preferences);

      final attempts = await store.loadAttempts('execution-legacy');

      expect(attempts, hasLength(1));
      expect(attempts.single.attemptId, 'attempt-legacy');
      expect(attempts.single.effectiveAttemptStartedAt, now);

      final next = await store.beginNextAttempt(
        execution: attempts.single,
        providerId: 'gemini',
      );
      final migratedAttempts = await store.loadAttempts('execution-legacy');
      expect(migratedAttempts, hasLength(2));
      expect(migratedAttempts.first.attemptId, 'attempt-legacy');
      expect(migratedAttempts.last.attemptId, next.attemptId);
    });

    test('saving one attempt repeatedly updates audit record in place', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopExecutionStore(preferences: preferences);

      final created = await store.create(
        projectId: 'project-1',
        taskId: 'task-1',
        sessionId: 'session-1',
        resource: WorkshopTaskResource.local,
      );
      await store.save(created.copyWith(inputTokens: 10));
      await store.save(created.copyWith(inputTokens: 25, outputTokens: 5));

      final attempts = await store.loadAttempts(created.executionId);
      expect(attempts, hasLength(1));
      expect(attempts.single.inputTokens, 25);
      expect(attempts.single.outputTokens, 5);
    });
  });

  group('InferenceRequest execution identity', () {
    test('copyWith preserves and updates distinct identities', () {
      const request = InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
        requestId: 'request-1',
        projectId: 'project-1',
        taskId: 'task-1',
        executionId: 'execution-1',
        checkpointId: 'checkpoint-1',
      );

      final copied = request.copyWith(
        executionId: 'execution-2',
        checkpointId: 'checkpoint-2',
      );

      expect(copied.sessionId, 'session-1');
      expect(copied.requestId, 'request-1');
      expect(copied.projectId, 'project-1');
      expect(copied.taskId, 'task-1');
      expect(copied.executionId, 'execution-2');
      expect(copied.checkpointId, 'checkpoint-2');
    });
  });
}
