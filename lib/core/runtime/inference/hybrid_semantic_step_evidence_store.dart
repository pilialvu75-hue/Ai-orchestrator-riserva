import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_progress_checkpoint_journal.dart';

/// An explicit, externally checked result. Never hidden reasoning or a
/// partially streamed answer. The caller is responsible for validating it.
final class HybridVerifiedStepResult {
  const HybridVerifiedStepResult({
    required this.output,
    required this.provenance,
  });

  final String output;
  final String provenance;
}

/// Opt-in, OS-protected receipts for completed HYBRID steps (H49a).
///
/// A receipt is written *before* the H48 progress revision advances. If a
/// crash occurs between the two writes, that receipt is invisible to readers
/// until the caller explicitly reconciles the unfinished operation. Neither
/// reads nor writes start inference, Web tools, or Cloud requests.
/// No API key, Cloud permission, or hidden model reasoning is stored here.
///
/// The H48 journal remains the sole authoritative progress counter.
/// Atomicity across two independent storage keys is NOT claimed.
final class HybridSemanticStepEvidenceStore {
  HybridSemanticStepEvidenceStore({
    required HybridCloudConsentStorage storage,
    required HybridProgressCheckpointJournal journal,
  }) : _storage = storage, _journal = journal;

  static const _prefix = 'aivexus.hybrid.semantic.h49a.';
  static const _secret = 'aivexus.hybrid.semantic.h49a.mac';
  static const _version = 1;
  static const _maxOutputBytes = 8192;
  static const _maxProvenanceBytes = 512;

  final HybridCloudConsentStorage _storage;
  final HybridProgressCheckpointJournal _journal;

  String _key(String owner, String session, String task, int step) =>
      _prefix + sha256.convert(utf8.encode(
        jsonEncode(<Object>[owner, session, task, step]),
      )).toString();

  Future<List<int>> _signingKey({required bool create}) async {
    final saved = await _storage.read(_secret);
    if (saved != null) {
      try {
        final bytes = base64.decode(saved);
        if (bytes.length == 32) return bytes;
      } catch (_) { /* fail closed */ }
      throw StateError('Protected semantic integrity key invalid');
    }
    if (!create) throw StateError('Protected semantic integrity key missing');
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    await _storage.write(_secret, base64.encode(key));
    return key;
  }

  String _mac(List<int> key, String payload) =>
      Hmac(sha256, key).convert(utf8.encode(payload)).toString();

  bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }

  /// Save a verified output and advance H48 once. No implicit provider call.
  /// Orphan receipts from interrupted writes fail closed on conflicting retry.
  Future<HybridProgressCheckpoint> completeVerifiedStep({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required int expectedRevision,
    required HybridCheckpointExecutor executor,
    required HybridVerifiedStepResult result,
  }) async {
    if (executor == HybridCheckpointExecutor.none) {
      throw ArgumentError.value(executor, 'executor');
    }
    final bytes = utf8.encode(result.output);
    final provenanceBytes = utf8.encode(result.provenance);
    if (bytes.isEmpty || bytes.length > _maxOutputBytes ||
        provenanceBytes.isEmpty ||
        provenanceBytes.length > _maxProvenanceBytes) {
      throw ArgumentError('A bounded explicit result and provenance are required');
    }

    final current = await _journal.load(
      ownerId: ownerId, sessionId: sessionId, taskId: taskId);
    if (current == null || !current.canContinue ||
        current.revision != expectedRevision) {
      throw StateError('Stale or missing H48 progress');
    }

    final step = current.completedSteps + 1;
    final key = _key(ownerId, sessionId, taskId, step);
    final payload = jsonEncode(<String, Object>{
      'version': _version,
      'scope': key,
      'step': step,
      'revision': expectedRevision + 1,
      'executor': executor.name,
      'output': result.output,
      'provenance': result.provenance,
    });
    final macKey = await _signingKey(create: true);
    final envelope = jsonEncode(<String, String>{
      'payload': payload,
      'mac': _mac(macKey, payload),
    });

    final existing = await _storage.read(key);
    if (existing != null && existing != envelope) {
      throw StateError('Conflicting or corrupt existing step receipt');
    }
    if (existing == null) await _storage.write(key, envelope);
    // Verify storage acknowledgement before advancing the authoritative H48
    // revision. Durable recovery is still subject to the storage backend.
    if (await _storage.read(key) != envelope) {
      throw StateError('Protected semantic receipt readback failed');
    }

    return _journal.completeStep(
      ownerId: ownerId,
      sessionId: sessionId,
      taskId: taskId,
      expectedRevision: expectedRevision,
      executor: executor,
    );
  }

  /// A receipt never becomes visible unless H48 certifies that stage complete.
  Future<HybridVerifiedStepResult?> loadCompletedStep({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required int step,
  }) async {
    final current = await _journal.load(
      ownerId: ownerId, sessionId: sessionId, taskId: taskId);
    if (current == null || step < 1 || step > current.completedSteps) {
      return null;
    }
    final key = _key(ownerId, sessionId, taskId, step);
    final record = await _storage.read(key);
    if (record == null) return null;
    try {
      final decoded = jsonDecode(record);
      if (decoded is! Map<String, dynamic>) return null;
      final payload = decoded['payload'];
      final signature = decoded['mac'];
      if (payload is! String || signature is! String) return null;
      final macKey = await _signingKey(create: false);
      if (!_same(_mac(macKey, payload), signature)) return null;
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic> ||
          data['version'] != _version ||
          data['scope'] != key ||
          data['step'] != step ||
          data['revision'] != step ||
          data['executor'] is! String ||
          !<String>['local', 'cloud'].contains(data['executor']) ||
          data['output'] is! String ||
          data['provenance'] is! String) return null;
      final output = data['output'] as String;
      final provenance = data['provenance'] as String;
      if (output.isEmpty ||
          utf8.encode(output).length > _maxOutputBytes ||
          provenance.isEmpty ||
          utf8.encode(provenance).length > _maxProvenanceBytes) return null;
      return HybridVerifiedStepResult(
        output: output, provenance: provenance);
    } catch (_) {
      return null;
    }
  }
}
