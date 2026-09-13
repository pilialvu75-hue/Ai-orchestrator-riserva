import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

abstract interface class WorkshopLibrarySecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureWorkshopLibrarySecretStorage
    implements WorkshopLibrarySecretStorage {
  FlutterSecureWorkshopLibrarySecretStorage({FlutterSecureStorage? storage})
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

final class WorkshopLibraryGitHubCredentialSnapshot {
  const WorkshopLibraryGitHubCredentialSnapshot({
    required this.configured,
    this.expiresAt,
    this.refreshExpiresAt,
  });

  final bool configured;
  final DateTime? expiresAt;
  final DateTime? refreshExpiresAt;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());
}

final class WorkshopLibraryGitHubCredentialStore {
  WorkshopLibraryGitHubCredentialStore({WorkshopLibrarySecretStorage? storage})
      : _storage = storage ?? FlutterSecureWorkshopLibrarySecretStorage();

  static const String _key = 'ai_orchestrator.workshop.library.github.v1';

  final WorkshopLibrarySecretStorage _storage;

  Future<void> save(WorkshopGitHubUserCredential credential) async {
    if (credential.accessToken.trim().isEmpty) {
      throw const FormatException('GitHub access token cannot be empty.');
    }
    await _storage.write(
      _key,
      jsonEncode(<String, Object?>{
        'version': 1,
        'access_token': credential.accessToken,
        'refresh_token': credential.refreshToken,
        'expires_at': credential.expiresAt?.toUtc().toIso8601String(),
        'refresh_expires_at':
            credential.refreshExpiresAt?.toUtc().toIso8601String(),
      }),
    );
  }

  Future<WorkshopGitHubUserCredential?> load() async {
    final encoded = await _storage.read(_key);
    if (encoded == null || encoded.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded['version'] != 1) return null;
      final accessToken = decoded['access_token']?.toString().trim() ?? '';
      if (accessToken.isEmpty) return null;
      return WorkshopGitHubUserCredential(
        accessToken: accessToken,
        refreshToken: _nullable(decoded['refresh_token']),
        expiresAt: _date(decoded['expires_at']),
        refreshExpiresAt: _date(decoded['refresh_expires_at']),
      );
    } catch (_) {
      return null;
    }
  }

  Future<WorkshopLibraryGitHubCredentialSnapshot> snapshot() async {
    final credential = await load();
    return WorkshopLibraryGitHubCredentialSnapshot(
      configured: credential != null && !credential.isExpired,
      expiresAt: credential?.expiresAt,
      refreshExpiresAt: credential?.refreshExpiresAt,
    );
  }

  Future<void> clear() => _storage.delete(_key);

  static String? _nullable(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static DateTime? _date(Object? value) {
    final normalized = _nullable(value);
    return normalized == null ? null : DateTime.tryParse(normalized)?.toUtc();
  }
}

final class WorkshopGitHubDeviceAuthorization {
  const WorkshopGitHubDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration interval;
}

final class WorkshopGitHubUserCredential {
  const WorkshopGitHubUserCredential({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.refreshExpiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final DateTime? refreshExpiresAt;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());
}

enum WorkshopGitHubDevicePollState {
  authorized,
  authorizationPending,
  slowDown,
  expired,
  accessDenied,
}

final class WorkshopGitHubDevicePollResult {
  const WorkshopGitHubDevicePollResult({
    required this.state,
    this.credential,
    this.minimumInterval,
  });

  final WorkshopGitHubDevicePollState state;
  final WorkshopGitHubUserCredential? credential;
  final Duration? minimumInterval;
}

/// GitHub App user-authentication boundary for the private Module Library.
///
/// It implements GitHub's OAuth Device Flow using only the public GitHub App
/// client id. No GitHub App private key or client secret belongs in the APK.
/// The resulting user token is intended to be persisted through
/// [WorkshopLibraryGitHubCredentialStore] and used only by the Library transport.
final class WorkshopLibraryGitHubAuthClient {
  WorkshopLibraryGitHubAuthClient({
    http.Client? client,
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _now;

  static final Uri _deviceCodeUri =
      Uri.parse('https://github.com/login/device/code');
  static final Uri _accessTokenUri =
      Uri.parse('https://github.com/login/oauth/access_token');

  Future<WorkshopGitHubDeviceAuthorization> requestDeviceAuthorization({
    required String clientId,
  }) async {
    final normalizedClientId = clientId.trim();
    if (normalizedClientId.isEmpty) {
      throw const FormatException('GitHub App client id is required.');
    }

    final response = await _client.post(
      _deviceCodeUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{'client_id': normalizedClientId},
    );
    final body = _jsonObject(response, operation: 'device authorization');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'GitHub device authorization failed with HTTP ${response.statusCode}.',
      );
    }

    final deviceCode = body['device_code']?.toString().trim() ?? '';
    final userCode = body['user_code']?.toString().trim() ?? '';
    final verificationUri = Uri.tryParse(
      body['verification_uri']?.toString().trim() ?? '',
    );
    final expiresIn = _positiveSeconds(body['expires_in'], 'expires_in');
    final interval = _positiveSeconds(body['interval'], 'interval');
    if (deviceCode.isEmpty || userCode.isEmpty || verificationUri == null) {
      throw const FormatException('GitHub device authorization response is incomplete.');
    }
    if (verificationUri.scheme != 'https' ||
        verificationUri.host.toLowerCase() != 'github.com') {
      throw const FormatException('GitHub verification URI is not trusted.');
    }

    return WorkshopGitHubDeviceAuthorization(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      expiresAt: _now().toUtc().add(Duration(seconds: expiresIn)),
      interval: Duration(seconds: interval),
    );
  }

  Future<WorkshopGitHubDevicePollResult> pollDeviceAuthorization({
    required String clientId,
    required String deviceCode,
  }) async {
    final normalizedClientId = clientId.trim();
    final normalizedDeviceCode = deviceCode.trim();
    if (normalizedClientId.isEmpty || normalizedDeviceCode.isEmpty) {
      throw const FormatException('GitHub client id and device code are required.');
    }

    final response = await _client.post(
      _accessTokenUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'client_id': normalizedClientId,
        'device_code': normalizedDeviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );
    final body = _jsonObject(response, operation: 'device token exchange');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'GitHub device token exchange failed with HTTP ${response.statusCode}.',
      );
    }

    final error = body['error']?.toString().trim();
    if (error != null && error.isNotEmpty) {
      return switch (error) {
        'authorization_pending' => const WorkshopGitHubDevicePollResult(
            state: WorkshopGitHubDevicePollState.authorizationPending,
          ),
        'slow_down' => WorkshopGitHubDevicePollResult(
            state: WorkshopGitHubDevicePollState.slowDown,
            minimumInterval: Duration(
              seconds: _optionalPositiveSeconds(body['interval']) ?? 5,
            ),
          ),
        'expired_token' => const WorkshopGitHubDevicePollResult(
            state: WorkshopGitHubDevicePollState.expired,
          ),
        'access_denied' => const WorkshopGitHubDevicePollResult(
            state: WorkshopGitHubDevicePollState.accessDenied,
          ),
        _ => throw FormatException('GitHub device flow failed: $error.'),
      };
    }

    final credential = _credentialFromTokenResponse(body);
    return WorkshopGitHubDevicePollResult(
      state: WorkshopGitHubDevicePollState.authorized,
      credential: credential,
    );
  }

  Future<WorkshopGitHubUserCredential> refresh({
    required String clientId,
    required String refreshToken,
  }) async {
    final normalizedClientId = clientId.trim();
    final normalizedRefreshToken = refreshToken.trim();
    if (normalizedClientId.isEmpty || normalizedRefreshToken.isEmpty) {
      throw const FormatException('GitHub client id and refresh token are required.');
    }
    final response = await _client.post(
      _accessTokenUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'client_id': normalizedClientId,
        'grant_type': 'refresh_token',
        'refresh_token': normalizedRefreshToken,
      },
    );
    final body = _jsonObject(response, operation: 'token refresh');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'GitHub token refresh failed with HTTP ${response.statusCode}.',
      );
    }
    final error = body['error']?.toString().trim();
    if (error != null && error.isNotEmpty) {
      throw FormatException('GitHub token refresh failed: $error.');
    }
    return _credentialFromTokenResponse(body);
  }

  WorkshopGitHubUserCredential _credentialFromTokenResponse(
    Map<String, dynamic> body,
  ) {
    final accessToken = body['access_token']?.toString().trim() ?? '';
    final tokenType = body['token_type']?.toString().trim().toLowerCase() ?? '';
    if (accessToken.isEmpty || tokenType != 'bearer') {
      throw const FormatException('GitHub token response is incomplete.');
    }
    final expiresIn = _optionalPositiveSeconds(body['expires_in']);
    final refreshExpiresIn =
        _optionalPositiveSeconds(body['refresh_token_expires_in']);
    final refreshToken = body['refresh_token']?.toString().trim();
    final now = _now().toUtc();
    return WorkshopGitHubUserCredential(
      accessToken: accessToken,
      refreshToken:
          refreshToken == null || refreshToken.isEmpty ? null : refreshToken,
      expiresAt: expiresIn == null ? null : now.add(Duration(seconds: expiresIn)),
      refreshExpiresAt: refreshExpiresIn == null
          ? null
          : now.add(Duration(seconds: refreshExpiresIn)),
    );
  }

  static Map<String, dynamic> _jsonObject(
    http.Response response, {
    required String operation,
  }) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Converted below to one bounded, non-secret diagnostic error.
    }
    throw FormatException('GitHub $operation returned invalid JSON.');
  }

  static int _positiveSeconds(Object? value, String field) {
    final result = _optionalPositiveSeconds(value);
    if (result == null) {
      throw FormatException('GitHub $field must be a positive integer.');
    }
    return result;
  }

  static int? _optionalPositiveSeconds(Object? value) {
    final int? parsed =
        value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }
}
