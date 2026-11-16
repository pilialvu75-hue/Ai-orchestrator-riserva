import 'dart:async';

import '../workshop_build_lab.dart';
import '../workshop_stable_build_request_provider.dart';
import 'workshop_durable_build_generation_ledger.dart';
import 'workshop_durable_build_preflight.dart';
import 'workshop_durable_final_build_controller.dart';
import 'workshop_durable_orchestrator.dart';

/// Calls a per-generation final-build controller. The caller must construct
/// that controller with logicalBuildId, never the mutable UI request id.
typedef WorkshopDurableSessionAdvance =
    Future<WorkshopDurableFinalBuildAdvance> Function({
  required WorkshopBuildRequest request,
  required String logicalBuildId,
});

/// Opt-in, per-isolate scheduler boundary. It is NOT the production default.
///
/// The same hashed build intent is serialized across instances with the same
/// scheduler scope within one Dart isolate. Start/recover cannot race with
/// terminal ledger updates, and a restarted session uses the persisted v2
/// logical build ID instead of allocating a new one.
///
/// Only a single authority may operate the underlying ledger/orchestrator.
/// The map below is NOT a cross-process/isolate lock. Do not enable this
/// adapter in production until a platform-wide scheduler is proven.
final class WorkshopDurableBuildSessionCoordinator {
  WorkshopDurableBuildSessionCoordinator({
    required WorkshopDurableBuildPreflight preflight,
    required WorkshopDurableBuildGenerationLedger ledger,
    required WorkshopDurableSessionAdvance advance,
    required String schedulerScope,
  })  : _preflight = preflight,
        _ledger = ledger,
        _advance = advance,
        _schedulerScope = _requireScope(schedulerScope);

  static final Map<String, Future<void>> _active = <String, Future<void>>{};

  final WorkshopDurableBuildPreflight _preflight;
  final WorkshopDurableBuildGenerationLedger _ledger;
  final WorkshopDurableSessionAdvance _advance;
  final String _schedulerScope;

  /// Explicit user-authorized NEW generation. Never used as an automatic
  /// retry of an already-active CI workflow.
  Future<WorkshopDurablePreparedBuild> beginNew(
    WorkshopBuildRequest request,
  ) =>
      _serial(request, () => _preflight.beginNew(request));

  /// Restores exactly the persisted source/generation. No implicit recapture,
  /// no new generation, and no network action.
  Future<WorkshopDurablePreparedBuild?> recoverPending(
    WorkshopBuildRequest request,
  ) =>
      _serial(request, () => _preflight.recoverPending(request));

  /// Advances ONE persisted execution step and updates the generation ledger
  /// only after the controller's authoritative terminal checkpoint.
  ///
  /// The delegate may send network requests on the FIRST READY step, so it
  /// must use the frozen-source resolver and the atomic dispatch claim.
  Future<WorkshopDurableFinalBuildAdvance> advancePending(
    WorkshopBuildRequest request,
  ) =>
      _serial(request, () async {
        final prepared = await _preflight.recoverPending(request);
        if (prepared == null) {
          throw StateError('No active durable generation to advance.');
        }
        final id = prepared.reservation.buildId;
        final step = await _advance(request: request, logicalBuildId: id);

        final snapshot = step.snapshot;
        final task = snapshot.tasks['final-build'];
        if (snapshot.projectId != 'durable-final-build:$id' ||
            snapshot.correlationId != id ||
            task == null) {
          throw StateError(
            'Final build returned a checkpoint for another generation.',
          );
        }

        // A different actor may have committed a terminal ledger state while
        // the controller performed I/O. Do not publish a mismatched result.
        final latest = await _ledger.recoverLatest(request);
        if (latest == null ||
            latest.state != WorkshopDurableGenerationState.active ||
            latest.buildId != id ||
            latest.sourceSha256 != prepared.reservation.sourceSha256) {
          throw StateError('Durable generation changed during advance.');
        }

        if (step.disposition == WorkshopDurableFinalBuildDisposition.completed) {
          final result = step.buildResult;
          if (task.state != WorkshopDurableState.completed ||
              result == null ||
              !result.succeeded ||
              !result.hasArtifact ||
              result.testsPassed != true ||
              result.analysisPassed != true ||
              result.formatPassed != true) {
            throw StateError('Cannot commit an unverified completed build.');
          }
          await _ledger.markTerminal(
            request: request,
            expectedBuildId: id,
            succeeded: true,
          );
        } else if (step.disposition ==
                WorkshopDurableFinalBuildDisposition.failed &&
            task.state == WorkshopDurableState.failed) {
          await _ledger.markTerminal(
            request: request,
            expectedBuildId: id,
            succeeded: false,
          );
        } else if (step.disposition ==
                WorkshopDurableFinalBuildDisposition.cancelled &&
            task.state == WorkshopDurableState.cancelled) {
          await _ledger.markTerminal(
            request: request,
            expectedBuildId: id,
            succeeded: false,
          );
        } else if (task.state == WorkshopDurableState.completed ||
            task.state == WorkshopDurableState.failed ||
            task.state == WorkshopDurableState.cancelled) {
          throw StateError(
            'Durable terminal checkpoint does not match controller result.',
          );
        }
        // Retry/backoff/WAITING_EXTERNAL/VALIDATING remain ACTIVE; a caller
        // must reconcile instead of allocating a new generation.
        return step;
      });

  Future<T> _serial<T>(
    WorkshopBuildRequest request,
    Future<T> Function() action,
  ) async {
    final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
    final key = '$_schedulerScope:$intent';
    final previous = _active[key] ?? Future<void>.value();
    final turn = Completer<void>();
    final future = turn.future;
    _active[key] = future;
    await previous;
    try {
      return await action();
    } finally {
      if (identical(_active[key], future)) _active.remove(key);
      turn.complete();
    }
  }

  static String _requireScope(String scope) {
    final normalized = scope.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(scope, 'schedulerScope', 'is required');
    }
    return normalized;
  }
}
