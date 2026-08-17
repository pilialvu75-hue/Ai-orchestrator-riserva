import 'dart:async';
import 'dart:io';

import 'workshop_task_contract.dart';
import 'workshop_task_execution_guard.dart';
import 'workshop_task_executor.dart';

/// Executor locale del Cantiere.
///
/// Questa prima implementazione è volutamente conservativa.
///
/// Responsabilità:
///
/// - eseguire task LOCAL autorizzate;
/// - verificare lo staging;
/// - verificare il file scope;
/// - produrre progressi e checkpoint;
/// - non consumare crediti cloud;
/// - non modificare il repository reale;
/// - non eseguire comandi arbitrari.
///
/// La toolchain Flutter/Dart/Gradle locale verrà collegata
/// successivamente attraverso un componente dedicato.
///
/// Questo evita di trasformare l'executor in un secondo orchestratore.
final class WorkshopLocalTaskExecutor
    implements WorkshopTaskExecutor {
  WorkshopLocalTaskExecutor({
    this.executorId = 'local-task-executor',
    this.providerId = 'local',
    this.createStagingDirectory = true,
  });

  @override
  final String executorId;

  @override
  final WorkshopTaskResource resource =
      WorkshopTaskResource.local;

  @override
  final String? providerId;

  /// Se true, lo staging mancante viene creato automaticamente.
  ///
  /// La directory deve comunque essere fornita dal contesto.
  final bool createStagingDirectory;

  @override
  bool get isAvailable => Platform.environment.isNotEmpty;

  @override
  Future<WorkshopTaskExecutionResult> execute({
    required WorkshopTaskContract task,
    required WorkshopTaskExecutionGuardDecision guardDecision,
    required WorkshopTaskExecutionContext context,
    WorkshopTaskExecutionProgressCallback? onProgress,
  }) async {
    if (!guardDecision.isAllowed) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: _statusForBlockedDecision(
          guardDecision,
        ),
        message:
            'Local execution rejected by the Execution Guard: '
            '${guardDecision.message}',
      );
    }

    if (task.mode != WorkshopTaskMode.local) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Local executor received a task that is not in Local mode.',
      );
    }

    if (guardDecision.resource !=
        WorkshopTaskResource.local) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Local executor received a task allocated to another resource.',
      );
    }

    final stagingPath = _resolveStagingPath(
      context,
    );

    if (stagingPath == null) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Local execution requires a staging directory.',
      );
    }

    try {
      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'staging',
          message: 'Preparing local staging area.',
          completedSteps: 0,
          totalSteps: 4,
          progress: 0,
        ),
      );

      final stagingDirectory = Directory(stagingPath);

      await _ensureStagingDirectory(
        stagingDirectory,
      );

      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'staging-ready',
          message: 'Local staging area is ready.',
          completedSteps: 1,
          totalSteps: 4,
          progress: 0.25,
        ),
      );

      final scopeResult = _validateFileScope(task);

      if (scopeResult != null) {
        return WorkshopTaskExecutionResult(
          taskId: task.id,
          status: WorkshopTaskStatus.failed,
          message: scopeResult,
        );
      }

      final checkpoint = WorkshopTaskCheckpoint(
        id: '${task.id}-local-staging',
        createdAt: DateTime.now().toUtc(),
        phase: 'local-staging-ready',
        completedSteps: const <String>[
          'guard-approved',
          'staging-ready',
          'scope-validated',
        ],
        changedFiles: const <String>[],
        metadata: <String, dynamic>{
          'executorId': executorId,
          'providerId': providerId,
          'resource': resource.name,
          'stagingRoot': stagingDirectory.path,
          'executionMode': task.mode.name,
          'implementationPhase':
              'safe-local-executor-foundation',
        },
      );

      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'checkpoint',
          message: 'Local checkpoint created.',
          completedSteps: 2,
          totalSteps: 4,
          progress: 0.5,
          checkpoint: checkpoint,
        ),
      );

      /// Importante:
      ///
      /// Non eseguiamo ancora comandi di sistema.
      /// Questo executor prepara l'ambiente e certifica che
      /// la task può procedere in sicurezza.
      ///
      /// La vera toolchain sarà collegata successivamente.
      final preparationCheckpoint =
          WorkshopTaskCheckpoint(
        id: '${task.id}-local-prepared',
        createdAt: DateTime.now().toUtc(),
        phase: 'local-prepared',
        completedSteps: const <String>[
          'guard-approved',
          'staging-ready',
          'scope-validated',
          'local-executor-ready',
        ],
        changedFiles: const <String>[],
        metadata: <String, dynamic>{
          'executorId': executorId,
          'toolchainExecution': false,
          'repositoryModified': false,
          'cloudCreditsUsed': 0,
        },
      );

      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'ready',
          message:
              'Local execution environment prepared safely.',
          completedSteps: 3,
          totalSteps: 4,
          progress: 0.75,
          checkpoint: preparationCheckpoint,
        ),
      );

      final finalCheckpoint = WorkshopTaskCheckpoint(
        id: '${task.id}-local-complete',
        createdAt: DateTime.now().toUtc(),
        phase: 'local-executor-complete',
        completedSteps: const <String>[
          'guard-approved',
          'staging-ready',
          'scope-validated',
          'local-executor-ready',
        ],
        changedFiles: const <String>[],
        metadata: <String, dynamic>{
          'executorId': executorId,
          'repositoryModified': false,
          'stagingOnly': true,
          'cloudCreditsUsed': 0,
          'requiresToolchainBridge': true,
        },
      );

      onProgress?.call(
        WorkshopTaskExecutionProgress(
          taskId: task.id,
          phase: 'complete',
          message:
              'Local executor completed the safe preparation phase.',
          completedSteps: 4,
          totalSteps: 4,
          progress: 1,
          checkpoint: finalCheckpoint,
        ),
      );

      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.completed,
        message:
            'Local task preparation completed. '
            'No repository files were modified.',
        checkpoint: finalCheckpoint,
        changedFiles: const <String>[],
        artifacts: const <String>[],
        metadata: <String, dynamic>{
          'executorId': executorId,
          'resource': resource.name,
          'providerId': providerId,
          'stagingRoot': stagingDirectory.path,
          'repositoryModified': false,
          'cloudCreditsUsed': 0,
          'toolchainExecution': false,
        },
      );
    } on FileSystemException catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Local staging operation failed.',
        metadata: <String, dynamic>{
          'executorId': executorId,
          'error': error.message,
          'path': error.path,
        },
      );
    } catch (error) {
      return WorkshopTaskExecutionResult(
        taskId: task.id,
        status: WorkshopTaskStatus.failed,
        message:
            'Unexpected error in local task executor.',
        metadata: <String, dynamic>{
          'executorId': executorId,
          'error': error.toString(),
        },
      );
    }
  }

  WorkshopTaskStatus _statusForBlockedDecision(
    WorkshopTaskExecutionGuardDecision decision,
  ) {
    if (decision.blockReason ==
        WorkshopTaskExecutionBlockReason.approvalRequired) {
      return WorkshopTaskStatus.waitingApproval;
    }

    return WorkshopTaskStatus.failed;
  }

  String? _resolveStagingPath(
    WorkshopTaskExecutionContext context,
  ) {
    final workingDirectory =
        context.workingDirectory?.trim();

    if (workingDirectory != null &&
        workingDirectory.isNotEmpty) {
      return workingDirectory;
    }

    final stagingRoot =
        context.stagingRoot?.trim();

    if (stagingRoot != null &&
        stagingRoot.isNotEmpty) {
      return stagingRoot;
    }

    return null;
  }

  Future<void> _ensureStagingDirectory(
    Directory directory,
  ) async {
    if (await directory.exists()) {
      return;
    }

    if (!createStagingDirectory) {
      throw FileSystemException(
        'Staging directory does not exist.',
        directory.path,
      );
    }

    await directory.create(
      recursive: true,
    );
  }

  String? _validateFileScope(
    WorkshopTaskContract task,
  ) {
    final allowed = task.fileScope.allowed
        .map(_normalizePath)
        .where((path) => path.isNotEmpty)
        .toSet();

    final forbidden = task.fileScope.forbidden
        .map(_normalizePath)
        .where((path) => path.isNotEmpty)
        .toSet();

    final readOnly = task.fileScope.readOnly
        .map(_normalizePath)
        .where((path) => path.isNotEmpty)
        .toSet();

    final allowedForbidden =
        allowed.intersection(forbidden);

    if (allowedForbidden.isNotEmpty) {
      return 'Task file scope contains paths that are both '
          'allowed and forbidden.';
    }

    final allowedReadOnly =
        allowed.intersection(readOnly);

    if (allowedReadOnly.isNotEmpty) {
      return 'Task file scope contains paths that are both '
          'writable and read-only.';
    }

    final forbiddenReadOnly =
        forbidden.intersection(readOnly);

    if (forbiddenReadOnly.isNotEmpty) {
      return 'Task file scope contains paths that are both '
          'forbidden and read-only.';
    }

    return null;
  }

  String _normalizePath(String value) {
    return value
        .trim()
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^\.\/'), '');
  }
}
