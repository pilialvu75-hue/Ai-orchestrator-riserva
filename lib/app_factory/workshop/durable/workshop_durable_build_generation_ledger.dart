import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

import '../workshop_build_lab.dart';
import '../workshop_build_source_snapshot.dart';
import '../workshop_stable_build_request_provider.dart';
import 'workshop_durable_build_identity.dart';

/// A durable generation is allocated only for an explicit NEW build request.
/// Foreground cancellation does not change this state or stop GitHub work.
enum WorkshopDurableGenerationState { active, succeeded, failed }

final class WorkshopDurableBuildReservation {
  const WorkshopDurableBuildReservation({
    required this.intentId,
    required this.buildId,
    required this.sourceSha256,
    required this.generation,
    required this.state,
  });

  final String intentId;
  final String buildId;
  final String sourceSha256;
  final int generation;
  final WorkshopDurableGenerationState state;

  WorkshopDurableBuildReservation withState(
    WorkshopDurableGenerationState next,
  ) =>
      WorkshopDurableBuildReservation(
        intentId: intentId,
        buildId: buildId,
        sourceSha256: sourceSha256,
        generation: generation,
        state: next,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'intent': intentId,
        'buildId': buildId,
        'sourceSha256': sourceSha256,
        'generation': generation,
        'state': state.name,
      };
}

/// Preferences-backed generation reservation, deliberately NOT wired into
/// production dispatch. It stores ONLY hashes and counters, never files,
/// credentials, prompts or project paths.
///
/// The caller must first persist a frozen and independently verified source
/// snapshot, then call reserveNew(), then persist the durable orchestrator's
/// WAITING_EXTERNAL state before any GitHub side effect. Without that atomic
/// source snapshot, a reserved identity must NOT be used for remote dispatch.
///
/// A single serialized queue protects all instances within one Dart isolate.
/// Cross-isolate/process coordination is not provided by SharedPreferences;
/// production wiring must enforce a single scheduler authority.
final class WorkshopDurableBuildGenerationLedger {
  WorkshopDurableBuildGenerationLedger({required PreferencesService preferences})
      : _preferences = preferences;

  static const String storageKey = 'workshop.durable.generations.v1';
  static const int _maxIntents = 10000;
  static Future<void> _mutationTail = Future<void>.value();

  final PreferencesService _preferences;

  /// Refuses to allocate a second generation while the previous durable
  /// execution remains active. Reopen via recoverLatest() instead.
  Future<WorkshopDurableBuildReservation> reserveNew({
    required WorkshopBuildRequest request,
    required WorkshopBuildSourceSnapshot source,
  }) =>
      _serialize(() async {
        final all = _read();
        final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
        final previous = all[intent];
        if (previous?.state == WorkshopDurableGenerationState.active) {
          throw StateError(
            'A durable build is still active; recover its saved identity.',
          );
        }
        if (previous == null && all.length >= _maxIntents) {
          throw StateError('Durable build generation ledger is full.');
        }
        final generation = (previous?.generation ?? 0) + 1;
        if (generation > 2147483647) {
          throw StateError('Durable build generation counter exhausted.');
        }
        final reservation = WorkshopDurableBuildReservation(
          intentId: intent,
          buildId: WorkshopDurableBuildIdentity.forBuild(
            request: request,
            snapshot: source,
            generation: generation,
          ),
          sourceSha256: WorkshopDurableBuildIdentity.sourceDigest(source),
          generation: generation,
          state: WorkshopDurableGenerationState.active,
        );
        all[intent] = reservation;
        await _write(all);
        return reservation;
      });

  /// Does not recapture the current workspace: source files may have changed
  /// since the remote build was dispatched. Returns the saved identity to a
  /// future frozen-source recovery boundary.
  Future<WorkshopDurableBuildReservation?> recoverLatest(
    WorkshopBuildRequest request,
  ) =>
      _serialize(() async {
        final all = _read();
        return all[WorkshopStableBuildRequestIdentity.forRequest(request)];
      });

  /// Call only AFTER the corresponding authoritative durable terminal
  /// checkpoint has been persisted. Late results for an older generation are
  /// rejected rather than overwriting the current execution's state.
  Future<WorkshopDurableBuildReservation> markTerminal({
    required WorkshopBuildRequest request,
    required String expectedBuildId,
    required bool succeeded,
  }) =>
      _serialize(() async {
        final all = _read();
        final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
        final current = all[intent];
        if (current == null || current.buildId != expectedBuildId) {
          throw StateError('Unknown or stale durable build generation.');
        }
        final nextState = succeeded
            ? WorkshopDurableGenerationState.succeeded
            : WorkshopDurableGenerationState.failed;
        if (current.state == nextState) return current;
        if (current.state != WorkshopDurableGenerationState.active) {
          throw StateError('Durable generation terminal status conflicts.');
        }
        final completed = current.withState(nextState);
        all[intent] = completed;
        await _write(all);
        return completed;
      });

  Map<String, WorkshopDurableBuildReservation> _read() {
    final raw = _preferences.getString(storageKey);
    if (raw == null) return <String, WorkshopDurableBuildReservation>{};
    try {
      final root = jsonDecode(raw);
      if (root is! Map || root['schema'] != 1 ||
          root['records'] is! Map) {
        throw const FormatException('Invalid durable generation schema.');
      }
      final entries = root['records'] as Map;
      if (entries.length > _maxIntents) {
        throw const FormatException('Durable generation ledger exceeds limit.');
      }
      final output = <String, WorkshopDurableBuildReservation>{};
      for (final entry in entries.entries) {
        final key = entry.key;
        final data = entry.value;
        if (key is! String || data is! Map) {
          throw const FormatException('Invalid durable generation entry.');
        }
        final intent = data['intent'];
        final buildId = data['buildId'];
        final source = data['sourceSha256'];
        final generation = data['generation'];
        final rawState = data['state'];
        if (intent is! String || intent != key ||
            !RegExp(r'^build-v1-[a-f0-9]{32}$').hasMatch(intent) ||
            buildId is! String ||
            !RegExp(r'^durable-v2-[a-f0-9]{40}$').hasMatch(buildId) ||
            source is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(source) ||
            generation is! int || generation < 1 ||
            generation > 2147483647 || rawState is! String) {
          throw const FormatException('Invalid durable generation identity.');
        }
        final digest = sha256.convert(utf8.encode(
          'workshop-durable-build-v2:' +
          intent + ':' + source + ':' + generation.toString(),
        )).toString();
        if (buildId != 'durable-v2-' + digest.substring(0, 40)) {
          throw const FormatException('Durable generation digest mismatch.');
        }
        final state = switch (rawState) {
          'active' => WorkshopDurableGenerationState.active,
          'succeeded' => WorkshopDurableGenerationState.succeeded,
          'failed' => WorkshopDurableGenerationState.failed,
          _ => throw const FormatException('Invalid durable generation state.'),
        };
        output[intent] = WorkshopDurableBuildReservation(
          intentId: intent,
          buildId: buildId,
          sourceSha256: source,
          generation: generation,
          state: state,
        );
      }
      return output;
    } catch (_) {
      // Never silently reset an invalid journal: that could reuse generation 1
      // and duplicate a remote workflow that is still running.
      throw StateError(
        'Durable generation ledger is invalid; refusing to reallocate.',
      );
    }
  }

  Future<void> _write(
    Map<String, WorkshopDurableBuildReservation> entries,
  ) async {
    final encoded = jsonEncode(<String, Object?>{
      'schema': 1,
      'records': <String, Object?>{
        for (final entry in entries.entries) entry.key: entry.value.toJson(),
      },
    });
    await _preferences.setString(storageKey, encoded);
    if (_preferences.getString(storageKey) != encoded) {
      throw StateError('Durable generation write could not be verified.');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
