import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkshopExecution', () {
    test('serializes independent project/task/session/execution identities', () {
      final now = DateTime.utc(2026, 9, 5, 16, 30);
      final execution = WorkshopExecution(
        executionId: 'execution-1',
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

    test('store persists executions and finds latest resumable task attempt', () async {
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

      final checkpointed = created.copyWith(
        status: WorkshopExecutionStatus.checkpointed,
        checkpointId: 'checkpoint-1',
        resumePhase: 'review',
      );
      await store.save(checkpointed);

      final recovered = await store.latestResumableForTask('task-1');

      expect(recovered, isNotNull);
      expect(recovered!.executionId, created.executionId);
      expect(recovered.projectId, 'project-1');
      expect(recovered.checkpointId, 'checkpoint-1');
      expect(recovered.resumePhase, 'review');
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
