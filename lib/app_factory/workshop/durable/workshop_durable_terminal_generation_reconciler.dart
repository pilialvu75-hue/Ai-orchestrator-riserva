import '../workshop_build_lab.dart';
import 'workshop_durable_build_generation_ledger.dart';
import 'workshop_durable_orchestrator.dart';

/// Reconciles a **persisted** terminal build checkpoint into its generation
/// ledger. This component performs no remote I/O and is NOT production-wired.
///
/// Crash-safe order: verified source persisted -> generation reserved ->
/// external wait persisted -> terminal task checkpoint persisted -> ledger
/// terminal state. If the process dies after the checkpoint and before the
/// ledger write, calling [reconcile] again is safe and idempotent.
///
/// Callers still must enforce a single authoritative scheduler across isolates
/// and processes: the two stores do not offer a distributed transaction.
final class WorkshopDurableTerminalGenerationReconciler {
  WorkshopDurableTerminalGenerationReconciler({
    required WorkshopDurableBuildGenerationLedger ledger,
    required WorkshopDurableOrchestrationStore orchestrationStore,
  })  : _ledger = ledger,
        _orchestrationStore = orchestrationStore;

  final WorkshopDurableBuildGenerationLedger _ledger;
  final WorkshopDurableOrchestrationStore _orchestrationStore;

  /// Returns null only when the correct generation exists but its authoritative
  /// checkpoint has not reached a terminal state. Missing/mismatched/corrupted
  /// checkpoints fail closed and NEVER free a generation for a new build.
  Future<WorkshopDurableBuildReservation?> reconcile({
    required WorkshopBuildRequest request,
    required String expectedBuildId,
  }) async {
    if (request.target != WorkshopBuildTarget.android) {
      throw StateError('Durable terminal reconciliation supports Android only.');
    }
    final reservation = await _ledger.recoverLatest(request);
    if (reservation == null || reservation.buildId != expectedBuildId) {
      throw StateError('Unknown or stale durable build generation.');
    }

    final projectId = 'durable-final-build:${reservation.buildId}';
    // Load from the persisted checkpoint store, NOT a UI/controller snapshot.
    final checkpoint = await _orchestrationStore.load(projectId);
    if (checkpoint == null ||
        checkpoint.projectId != projectId ||
        checkpoint.correlationId != reservation.buildId ||
        checkpoint.tasks.length != 1 ||
        !checkpoint.tasks.containsKey('final-build')) {
      throw StateError('Missing or incompatible durable terminal checkpoint.');
    }
    final task = checkpoint.tasks['final-build']!;
    bool? succeeded;
    switch (task.state) {
      case WorkshopDurableState.completed:
        if (checkpoint.state != WorkshopDurableState.completed ||
            !task.artifactIds.any(
              (id) => id.startsWith('local-apk:') &&
                  id.substring('local-apk:'.length).trim().isNotEmpty,
            )) {
          throw StateError('Completed checkpoint lacks verified APK evidence.');
        }
        succeeded = true;
      case WorkshopDurableState.failed:
      case WorkshopDurableState.cancelled:
        if (checkpoint.state != task.state) {
          throw StateError('Durable terminal task/project state mismatch.');
        }
        succeeded = false;
      default:
        if (reservation.state != WorkshopDurableGenerationState.active) {
          throw StateError('Terminal ledger contradicts a pending checkpoint.');
        }
        return null;
    }

    final expectedState = succeeded
        ? WorkshopDurableGenerationState.succeeded
        : WorkshopDurableGenerationState.failed;
    if (reservation.state != WorkshopDurableGenerationState.active &&
        reservation.state != expectedState) {
      throw StateError('Durable ledger and terminal checkpoint disagree.');
    }
    // The ledger checks expectedBuildId again under its serialized mutation;
    // a newly reserved generation cannot be overwritten by a late callback.
    return _ledger.markTerminal(
      request: request,
      expectedBuildId: expectedBuildId,
      succeeded: succeeded,
    );
  }
}
