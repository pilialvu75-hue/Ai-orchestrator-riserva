import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'hybrid_cloud_disclosure_consent.dart';

/// Device-local, OS-protected principal for an Aivexus single-user install.
///
/// This is NOT a verified Cloud login or a multi-device identity. It only
/// proves that this session can still read the same protected installation
/// secret. It never enables Cloud sending by itself.
final class HybridCloudLocalSession {
  const HybridCloudLocalSession({
    required this.ownerId,
    required this.sessionId,
  });

  final String ownerId;
  final String sessionId;
}

final class HybridCloudLocalIdentity {
  HybridCloudLocalIdentity({required HybridCloudConsentStorage storage})
      : _storage = storage;

  static final HybridCloudLocalIdentity instance =
      HybridCloudLocalIdentity(storage: FlutterSecureCloudConsentStorage());

  static const String _key = 'aivexus.hybrid.local_identity.v1';
  static final RegExp _tokenFormat = RegExp(r'^[A-Za-z0-9_-]{43}$');

  final HybridCloudConsentStorage _storage;
  HybridCloudLocalSession? _active;
  Future<HybridCloudLocalSession>? _pending;

  static String _randomToken(int bytes) {
    final source = Random.secure();
    final values = List<int>.generate(bytes, (_) => source.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '');
  }

  /// Identifies the current installation, not the user of a remote account.
  /// Fail closed on storage errors, invalid tokens or failed read-back.
  Future<HybridCloudLocalSession> openSession() {
    final active = _active;
    if (active != null) return Future.value(active);
    final pending = _pending;
    if (pending != null) return pending;
    final load = _openProtectedSession();
    _pending = load;
    return load.whenComplete(() => _pending = null);
  }

  Future<HybridCloudLocalSession> _openProtectedSession() async {
    var token = await _storage.read(_key);
    if (token == null) {
      token = _randomToken(32);
      await _storage.write(_key, token);
    }
    if (!_tokenFormat.hasMatch(token)) {
      throw StateError('Invalid protected HYBRID installation identity');
    }
    if (await _storage.read(_key) != token) {
      throw StateError('Cannot verify protected HYBRID installation identity');
    }
    final session = HybridCloudLocalSession(
      ownerId: 'device-' + sha256.convert(utf8.encode(token)).toString(),
      sessionId: _randomToken(24),
    );
    _active = session;
    return session;
  }

  /// Re-reads protected storage every time a permission is accessed.
  /// A different installation, ended session or lost secret is never accepted.
  Future<bool> isAuthorized(String ownerId, String sessionId) async {
    final active = _active;
    if (active == null ||
        active.ownerId != ownerId ||
        active.sessionId != sessionId) {
      return false;
    }
    try {
      final current = await _storage.read(_key);
      return current != null &&
          _tokenFormat.hasMatch(current) &&
          'device-' + sha256.convert(utf8.encode(current)).toString() ==
              ownerId;
    } on Object {
      return false;
    }
  }

  void endSession() {
    _active = null;
  }
}
