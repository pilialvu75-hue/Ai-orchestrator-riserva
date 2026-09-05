import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum CloudCredentialKind {
  apiKey,
  oauthAccessToken,
}

class CloudCredentialSnapshot {
  const CloudCredentialSnapshot({
    required this.providerId,
    required this.configured,
    this.kind,
    this.accountId,
    this.expiresAt,
    this.fromEnvironmentFallback = false,
  });

  final String providerId;
  final bool configured;
  final CloudCredentialKind? kind;
  final String? accountId;
  final DateTime? expiresAt;
  final bool fromEnvironmentFallback;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());
}

/// Minimal secret-storage contract so credential behavior can be unit-tested
/// without invoking platform method channels.
abstract interface class CloudSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureCloudSecretStorage implements CloudSecretStorage {
  FlutterSecureCloudSecretStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Secure, dynamic credentials used by Cloud provider adapters.
///
/// Secrets are persisted only through [CloudSecretStorage]. The in-memory
/// cache intentionally exposes synchronous reads to existing datasource and
/// provider-health code after [initialize] has completed during bootstrap.
/// Environment/build-time credentials can be supplied as non-persistent
/// fallbacks for CI/development and are never copied into secure storage.
final class CloudCredentialStore {
  CloudCredentialStore({CloudSecretStorage? storage})
      : _storage = storage ?? FlutterSecureCloudSecretStorage();

  static const String _keyPrefix = 'ai_orchestrator.cloud.credential.v1.';

  final CloudSecretStorage _storage;
  final Map<String, _CloudCredentialRecord> _records =
      <String, _CloudCredentialRecord>{};
  final Map<String, String> _environmentFallbacks = <String, String>{};

  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> initialize({
    Map<String, String> environmentFallbacks = const <String, String>{},
  }) async {
    _environmentFallbacks
      ..clear()
      ..addEntries(
        environmentFallbacks.entries.where(
          (entry) =>
              CloudProviderCatalog.supportedProviders.contains(entry.key) &&
              entry.value.trim().isNotEmpty,
        ),
      );

    _records.clear();

    for (final providerId in CloudProviderCatalog.supportedProviders) {
      final encoded = await _storage.read(_storageKey(providerId));
      if (encoded == null || encoded.trim().isEmpty) {
        continue;
      }

      try {
        final record = _CloudCredentialRecord.decode(encoded);
        if (record.providerId == providerId && record.secret.trim().isNotEmpty) {
          _records[providerId] = record;
        }
      } catch (_) {
        // A corrupt secret entry must not prevent app startup or expose data.
        // It simply behaves as not configured until the user replaces it.
      }
    }

    _initialized = true;
  }

  String? secretFor(String providerId) {
    final record = _records[providerId];
    if (record != null && !record.isExpired) {
      return record.secret;
    }

    final fallback = _environmentFallbacks[providerId]?.trim();
    return fallback == null || fallback.isEmpty ? null : fallback;
  }

  bool hasCredential(String providerId) => secretFor(providerId) != null;

  CloudCredentialSnapshot snapshotFor(String providerId) {
    final record = _records[providerId];
    if (record != null) {
      return CloudCredentialSnapshot(
        providerId: providerId,
        configured: !record.isExpired && record.secret.trim().isNotEmpty,
        kind: record.kind,
        accountId: record.accountId,
        expiresAt: record.expiresAt,
      );
    }

    return CloudCredentialSnapshot(
      providerId: providerId,
      configured: _environmentFallbacks[providerId]?.trim().isNotEmpty ?? false,
      kind: _environmentFallbacks[providerId]?.trim().isNotEmpty ?? false
          ? CloudCredentialKind.apiKey
          : null,
      fromEnvironmentFallback:
          _environmentFallbacks[providerId]?.trim().isNotEmpty ?? false,
    );
  }

  List<CloudCredentialSnapshot> get snapshots =>
      CloudProviderCatalog.supportedProviders
          .map(snapshotFor)
          .toList(growable: false);

  Future<void> setApiKey(
    String providerId,
    String apiKey, {
    String? accountId,
  }) async {
    _validateProvider(providerId);
    final secret = apiKey.trim();
    if (secret.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API key cannot be empty.');
    }

    await _save(
      _CloudCredentialRecord(
        providerId: providerId,
        kind: CloudCredentialKind.apiKey,
        secret: secret,
        accountId: _normalizedNullable(accountId),
      ),
    );
  }

  Future<void> setOAuthAccessToken(
    String providerId,
    String accessToken, {
    String? accountId,
    DateTime? expiresAt,
  }) async {
    _validateProvider(providerId);
    final secret = accessToken.trim();
    if (secret.isEmpty) {
      throw ArgumentError.value(
        accessToken,
        'accessToken',
        'OAuth access token cannot be empty.',
      );
    }

    await _save(
      _CloudCredentialRecord(
        providerId: providerId,
        kind: CloudCredentialKind.oauthAccessToken,
        secret: secret,
        accountId: _normalizedNullable(accountId),
        expiresAt: expiresAt?.toUtc(),
      ),
    );
  }

  Future<void> remove(String providerId) async {
    _validateProvider(providerId);
    _records.remove(providerId);
    _environmentFallbacks.remove(providerId);
    await _storage.delete(_storageKey(providerId));
  }

  Future<void> _save(_CloudCredentialRecord record) async {
    await _storage.write(
      _storageKey(record.providerId),
      record.encode(),
    );
    _records[record.providerId] = record;
  }

  void _validateProvider(String providerId) {
    if (!CloudProviderCatalog.supportedProviders.contains(providerId)) {
      throw ArgumentError.value(
        providerId,
        'providerId',
        'Unsupported Cloud provider.',
      );
    }
  }

  String _storageKey(String providerId) => '$_keyPrefix$providerId';

  String? _normalizedNullable(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

final class _CloudCredentialRecord {
  const _CloudCredentialRecord({
    required this.providerId,
    required this.kind,
    required this.secret,
    this.accountId,
    this.expiresAt,
  });

  final String providerId;
  final CloudCredentialKind kind;
  final String secret;
  final String? accountId;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());

  String encode() => jsonEncode(<String, dynamic>{
        'version': 1,
        'providerId': providerId,
        'kind': kind.name,
        'secret': secret,
        'accountId': accountId,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
      });

  factory _CloudCredentialRecord.decode(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Invalid Cloud credential payload.');
    }

    final data = Map<String, dynamic>.from(decoded);
    if (data['version'] != 1) {
      throw const FormatException('Unsupported Cloud credential version.');
    }

    final providerId = data['providerId']?.toString() ?? '';
    final secret = data['secret']?.toString() ?? '';
    final kindName = data['kind']?.toString() ?? '';

    final kind = CloudCredentialKind.values.where(
      (candidate) => candidate.name == kindName,
    );

    if (providerId.isEmpty || secret.isEmpty || kind.isEmpty) {
      throw const FormatException('Incomplete Cloud credential payload.');
    }

    final expiresAtRaw = data['expiresAt']?.toString();

    return _CloudCredentialRecord(
      providerId: providerId,
      kind: kind.first,
      secret: secret,
      accountId: data['accountId']?.toString(),
      expiresAt: expiresAtRaw == null || expiresAtRaw.isEmpty
          ? null
          : DateTime.tryParse(expiresAtRaw)?.toUtc(),
    );
  }
}
