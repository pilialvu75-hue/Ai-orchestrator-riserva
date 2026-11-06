import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';

/// Executed checkpoint stage. This does NOT authorize Cloud access.
enum HybridCheckpointExecutor { none, local, cloud }

/// Persisted states deliberately exclude "running": reopening the app never
/// resumes a task, sends a Cloud request, or restores an approval implicitly.
enum HybridCheckpointStatus { paused, completed }

/// Metadata-only progress for a multi-step HYBRID job. User prompts, replies,
/// history, secrets, account identities and model text are never persisted.
final class HybridProgressCheckpoint {
  const HybridProgressCheckpoint({
    required this.ownerId,
    required this.sessionId,
    required this.taskId,
    required this.totalSteps,
    required this.completedSteps,
    required this.revision,
    required this.lastExecutor,
    required this.status,
    required this.updatedAt,
  });

  final String ownerId;
  final String sessionId;
  final String taskId;
  final int totalSteps;
  final int completedSteps;
  final int revision;
  final HybridCheckpointExecutor lastExecutor;
  final HybridCheckpointStatus status;
  final DateTime updatedAt;

  bool get canContinue =>
      status == HybridCheckpointStatus.paused &&
      completedSteps < totalSteps;
}

/// OS-protected and authenticated, progress-only HYBRID checkpoint journal.
///
/// Reads require a trusted owner/session authorization callback. All changes
/// are serialized in this Dart isolate and require the expected revision.
/// No method here calls inference, web tools, or any Cloud provider. A prior
/// Cloud approval never grants permission for the next checkpoint.
final class HybridProgressCheckpointJournal {
  HybridProgressCheckpointJournal({
    required HybridCloudConsentStorage storage,
    required Future<bool> Function(String ownerId, String sessionId)
        authorizeOwnerSession,
    DateTime Function()? now,
  })  : _storage = storage,
        _authorizeOwnerSession = authorizeOwnerSession,
        _now = now ?? DateTime.now;

  static const String _version = 'AIVEXUS_HYBRID_PROGRESS_V1';
  static const String _keyPrefix = 'aivexus.hybrid.progress.v1.';
  static const String _secretKey = 'aivexus.hybrid.progress.hmac.v1';
  static final RegExp _identifier = RegExp(r'^[A-Za-z0-9_:.-]{1,128}$');
  static Future<void> _mutationTail = Future<void>.value();

  final HybridCloudConsentStorage _storage;
  final Future<bool> Function(String ownerId, String sessionId)
      _authorizeOwnerSession;
  final DateTime Function() _now;

  /// Starts with zero completed steps and PAUSED status, never running.
  Future<HybridProgressCheckpoint> begin({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required int totalSteps,
  }) => _serialize(() async {
        await _requireAuthorized(ownerId, sessionId, taskId);
        if (totalSteps < 1 || totalSteps > 1000) {
          throw ArgumentError.value(totalSteps, 'totalSteps');
        }
        final key = _recordKey(ownerId, sessionId, taskId);
        // An existing corrupt record also blocks replacement: fail closed.
        if (await _storage.read(key) != null) {
          throw StateError('Checkpoint already exists; explicit deletion required');
        }
        final entry = HybridProgressCheckpoint(
          ownerId: ownerId,
          sessionId: sessionId,
          taskId: taskId,
          totalSteps: totalSteps,
          completedSteps: 0,
          revision: 0,
          lastExecutor: HybridCheckpointExecutor.none,
          status: HybridCheckpointStatus.paused,
          updatedAt: _now().toUtc(),
        );
        await _write(entry);
        return entry;
      });

  /// Metadata is safe to inspect after restart; never auto-resume.
  Future<HybridProgressCheckpoint?> load({
    required String ownerId,
    required String sessionId,
    required String taskId,
  }) => _serialize(() async {
        await _requireAuthorized(ownerId, sessionId, taskId);
        return _read(ownerId, sessionId, taskId);
      });

  /// Commits exactly one completed local/Cloud stage.
  ///
  /// The caller must have already finished that stage and independently
  /// approved any Cloud disclosure. This function never invokes a model.
  Future<HybridProgressCheckpoint> completeStep({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required int expectedRevision,
    required HybridCheckpointExecutor executor,
  }) => _serialize(() async {
        await _requireAuthorized(ownerId, sessionId, taskId);
        if (executor == HybridCheckpointExecutor.none) {
          throw ArgumentError.value(executor, 'executor');
        }
        final current = await _read(ownerId, sessionId, taskId);
        if (current == null || !current.canContinue ||
            current.revision != expectedRevision) {
          throw StateError('Missing, corrupt, finished or stale checkpoint');
        }
        final next = current.completedSteps + 1;
        final updated = HybridProgressCheckpoint(
          ownerId: ownerId,
          sessionId: sessionId,
          taskId: taskId,
          totalSteps: current.totalSteps,
          completedSteps: next,
          revision: current.revision + 1,
          lastExecutor: executor,
          status: next == current.totalSteps
              ? HybridCheckpointStatus.completed
              : HybridCheckpointStatus.paused,
          updatedAt: _now().toUtc(),
        );
        await _write(updated);
        return updated;
      });

  Future<void> remove({
    required String ownerId,
    required String sessionId,
    required String taskId,
  }) => _serialize(() async {
        await _requireAuthorized(ownerId, sessionId, taskId);
        await _storage.delete(_recordKey(ownerId, sessionId, taskId));
      });

  Future<void> _requireAuthorized(
      String ownerId, String sessionId, String taskId) async {
    for (final id in <String>[ownerId, sessionId, taskId]) {
      if (!_identifier.hasMatch(id)) {
        throw ArgumentError('Checkpoint identity must be a bounded opaque ID');
      }
    }
    if (!await _authorizeOwnerSession(ownerId, sessionId)) {
      throw StateError('Checkpoint owner/session authorization denied');
    }
  }

  String _recordKey(String owner, String session, String task) {
    final encoded = utf8.encode(jsonEncode(<String>[owner, session, task]));
    return _keyPrefix + sha256.convert(encoded).toString();
  }

  Future<List<int>?> _macKey({required bool create}) async {
    final previous = await _storage.read(_secretKey);
    if (previous != null) {
      try {
        final bytes = base64.decode(previous);
        if (bytes.length != 32) return null;
        return bytes;
      } catch (_) {
        return null;
      }
    }
    if (!create) return null;
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    await _storage.write(_secretKey, base64.encode(key));
    return key;
  }

  String _mac(List<int> key, String payload) =>
      Hmac(sha256, key).convert(utf8.encode(payload)).toString();

  bool _sameMac(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _write(HybridProgressCheckpoint entry) async {
    final key = await _macKey(create: true);
    if (key == null) {
      throw StateError('Protected checkpoint integrity key is unavailable');
    }
    final scope = _recordKey(entry.ownerId, entry.sessionId, entry.taskId);
    final payload = jsonEncode(<String, Object>{
      'version': _version,
      'scope': scope,
      'total': entry.totalSteps,
      'completed': entry.completedSteps,
      'revision': entry.revision,
      'executor': entry.lastExecutor.name,
      'status': entry.status.name,
      'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
    });
    await _storage.write(scope, jsonEncode(<String, String>{
      'payload': payload,
      'mac': _mac(key, payload),
    }));
  }

  Future<HybridProgressCheckpoint?> _read(
      String owner, String session, String task) async {
    final scope = _recordKey(owner, session, task);
    final encoded = await _storage.read(scope);
    if (encoded == null) return null;
    try {
      final outer = jsonDecode(encoded);
      if (outer is! Map<String, dynamic>) return null;
      final payload = outer['payload'];
      final mac = outer['mac'];
      if (payload is! String || mac is! String) return null;
      final key = await _macKey(create: false);
      if (key == null || !_sameMac(_mac(key, payload), mac)) return null;
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic> ||
          data['version'] != _version ||
          data['scope'] != scope) return null;
      final total = data['total'];
      final complete = data['completed'];
      final revision = data['revision'];
      final executorValue = data['executor'];
      final statusValue = data['status'];
      final timestamp = data['updatedAt'];
      if (total is! int || total < 1 || total > 1000 ||
          complete is! int || complete < 0 || complete > total ||
          revision is! int || revision != complete ||
          timestamp is! String ||
          executorValue is! String || statusValue is! String) return null;
      final executor = HybridCheckpointExecutor.values
          .where((value) => value.name == executorValue).firstOrNull;
      final status = HybridCheckpointStatus.values
          .where((value) => value.name == statusValue).firstOrNull;
      if (executor == null || status == null ||
          (complete == 0) != (executor == HybridCheckpointExecutor.none) ||
          (complete == total) != (status == HybridCheckpointStatus.completed)) {
        return null;
      }
      final updatedAt = DateTime.tryParse(timestamp);
      if (updatedAt == null || !updatedAt.isUtc) return null;
      return HybridProgressCheckpoint(
        ownerId: owner,
        sessionId: session,
        taskId: task,
        totalSteps: total,
        completedSteps: complete,
        revision: revision,
        lastExecutor: executor,
        status: status,
        updatedAt: updatedAt,
      );
    } catch (_) {
      // Never recover progress from a malformed, tampered or partial record.
      return null;
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
