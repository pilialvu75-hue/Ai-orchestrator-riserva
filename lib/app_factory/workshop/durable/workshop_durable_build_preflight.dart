import 'package:path/path.dart' as p;

import '../workshop_build_lab.dart';
import '../workshop_build_source_snapshot.dart';
import 'workshop_durable_build_generation_ledger.dart';
import 'workshop_durable_frozen_source_store.dart';

typedef WorkshopDurableSourceCapture =
    Future<WorkshopBuildSourceSnapshot> Function(String workspacePath);

/// Non-authoritative, no-network preparation metadata. The final dispatch
/// gateway must reload the frozen bytes and persist WAITING_EXTERNAL before
/// performing any remote side effect.
final class WorkshopDurablePreparedBuild {
  const WorkshopDurablePreparedBuild({
    required this.reservation,
    required this.sourceHandle,
  });

  final WorkshopDurableBuildReservation reservation;
  final WorkshopDurableFrozenSourceHandle sourceHandle;
}

/// Prepares and recovers durable Android builds WITHOUT dispatching workflows.
///
/// It is deliberately not connected to the Cantiere production factory.
/// Callers must provide a single scheduler authority and an app-private root;
/// both the ledger and frozen source store have only per-isolate serialization.
/// `beginNew` is for explicit owner-approved new builds. `recoverPending`
/// never recaptures the current workspace or reallocates a generation.
///
/// A future remote gateway must consume the bytes returned by
/// `loadFrozenForDispatch` instead of calling Snapshotter.capture again.
final class WorkshopDurableBuildPreflight {
  WorkshopDurableBuildPreflight({
    required WorkshopDurableBuildGenerationLedger ledger,
    required WorkshopDurableFrozenSourceStore frozenSources,
    required WorkshopDurableSourceCapture capture,
    required String namespace,
  })  : _ledger = ledger,
        _frozenSources = frozenSources,
        _capture = capture,
        _namespace = _nonEmptyNamespace(namespace);

  final WorkshopDurableBuildGenerationLedger _ledger;
  final WorkshopDurableFrozenSourceStore _frozenSources;
  final WorkshopDurableSourceCapture _capture;
  final String _namespace;

  Future<WorkshopDurablePreparedBuild> beginNew(
    WorkshopBuildRequest request,
  ) async {
    _requireAndroid(request);
    // Reject an in-flight intent before capturing or persisting any new
    // source files. The ledger still enforces this atomically at reserveNew().
    final existing = await _ledger.recoverLatest(request);
    if (existing?.state == WorkshopDurableGenerationState.active) {
      throw StateError('A durable build is still active; recover it first.');
    }
    final candidate = await _capture(request.projectPath);
    _validateSource(candidate, request);
    // Freeze and verify the exact bytes BEFORE reserving any generation.
    final handle = await _frozenSources.persist(
      request: request,
      source: candidate,
      namespace: _namespace,
    );
    final frozen = await _frozenSources.recover(
      request: request,
      handle: handle,
      namespace: _namespace,
    );
    _validateSource(frozen, request);
    final ticket = await _ledger.reserveNew(
      request: request,
      source: frozen,
    );
    if (ticket.sourceSha256 != handle.sourceSha256) {
      throw StateError('Frozen source and ledger identity mismatch.');
    }
    return WorkshopDurablePreparedBuild(
      reservation: ticket,
      sourceHandle: handle,
    );
  }

  Future<WorkshopDurablePreparedBuild?> recoverPending(
    WorkshopBuildRequest request,
  ) async {
    _requireAndroid(request);
    final saved = await _ledger.recoverLatest(request);
    if (saved == null ||
        saved.state != WorkshopDurableGenerationState.active) {
      return null;
    }
    final handle =
        WorkshopDurableFrozenSourceStore.handleFromPersistedDigest(
      request: request,
      sourceSha256: saved.sourceSha256,
      namespace: _namespace,
    );
    // Refuse recovery when the source archive has been removed/tampered with:
    // never replay a running generation against the edited workspace.
    final frozen = await _frozenSources.recover(
      request: request,
      handle: handle,
      namespace: _namespace,
    );
    _validateSource(frozen, request);
    return WorkshopDurablePreparedBuild(
      reservation: saved,
      sourceHandle: handle,
    );
  }

  Future<WorkshopBuildSourceSnapshot> loadFrozenForDispatch({
    required WorkshopBuildRequest request,
    required WorkshopDurablePreparedBuild prepared,
  }) async {
    _requireAndroid(request);
    final active = await _ledger.recoverLatest(request);
    if (active == null ||
        active.state != WorkshopDurableGenerationState.active ||
        active.buildId != prepared.reservation.buildId ||
        active.sourceSha256 != prepared.sourceHandle.sourceSha256) {
      throw StateError('Stale or terminal durable build reservation.');
    }
    final frozen = await _frozenSources.recover(
      request: request,
      handle: prepared.sourceHandle,
      namespace: _namespace,
    );
    _validateSource(frozen, request);
    return frozen;
  }

  static void _validateSource(
    WorkshopBuildSourceSnapshot source,
    WorkshopBuildRequest request,
  ) {
    // Do not freeze a snapshot from a DIFFERENT workspace than the
    // user-approved build request, even with an injected capture callback.
    final capturedRoot = p.normalize(p.absolute(source.rootPath));
    final requestedRoot = p.normalize(p.absolute(request.projectPath));
    if (!p.equals(capturedRoot, requestedRoot)) {
      throw StateError('Frozen build source workspace does not match request.');
    }
    final error = WorkshopAndroidBuildSourceBoundary.validate(source);
    if (error != null) throw StateError(error);
  }

  static void _requireAndroid(WorkshopBuildRequest request) {
    if (request.target != WorkshopBuildTarget.android) {
      throw StateError('Durable Cantiere preflight currently supports Android.');
    }
  }

  static String _nonEmptyNamespace(String namespace) {
    final value = namespace.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'is required');
    }
    return value;
  }
}
