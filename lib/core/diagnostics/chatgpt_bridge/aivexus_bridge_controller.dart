import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal runtime lifecycle supported by the authenticated loopback server.
abstract interface class BridgeControlHost {
  bool get isRunning;
  Future<void> start();
  Future<void> stop();
}

abstract interface class BridgeSecretStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

final class SecureBridgeSecretStore implements BridgeSecretStore {
  SecureBridgeSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'aivexus.chatgpt_bridge.local_token.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// User-controlled pairing state for a QA-only, local Windows bridge.
///
/// The token is generated on the device using Random.secure, persisted only
/// in OS-protected storage, and disclosed only when the user explicitly taps
/// Copy pairing key in the UI. Nothing is sent to GitHub or diagnostic logs.
class AivexusBridgeController {
  AivexusBridgeController({
    required this.buildHost,
    required this.allowed,
    BridgeSecretStore? secretStore,
  }) : _secretStore = secretStore ?? SecureBridgeSecretStore();

  final BridgeControlHost Function(String token) buildHost;
  final BridgeSecretStore _secretStore;
  final bool allowed;
  BridgeControlHost? _host;

  bool get isEnabled => _host?.isRunning == true;

  static String _makeToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Startup never resumes access. The user enables the bridge each session.
  Future<void> restore() async {}

  /// One tap: create OS-protected pairing token and start the existing app's
  /// loopback server. When starting fails, remove a newly created token.
  Future<void> enable() async {
    if (!allowed) throw StateError('bridge_not_available_in_this_build');
    if (isEnabled) return;
    final prior = await _secretStore.read();
    final fresh = prior == null || prior.length < 32;
    final token = fresh ? _makeToken() : prior!;
    if (fresh) await _secretStore.write(token);
    try {
      final host = buildHost(token);
      await host.start();
      _host = host;
    } catch (_) {
      if (fresh) await _secretStore.delete();
      rethrow;
    }
  }

  /// Read only after a deliberate user action (for clipboard pairing).
  Future<String?> pairingKeyForExplicitCopy() async {
    if (!isEnabled) return null;
    return _secretStore.read();
  }

  /// Revoke access immediately and remove the OS-protected secret. Any
  /// existing MCP instance becomes unable to access this process.
  Future<void> disable() async {
    if (!allowed) return;
    final old = _host;
    _host = null;
    try {
      await old?.stop();
    } finally {
      // Revocation must still erase credentials if shutdown reports an error.
      await _secretStore.delete();
    }
  }

  /// Generate a new key on explicit user request: invalidates old MCP config.
  Future<void> rotateKey() async {
    await disable();
    await enable();
  }
}
