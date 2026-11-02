import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'hybrid_checkpoint_ledger.dart';
import 'hybrid_checkpoint_snapshot_store.dart';

/// Immutable user-owned instructions for a single HYBRID execution.
///
/// Results belong to [HybridCheckpointSnapshotStore], not to this plan.
/// The plan is sensitive content: a Cloud handoff still needs explicit consent
/// to the exact outbound text, even if these instructions are stored locally.
final class HybridCheckpointPlan {
  HybridCheckpointPlan({
    required this.executionId,
    required List<String> instructions,
  }) : instructions = List<String>.unmodifiable(instructions) {
    if (executionId.trim().isEmpty ||
        executionId.trim() != executionId ||
        executionId.length > 256 ||
        instructions.isEmpty ||
        instructions.length > 10000 ||
        instructions.any((s) => s.trim().isEmpty)) {
      throw ArgumentError('Invalid HYBRID execution plan');
    }
  }

  static const int schemaVersion = 1;
  final String executionId;
  final List<String> instructions;

  int get totalCheckpoints => instructions.length;

  String instructionFor(int checkpoint) {
    if (checkpoint < 1 || checkpoint > instructions.length) {
      throw RangeError.range(checkpoint, 1, instructions.length);
    }
    return instructions[checkpoint - 1];
  }

  void verifyLedger(HybridCheckpointLedger ledger) {
    if (ledger.executionId != executionId ||
        ledger.totalCheckpoints != totalCheckpoints) {
      throw StateError('HYBRID plan does not match the saved execution');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'executionId': executionId,
        'instructions': instructions,
      };

  factory HybridCheckpointPlan.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    final executionId = json['executionId'];
    final instructions = json['instructions'];
    if (version != schemaVersion ||
        executionId is! String ||
        instructions is! List ||
        instructions.any((x) => x is! String)) {
      throw const FormatException('Invalid HYBRID plan snapshot');
    }
    try {
      return HybridCheckpointPlan(
        executionId: executionId,
        instructions: instructions.cast<String>(),
      );
    } on ArgumentError {
      throw const FormatException('Invalid HYBRID plan content');
    }
  }
}

/// Secure, owner-scoped, immutable plan store.
///
/// This intentionally shares the app's existing secure backend interface,
/// rather than introducing a new SQLite/RAG/Cloud memory store. An owner ID is
/// provided by the authenticated caller; a hash alone is not authentication.
///
/// Plan and ledger are separate protected entries. The caller must persist
/// the immutable plan before the initial empty ledger and load/verify BOTH on
/// recovery. This store is only serialized within one app process: no claims
/// of multi-process CAS, cross-device sync, or crash-atomic multi-key writes.
final class HybridCheckpointPlanStore {
  HybridCheckpointPlanStore({
    required HybridProtectedSnapshotBackend backend,
  }) : _backend = backend;

  static const int maxPlanBytes = 64 * 1024;
  static const String _keyPrefix = 'hybrid_checkpoint_plan_v1_';

  final HybridProtectedSnapshotBackend _backend;
  Future<void> _tail = Future<void>.value();

  Future<void> save({
    required String ownerId,
    required HybridCheckpointPlan plan,
  }) => _serialize(() async {
        final key = _key(ownerId, plan.executionId);
        final payload = jsonEncode(<String, Object?>{
          'ownerFingerprint': _ownerFingerprint(ownerId),
          'plan': plan.toJson(),
        });
        if (utf8.encode(payload).length > maxPlanBytes) {
          throw StateError('HYBRID plan exceeds protected storage limit');
        }
        final existing = await _backend.read(key);
        if (existing != null) {
          if (existing != payload) {
            // An existing plan can never be silently changed, even if a model
            // suggests a different next step after a network interruption.
            _decode(existing, ownerId, plan.executionId);
            throw StateError('HYBRID plan is already committed and immutable');
          }
          return;
        }
        await _backend.write(key, payload);
        if (await _backend.read(key) != payload) {
          throw StateError('HYBRID plan protected readback failed');
        }
      });

  Future<HybridCheckpointPlan?> load({
    required String ownerId,
    required String executionId,
  }) => _serialize(() async {
        final raw = await _backend.read(_key(ownerId, executionId));
        if (raw == null) return null;
        return _decode(raw, ownerId, executionId);
      });

  /// Explicit user-requested removal only. This must not occur on network
  /// failure, model switch, or loss of Cloud access.
  Future<void> delete({
    required String ownerId,
    required String executionId,
  }) => _serialize(() async {
        await _backend.delete(_key(ownerId, executionId));
      });

  static HybridCheckpointPlan _decode(
    String raw,
    String ownerId,
    String executionId,
  ) {
    if (utf8.encode(raw).length > maxPlanBytes) {
      throw const FormatException('Oversized HYBRID plan');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['ownerFingerprint'] != _ownerFingerprint(ownerId) ||
        decoded['plan'] is! Map) {
      throw const FormatException('HYBRID plan owner mismatch');
    }
    final plan = HybridCheckpointPlan.fromJson(
      Map<String, dynamic>.from(decoded['plan'] as Map),
    );
    if (plan.executionId != executionId) {
      throw const FormatException('HYBRID plan execution mismatch');
    }
    return plan;
  }

  static String _ownerFingerprint(String ownerId) =>
      sha256.convert(utf8.encode(ownerId)).toString();

  static String _key(String ownerId, String executionId) {
    if (ownerId.trim().isEmpty ||
        ownerId.trim() != ownerId ||
        ownerId.length > 256 ||
        executionId.trim().isEmpty ||
        executionId.trim() != executionId ||
        executionId.length > 256) {
      throw ArgumentError('Invalid HYBRID plan owner/execution identity');
    }
    return '$_keyPrefix${sha256.convert(
      utf8.encode('$ownerId\u0000$executionId'),
    )}';
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return pending;
  }
}
