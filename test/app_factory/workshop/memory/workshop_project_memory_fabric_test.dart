import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/memory/workshop_project_memory_fabric.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution_journal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_resume_context.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/fabric/local_crdt_memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

void main() {
  late _MockDatabaseHelper database;
  late List<Map<String, dynamic>> rows;

  setUp(() {
    database = _MockDatabaseHelper();
    rows = <Map<String, dynamic>>[];

    when(() => database.getSyncChangesSince(any())).thenAnswer(
      (_) async => rows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
    );
    when(() => database.insertSyncChange(any())).thenAnswer((invocation) async {
      final raw = invocation.positionalArguments.first;
      rows.add(Map<String, dynamic>.from(raw as Map));
    });
    when(() => database.getMaxSyncHlc()).thenAnswer(
      (_) async => rows.isEmpty ? null : rows.last['hlc']?.toString(),
    );
    when(() => database.countSyncChanges()).thenAnswer(
      (_) async => rows.length,
    );
  });

  WorkshopProjectMemoryFabricService service() {
    final sync = SyncManager(
      databaseHelper: database,
      nodeId: 'device-a',
    );
    final provider = LocalCrdtMemoryFabricProvider(syncManager: sync);
    final fabric = MemoryFabric(<MemoryFabricNode>[
      MemoryFabricNode(
        provider: provider,
        role: MemoryFabricNodeRole.offlineCache,
      ),
    ]);
    return WorkshopProjectMemoryFabricService(memory: fabric);
  }

  test(
    'project memory survives process recreation and continues workflow',
    () async {
      final createdAt = DateTime.utc(2026, 9, 22, 8);
      final request = WorkshopRequest(
        id: 'request-1',
        title: 'Repair build',
        instruction: 'Repair the failing build and continue the project.',
        operation: WorkshopOperation.fix,
        constraints: const <String>['keep Cantiere authoritative'],
      );

      final initialPlan = _plan(
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(minutes: 5)),
        status: WorkshopProjectStatus.blocked,
        task2Completed: false,
      );
      final initialDurable = _durable(
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(minutes: 6)),
        state: WorkshopDurableState.blocked,
        task2State: WorkshopDurableState.blocked,
        attemptsStarted: 1,
        blockedReasonCode: 'build_error',
      );
      final initialResume = WorkshopResumeContext(
        executionId: 'execution-2',
        attemptId: 'attempt-1',
        projectId: initialPlan.id,
        taskId: 'task-2',
        sessionId: 'session-1',
        objective: 'Repair the failing build.',
        phase: 'validation',
        checkpointId: 'checkpoint-1',
        constraints: const <String>['keep Cantiere authoritative'],
        completedSteps: const <String>['analysis'],
        changedFiles: const <String>['lib/app.dart'],
        decisions: const <String>['Keep Cantiere authoritative'],
        verified: const <String>['flutter analyze'],
        remainingWork: const <String>['repair task-2', 'run CI'],
        artifacts: const <String>['build-log-1'],
        nextStep: 'repair task-2',
      );
      final failedExecution = WorkshopExecutionRecord(
        id: 'execution-2',
        taskId: 'task-2',
        status: 'failed',
        startedAt: createdAt.add(const Duration(minutes: 3)),
        completedAt: createdAt.add(const Duration(minutes: 6)),
        providerId: 'local',
        mode: 'offline',
        error: 'compile failed',
        checkpoint: 'checkpoint-1',
        changedFiles: const <String>['lib/app.dart'],
        artifacts: const <String>['build-log-1'],
        metadata: const <String, dynamic>{
          'decisions': <String>['Keep Cantiere authoritative'],
          'verified': <String>['flutter analyze'],
          'fixes': <String>['pin compatible dependency'],
        },
      );

      final firstProcess = service();
      final firstRecord = await firstProcess.save(
        request: request,
        plan: initialPlan,
        durable: initialDurable,
        resumeContext: initialResume,
        executions: <WorkshopExecutionRecord>[failedExecution],
        ciEvidence: const <Map<String, Object?>>[
          <String, Object?>{
            'provider': 'github_actions',
            'run_id': '42',
            'status': 'failed',
          },
        ],
      );

      expect(firstRecord.version, 1);
      expect(firstRecord.privacyLevel, MemoryFabricPrivacyLevel.project);
      expect(firstRecord.checksumValid, isTrue);

      // Simulate full process recreation. No MemoryFabric/SyncManager/provider
      // object from the first process is reused; only persisted CRDT rows stay.
      final secondProcess = service();
      final recovered = await secondProcess.load(initialPlan.id);

      expect(recovered, isNotNull);
      expect(
        recovered!.originalRequest,
        'Repair the failing build and continue the project.',
      );
      expect(recovered.status, 'blocked');
      expect(
        recovered.tasks.singleWhere(
          (task) => task['id'] == 'task-2',
        )['durable_state'],
        'blocked',
      );
      expect(recovered.lastError, 'build_error');
      expect(recovered.nextStep, 'repair task-2');
      expect(recovered.decisions, contains('Keep Cantiere authoritative'));
      expect(recovered.artifacts, contains('build-log-1'));

      // Continue the authoritative workflow from the recovered knowledge.
      final continuedPlan = _plan(
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(minutes: 12)),
        status: WorkshopProjectStatus.inProgress,
        task2Completed: false,
      );
      final continuedDurable = _durable(
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(minutes: 12)),
        state: WorkshopDurableState.validating,
        task2State: WorkshopDurableState.validating,
        attemptsStarted: 2,
      );
      final continuedResume = WorkshopResumeContext(
        executionId: 'execution-2',
        attemptId: 'attempt-2',
        projectId: continuedPlan.id,
        taskId: 'task-2',
        sessionId: 'session-2',
        objective: 'Validate the repaired build.',
        phase: 'validation',
        checkpointId: 'checkpoint-2',
        constraints: const <String>['keep Cantiere authoritative'],
        completedSteps: const <String>['analysis', 'repair'],
        changedFiles: const <String>['lib/app.dart', 'pubspec.yaml'],
        decisions: const <String>['Keep Cantiere authoritative'],
        verified: const <String>[
          'flutter analyze',
          'focused repair test',
        ],
        remainingWork: const <String>['run CI'],
        artifacts: const <String>['build-log-1', 'repair-patch'],
        nextStep: 'run CI',
      );
      final repairExecution = WorkshopExecutionRecord(
        id: 'execution-3',
        taskId: 'task-2',
        status: 'completed',
        startedAt: createdAt.add(const Duration(minutes: 8)),
        completedAt: createdAt.add(const Duration(minutes: 11)),
        providerId: 'local',
        mode: 'offline',
        changedFiles: const <String>['lib/app.dart', 'pubspec.yaml'],
        artifacts: const <String>['repair-patch'],
        metadata: const <String, dynamic>{
          'verified': <String>['focused repair test'],
          'fixes': <String>['pin compatible dependency'],
        },
      );

      final secondRecord = await secondProcess.save(
        request: request,
        plan: continuedPlan,
        durable: continuedDurable,
        resumeContext: continuedResume,
        executions: <WorkshopExecutionRecord>[
          failedExecution,
          repairExecution,
        ],
        ciEvidence: const <Map<String, Object?>>[
          <String, Object?>{
            'provider': 'github_actions',
            'run_id': '43',
            'status': 'queued',
          },
        ],
      );

      expect(secondRecord.version, 2);

      final thirdProcess = service();
      final continued = await thirdProcess.load(continuedPlan.id);
      final continuedRecord = await thirdProcess.loadRecord(continuedPlan.id);

      expect(continued, isNotNull);
      expect(continued!.originalRequest, recovered.originalRequest);
      expect(continued.status, 'validating');
      expect(continued.nextStep, 'run CI');
      expect(continued.lastError, 'compile failed');
      expect(
        continued.tasks.singleWhere(
          (task) => task['id'] == 'task-2',
        )['attempts_started'],
        2,
      );
      expect(continued.tests.map((item) => item['name']), contains('focused repair test'));
      expect(continued.fixes, contains('pin compatible dependency'));
      expect(continuedRecord?.version, 2);
      expect(continuedRecord?.checksumValid, isTrue);
    },
  );

  test('rejects durable or resume state from another project', () {
    final createdAt = DateTime.utc(2026, 9, 22, 8);
    final request = WorkshopRequest(
      id: 'request-1',
      title: 'Project',
      instruction: 'Build it.',
    );
    final plan = _plan(
      createdAt: createdAt,
      updatedAt: createdAt,
      status: WorkshopProjectStatus.planned,
      task2Completed: false,
    );
    final wrongDurable = WorkshopDurableProjectSnapshot(
      projectId: 'project:other',
      correlationId: 'correlation-other',
      state: WorkshopDurableState.ready,
      createdAt: createdAt,
      updatedAt: createdAt,
      tasks: const <String, WorkshopDurableTask>{},
    );

    expect(
      () => WorkshopProjectMemorySnapshot.capture(
        request: request,
        plan: plan,
        durable: wrongDurable,
      ),
      throwsStateError,
    );
  });
}

WorkshopProjectPlan _plan({
  required DateTime createdAt,
  required DateTime updatedAt,
  required WorkshopProjectStatus status,
  required bool task2Completed,
}) {
  return WorkshopProjectPlan(
    id: 'project:request-1',
    title: 'Repair build',
    goal: 'Return the project to a validated build.',
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    requirements: const <String>[
      'preserve existing behavior',
      'finish with green validation',
    ],
    validationCriteria: const <String>[
      'flutter analyze passes',
      'CI is green',
    ],
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase-1',
        title: 'Repair',
        description: 'Repair and validate the build.',
        status: task2Completed
            ? WorkshopProjectPhaseStatus.completed
            : WorkshopProjectPhaseStatus.inProgress,
        taskIds: const <String>['task-1', 'task-2'],
        validationCriteria: const <String>['CI is green'],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: 'task-1',
        title: 'Analyze failure',
        description: 'Identify the failing dependency.',
        phaseId: 'phase-1',
        completed: true,
      ),
      WorkshopProjectTask(
        id: 'task-2',
        title: 'Repair build',
        description: 'Apply and validate the repair.',
        phaseId: 'phase-1',
        completed: task2Completed,
        dependencies: const <String>['task-1'],
        validationCriteria: const <String>['focused repair test passes'],
      ),
    ],
  );
}

WorkshopDurableProjectSnapshot _durable({
  required DateTime createdAt,
  required DateTime updatedAt,
  required WorkshopDurableState state,
  required WorkshopDurableState task2State,
  required int attemptsStarted,
  String? blockedReasonCode,
}) {
  return WorkshopDurableProjectSnapshot(
    projectId: 'project:request-1',
    correlationId: 'correlation-1',
    state: state,
    createdAt: createdAt,
    updatedAt: updatedAt,
    tasks: <String, WorkshopDurableTask>{
      'task-1': WorkshopDurableTask(
        taskId: 'task-1',
        capability: 'analysis',
        state: WorkshopDurableState.completed,
        updatedAt: updatedAt,
        attemptsStarted: 1,
      ),
      'task-2': WorkshopDurableTask(
        taskId: 'task-2',
        dependencies: const <String>['task-1'],
        capability: 'repair',
        state: task2State,
        updatedAt: updatedAt,
        attemptsStarted: attemptsStarted,
        artifactIds: const <String>['durable-artifact-1'],
        blockedReasonCode: blockedReasonCode,
      ),
    },
  );
}
