import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'hybrid_checkpoint_snapshot_store.dart';

/// Owner-scoped, protected intent marker persisted BEFORE any model call.
/// An uncommitted step can have external side effects, even if its stream
/// returns no result. Restart must NOT replay it without fresh approval.
/// Separate entries are not multi-key atomic; after a successful checkpoint a
/// stale marker is safe to clear because the committed ledger is authoritative.
/// This is NOT a cross-process CAS or distributed ownership mechanism.
final class HybridCheckpointAttemptJournal {
  HybridCheckpointAttemptJournal({required HybridProtectedSnapshotBackend backend})
      : _backend = backend;

  final HybridProtectedSnapshotBackend _backend;
  Future<void> _tail = Future<void>.value();

  Future<int?> pendingCheckpoint({
    required String ownerId,
    required String executionId,
  }) => _serialize(() async {
    final raw = await _backend.read(_key(ownerId, executionId));
    return raw == null ? null : _decode(raw, ownerId, executionId);
  });

  /// Same-step retry keeps the existing intent without a deletion gap.
  Future<void> markBeforeInference({
    required String ownerId,
    required String executionId,
    required int checkpoint,
  }) => _serialize(() async {
    if (checkpoint < 1 || checkpoint > 10000) {
      throw ArgumentError.value(checkpoint, 'checkpoint');
    }
    final key = _key(ownerId, executionId);
    final raw = await _backend.read(key);
    if (raw != null) {
      if (_decode(raw, ownerId, executionId) != checkpoint) {
        throw StateError('HYBRID intent belongs to another unresolved step');
      }
      return;
    }
    final value = jsonEncode(<String, Object?>{
      'version': 1,
      'ownerHash': _hash(ownerId),
      'executionId': executionId,
      'checkpoint': checkpoint,
    });
    await _backend.write(key, value);
    if (await _backend.read(key) != value) {
      throw StateError('HYBRID intent save was not confirmed');
    }
  });

  Future<void> clearAfterCommit({
    required String ownerId,
    required String executionId,
    required int completedCount,
  }) => _serialize(() async {
    final key = _key(ownerId, executionId);
    final raw = await _backend.read(key);
    if (raw == null) return;
    if (completedCount < _decode(raw, ownerId, executionId)) {
      throw StateError('Cannot clear uncommitted HYBRID intent');
    }
    await _backend.delete(key);
    if (await _backend.read(key) != null) {
      throw StateError('HYBRID intent deletion was not confirmed');
    }
  });

  static int _decode(String raw, String owner, String executionId) {
    if (raw.length > 2048) {
      throw const FormatException('Oversized HYBRID intent');
    }
    final x = jsonDecode(raw);
    if (x is! Map || x['version'] != 1 ||
        x['ownerHash'] != _hash(owner) || x['executionId'] != executionId ||
        x['checkpoint'] is! int || (x['checkpoint'] as int) < 1 ||
        (x['checkpoint'] as int) > 10000) {
      throw const FormatException('Invalid HYBRID intent');
    }
    return x['checkpoint'] as int;
  }

  static String _hash(String id) => sha256.convert(utf8.encode(id)).toString();

  static String _key(String owner, String executionId) {
    if (owner.isEmpty || owner.trim() != owner || owner.length > 256 ||
        executionId.isEmpty || executionId.trim() != executionId ||
        executionId.length > 256) {
      throw ArgumentError('Invalid owner or execution identity');
    }
    return 'hybrid_intent_v1_${_hash('$owner\u0000$executionId')}';
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return pending;
  }
}
