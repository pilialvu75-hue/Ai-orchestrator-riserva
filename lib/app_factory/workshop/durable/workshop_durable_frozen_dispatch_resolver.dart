import '../workshop_build_lab.dart';
import '../workshop_build_source_snapshot.dart';
import 'workshop_durable_build_generation_ledger.dart';
import 'workshop_durable_frozen_source_store.dart';

/// The only source boundary the durable GitHub gateway accepts.
///
/// Callers must explicitly provide this resolver; the gateway has no
/// fallback that captures a mutable project folder during dispatch.
typedef WorkshopDurableSourceResolve = Future<WorkshopBuildSourceSnapshot>
    Function({
  required WorkshopBuildRequest request,
  required String correlationId,
});

/// Loads the **previously persisted** generation + frozen source for a single
/// GitHub dispatch attempt. This component performs no remote I/O and never
/// snapshots the live workspace.
///
/// The scheduler must persist the frozen source first, reserve the generation,
/// then persist the durable external wait before GitHub workflow dispatch.
final class WorkshopDurableFrozenDispatchResolver {
  WorkshopDurableFrozenDispatchResolver({
    required WorkshopDurableBuildGenerationLedger ledger,
    required WorkshopDurableFrozenSourceStore frozenStore,
    required String namespace,
  })  : _ledger = ledger,
        _frozenStore = frozenStore,
        _namespace = namespace.trim() {
    if (_namespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'is required');
    }
  }

  final WorkshopDurableBuildGenerationLedger _ledger;
  final WorkshopDurableFrozenSourceStore _frozenStore;
  final String _namespace;

  Future<WorkshopBuildSourceSnapshot> resolve({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    final reservation = await _ledger.recoverLatest(request);
    if (reservation == null ||
        reservation.state != WorkshopDurableGenerationState.active) {
      throw StateError('No active persisted durable build generation.');
    }

    final prefix = '${reservation.buildId}:attempt:';
    if (!correlationId.startsWith(prefix)) {
      throw StateError('GitHub correlation is not for the active generation.');
    }
    final suffix = correlationId.substring(prefix.length);
    final attempt = int.tryParse(suffix);
    if (attempt == null ||
        attempt < 1 ||
        attempt.toString() != suffix) {
      throw StateError('GitHub correlation has an invalid attempt number.');
    }

    final handle =
        WorkshopDurableFrozenSourceStore.handleFromPersistedDigest(
      request: request,
      sourceSha256: reservation.sourceSha256,
      namespace: _namespace,
    );
    final frozen = await _frozenStore.recover(
      request: request,
      handle: handle,
      namespace: _namespace,
    );
    // A terminal checkpoint or a newer generation may be persisted while
    // this bounded disk read is in progress. Do not return a stale source
    // to the GitHub staging gateway after that state transition.
    final current = await _ledger.recoverLatest(request);
    if (current == null ||
        current.state != WorkshopDurableGenerationState.active ||
        current.buildId != reservation.buildId ||
        current.sourceSha256 != reservation.sourceSha256) {
      throw StateError('Durable generation changed during frozen source read.');
    }
    return frozen;
  }
}
