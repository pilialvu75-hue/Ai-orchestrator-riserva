import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'hybrid_checkpoint_ledger.dart';

/// Protected backing store for short, owner-scoped HYBRID resume snapshots.
///
/// On each platform, production must use an encrypted/OS-protected backend.
/// Unlike the separate Cloud metadata journal, a snapshot contains user text.
/// No plaintext preferences, telemetry, or automatic Cloud replication.
abstract interface class HybridProtectedSnapshotBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Adapter around the application's existing secure-storage dependency.
/// Not yet connected to the production chat runtime.
final class FlutterSecureHybridSnapshotBackend
    implements HybridProtectedSnapshotBackend {
  FlutterSecureHybridSnapshotBackend({FlutterSecureStorage? secureStorage})
      : _storage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Small, versioned persistence boundary. It protects user content and checks
/// that every saved snapshot advances at most one *committed* checkpoint.
///
/// Caller must pass an authenticated owner identity; the hash in the key is
/// not an authentication mechanism. The full saved payload stays in secure
/// storage, not an unencrypted SQLite/SharedPreferences row.
///
/// This is deliberately bounded: long documents belong in a separately
/// encrypted RAG/artifact store, not secure storage. Cross-process/device
/// coordination is outside this component and must be added before syncing.
final class HybridCheckpointSnapshotStore {
  HybridCheckpointSnapshotStore({
    required HybridProtectedSnapshotBackend backend,
  }) : _backend = backend;

  static const int maxSnapshotBytes = 64 * 1024;
  static const int _maxIdentityChars = 256;
  static const String _keyPrefix = 'hybrid_checkpoint_v1_';

  final HybridProtectedSnapshotBackend _backend;
  Future<void> _tail = Future<void>.value();

  Future<void> saveSnapshot({
    required String ownerId,
    required Map<String, Object?> snapshot,
  }) => _serialize(() async {
        final owner = _checkIdentity(ownerId);
        final parsed = HybridCheckpointLedger.fromJson(
          Map<String, dynamic>.from(snapshot),
        );
        final key = _storageKey(owner, parsed.executionId);
        final serialized = jsonEncode(<String, Object?>{
          'ownerFingerprint': _ownerFingerprint(owner),
          'checkpoint': snapshot,
        });
        if (utf8.encode(serialized).length > maxSnapshotBytes) {
          throw StateError('HYBRID checkpoint exceeds protected storage limit');
        }

        final existing = await _backend.read(key);
        if (existing != null) {
          final previous = _decode(existing, parsed.executionId, owner);
          if (parsed.totalCheckpoints != previous.totalCheckpoints) {
            throw StateError('HYBRID plan size cannot change during an execution');
          }
          final before = previous.completed;
          final after = parsed.completed;
          if (after.length < before.length ||
              after.length > before.length + 1) {
            throw StateError('HYBRID checkpoint order is not monotonic');
          }
          for (var i = 0; i < before.length; i++) {
            final oldStep = before[i];
            final newStep = after[i];
            if (oldStep.number != newStep.number ||
                oldStep.attemptId != newStep.attemptId ||
                oldStep.executor != newStep.executor ||
                oldStep.result != newStep.result) {
              throw StateError('Committed HYBRID checkpoint was modified');
            }
          }
          final priorGeneration = previous.toJson()['generation'] as int;
          final nextGeneration = parsed.toJson()['generation'] as int;
          if (nextGeneration < priorGeneration) {
            throw StateError('Stale HYBRID snapshot generation');
          }
          // Idempotent replay is a no-op; do not re-encrypt or rewrite.
          if (after.length == before.length) return;
        } else if (parsed.completedCount != 0) {
          // The empty execution must be durably registered before step 1.
          throw StateError('HYBRID execution has no protected initial checkpoint');
        }

        await _backend.write(key, serialized);
        // Acknowledgement must follow a successful round-trip. A backend
        // failure propagates, so the caller does not claim durable progress.
        if (await _backend.read(key) != serialized) {
          throw StateError('HYBRID protected checkpoint readback failed');
        }
      });

  Future<HybridCheckpointLedger?> load({
    required String ownerId,
    required String executionId,
  }) => _serialize(() async {
        final owner = _checkIdentity(ownerId);
        final id = _checkIdentity(executionId);
        final raw = await _backend.read(_storageKey(owner, id));
        if (raw == null) return null;
        return _decode(raw, id, owner);
      });

  /// Only for explicit user-directed cleanup/forgetting; never automatic
  /// reset on a network error or model change.
  Future<void> delete({
    required String ownerId,
    required String executionId,
  }) => _serialize(() async {
        final key = _storageKey(
          _checkIdentity(ownerId),
          _checkIdentity(executionId),
        );
        await _backend.delete(key);
      });

  static HybridCheckpointLedger _decode(
    String raw,
    String expectedId,
    String expectedOwner,
  ) {
    if (utf8.encode(raw).length > maxSnapshotBytes) {
      throw const FormatException('Oversized HYBRID checkpoint snapshot');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Malformed HYBRID checkpoint snapshot');
    }
    if (decoded['ownerFingerprint'] != _ownerFingerprint(expectedOwner) ||
        decoded['checkpoint'] is! Map) {
      throw const FormatException('HYBRID checkpoint owner mismatch');
    }
    final ledger = HybridCheckpointLedger.fromJson(
      Map<String, dynamic>.from(decoded['checkpoint'] as Map),
    );
    if (ledger.executionId != expectedId) {
      throw const FormatException('HYBRID checkpoint execution mismatch');
    }
    return ledger;
  }

  static String _checkIdentity(String id) {
    if (id.isEmpty ||
        id.trim() != id ||
        id.length > _maxIdentityChars) {
      throw ArgumentError.value(id, 'identity', 'Invalid HYBRID identity');
    }
    return id;
  }

  static String _ownerFingerprint(String owner) =>
      sha256.convert(utf8.encode(owner)).toString();

  static String _storageKey(String owner, String executionId) {
    final bytes = utf8.encode('$owner\u0000$executionId');
    return '$_keyPrefix${sha256.convert(bytes)}';
  }

  // Serializes reads/writes within this instance, including failed writes.
  // Only one store should serve an owner in one process; cross-process CAS
  // requires a transactional adapter, not independent plugin instances.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return pending;
  }
}
