import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';

/// Binary storage is independent of project JSON and of any CAD/game runner.
abstract interface class AivexusBlobStorage {
  Future<void> putIfAbsent(String sha256, Uint8List bytes);
  Future<Uint8List?> read(String sha256);
}

final class AivexusAttachmentStore {
  AivexusAttachmentStore(this._storage, {this.maxBytes = 64 * 1024 * 1024});

  final AivexusBlobStorage _storage;
  final int maxBytes;

  Future<Map<String, Object?>> put({
    required Uint8List bytes,
    required String name,
    required String role,
    required String mimeType,
  }) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw StateError(
        'Allegato vuoto o superiore al limite di $maxBytes byte.',
      );
    }
    final copy = Uint8List.fromList(bytes);
    final digest = sha256.convert(copy).toString();
    final reference = <String, Object?>{
      'ref': 'sha256:$digest',
      'name': name,
      'role': role,
      'mimeType': mimeType,
      'sizeBytes': copy.length,
      'sha256': digest,
    };
    validateAivexusInput(reference);
    await _storage.putIfAbsent(digest, copy);
    // A producer receipt is not evidence that the persisted bytes are intact.
    await readVerified(reference);
    return reference;
  }

  Future<Uint8List> readVerified(Map<String, Object?> reference) async {
    validateAivexusInput(reference);
    final digest = reference['sha256']! as String;
    if (reference['ref'] != 'sha256:$digest') {
      throw StateError('Riferimento allegato non supportato.');
    }
    final bytes = await _storage.read(digest);
    if (bytes == null ||
        bytes.length != reference['sizeBytes'] ||
        sha256.convert(bytes).toString() != digest) {
      throw StateError('Allegato mancante o verifica SHA-256 fallita.');
    }
    return Uint8List.fromList(bytes);
  }
}

/// Explicit test adapter; production Web uses the persistent IndexedDB adapter.
final class InMemoryAivexusBlobStorage implements AivexusBlobStorage {
  final Map<String, Uint8List> _blobs = <String, Uint8List>{};

  @override
  Future<void> putIfAbsent(String digest, Uint8List bytes) async {
    _blobs.putIfAbsent(digest, () => Uint8List.fromList(bytes));
  }

  @override
  Future<Uint8List?> read(String digest) async {
    final bytes = _blobs[digest];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }
}
