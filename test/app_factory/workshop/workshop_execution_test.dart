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
        updatedAt: now,
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
    });

    test('legacy records recover with execution id as initial attempt id', () {
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
    });

    test('provider failover starts a new attempt of the same execution', () async {
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
      );
      final checkpointed = created.copyWith(
        status: WorkshopExecutionStatus.checkpointed,
        checkpointId: 'checkpoint-7',
        resumePhase: 'implementation',
        inputTokens: 120,
        outputTokens: 30,
        estimatedCredits: 4,
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
      expect(resumed.inputTokens, 120);
      expect(resumed.outputTokens, 30);
      expect(resumed.estimatedCredits, 4);
      expect(resumed.actualCost, 0.12);
      expect(resumed.startedAt, checkpointed.startedAt);

      final stored = await store.load(checkpointed.executionId);
      expect(stored, isNotNull);
      expect(stored!.attemptId, resumed.attemptId);
      expect(stored.providerId, 'gemini');
      expect(stored.checkpointId, 'checkpoint-7');
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
