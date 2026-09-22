import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:http/http.dart' as http;

/// Provider-neutral remote Memory Fabric node backed by the private AIrLab API.
///
/// Android/Desktop code knows only the stable `/v1/memory/*` contract.
/// Supabase, NAS or any future shared backend remain hidden behind AIrLab.
final class AirLabHttpMemoryFabricProvider implements MemoryFabricProvider {
  AirLabHttpMemoryFabricProvider({
    required Uri baseUri,
    required http.Client httpClient,
    String providerId = 'airlab_shared',
    String location = 'cloud',
    String? authToken,
    this.timeout = const Duration(seconds: 8),
  })  : _baseUri = _normalizeBaseUri(baseUri),
        _httpClient = httpClient,
        _authToken = _optional(authToken),
        descriptor = MemoryFabricProviderDescriptor(
          providerId: providerId,
          location: location,
          allowedPrivacy: const <MemoryFabricPrivacyLevel>{
            MemoryFabricPrivacyLevel.public,
            MemoryFabricPrivacyLevel.project,
            MemoryFabricPrivacyLevel.private,
          },
          durable: true,
        );

  final Uri _baseUri;
  final http.Client _httpClient;
  final String? _authToken;
  final Duration timeout;

  @override
  final MemoryFabricProviderDescriptor descriptor;

  @override
  Future<MemoryFabricRecord> write(MemoryFabricRecord record) async {
    _ensureRemoteEligible(record);

    final payload = await _postJson(
      'v1/memory/write',
      Map<String, dynamic>.from(record.toJson()),
    );
    final raw = payload['record'];
    if (raw is! Map) {
      throw const FormatException(
        'AIrLab Memory write response is missing record.',
      );
    }
    return _decodeRemoteRecord(Map<String, dynamic>.from(raw));
  }

  @override
  Future<MemoryFabricRecord?> read(String recordId) async {
    final normalized = recordId.trim();
    if (normalized.isEmpty) return null;

    late final Map<String, dynamic> payload;
    try {
      payload = await _postJson(
        'v1/memory/read',
        <String, dynamic>{'id': normalized},
      );
    } on AirLabMemoryFabricException catch (error) {
      if (error.statusCode == 404 && error.code == 'memory_not_found') {
        return null;
      }
      rethrow;
    }

    final raw = payload['record'];
    if (raw is! Map) {
      throw const FormatException(
        'AIrLab Memory read response is missing record.',
      );
    }
    return _decodeRemoteRecord(Map<String, dynamic>.from(raw));
  }

  @override
  Future<List<MemoryFabricRecord>> search(MemoryFabricQuery query) async {
    final payload = await _postJson(
      'v1/memory/search',
      <String, dynamic>{
        if (_optional(query.namespace) != null)
          'namespace': query.namespace!.trim(),
        if (query.types.isNotEmpty)
          'types': query.types.map((item) => item.wireName).toList(),
        if (_optional(query.text) != null) 'text': query.text!.trim(),
        if (_optional(query.subject) != null)
          'subject': query.subject!.trim(),
        if (query.tags.isNotEmpty) 'tags': query.tags,
        if (_optional(query.projectId) != null)
          'project_id': query.projectId!.trim(),
        if (_optional(query.userId) != null) 'user_id': query.userId!.trim(),
        if (_optional(query.agentId) != null)
          'agent_id': query.agentId!.trim(),
        if (_optional(query.conversationId) != null)
          'conversation_id': query.conversationId!.trim(),
        if (query.updatedAfter != null)
          'updated_after': query.updatedAfter!.toUtc().toIso8601String(),
        if (query.updatedBefore != null)
          'updated_before': query.updatedBefore!.toUtc().toIso8601String(),
        'include_expired': query.includeExpired,
        'limit': query.limit,
      },
    );

    final rawRecords = payload['records'];
    if (rawRecords is! List) {
      throw const FormatException(
        'AIrLab Memory search response must contain records.',
      );
    }

    final records = <MemoryFabricRecord>[];
    for (final raw in rawRecords) {
      if (raw is! Map) {
        throw const FormatException(
          'AIrLab Memory search returned an invalid record.',
        );
      }
      records.add(_decodeRemoteRecord(Map<String, dynamic>.from(raw)));
    }
    return List<MemoryFabricRecord>.unmodifiable(records);
  }

  @override
  Future<MemoryFabricSyncReport> sync() async {
    try {
      final payload = await _postJson(
        'v1/memory/sync',
        const <String, dynamic>{},
      );
      final rawReports = payload['reports'];
      if (rawReports is! List) {
        throw const FormatException(
          'AIrLab Memory sync response must contain reports.',
        );
      }

      var pulled = 0;
      var pushed = 0;
      var conflicts = 0;
      var allOk = rawReports.isNotEmpty;
      final reports = <Map<String, Object?>>[];

      for (final raw in rawReports) {
        if (raw is! Map) {
          throw const FormatException(
            'AIrLab Memory sync returned an invalid report.',
          );
        }
        final report = Map<String, dynamic>.from(raw);
        final ok = report['ok'] == true;
        allOk = allOk && ok;
        pulled += _nonNegativeInt(report['pulled']);
        pushed += _nonNegativeInt(report['pushed']);
        conflicts += _nonNegativeInt(report['conflicts']);
        reports.add(
          <String, Object?>{
            'provider_id': report['provider_id']?.toString(),
            'ok': ok,
            'pulled': _nonNegativeInt(report['pulled']),
            'pushed': _nonNegativeInt(report['pushed']),
            'conflicts': _nonNegativeInt(report['conflicts']),
          },
        );
      }

      return MemoryFabricSyncReport(
        providerId: descriptor.providerId,
        ok: allOk,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        details: <String, Object?>{
          'remote_reports': reports,
        },
      );
    } on Object catch (error) {
      return MemoryFabricSyncReport(
        providerId: descriptor.providerId,
        ok: false,
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  @override
  Future<MemoryFabricHealth> health() async {
    final checkedAt = DateTime.now().toUtc();
    try {
      final payload = await _getJson('v1/memory/health');
      final rawProviders = payload['providers'];
      if (rawProviders is! List || rawProviders.isEmpty) {
        return MemoryFabricHealth(
          providerId: descriptor.providerId,
          status: MemoryFabricHealthStatus.unavailable,
          readable: false,
          writable: false,
          checkedAt: checkedAt,
          details: const <String, Object?>{
            'reason': 'AIrLab Memory returned no providers.',
          },
        );
      }

      var readable = false;
      var writable = false;
      var healthyCount = 0;
      var unavailableCount = 0;
      final providers = <Map<String, Object?>>[];

      for (final raw in rawProviders) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final status = item['status']?.toString();
        final itemReadable = item['readable'] == true;
        final itemWritable = item['writable'] == true;
        readable = readable || itemReadable;
        writable = writable || itemWritable;
        if (status == 'healthy') healthyCount++;
        if (status == 'unavailable') unavailableCount++;
        providers.add(
          <String, Object?>{
            'provider_id': item['provider_id']?.toString(),
            'status': status,
            'readable': itemReadable,
            'writable': itemWritable,
          },
        );
      }

      final status = !readable && !writable
          ? MemoryFabricHealthStatus.unavailable
          : unavailableCount > 0 || healthyCount < providers.length
              ? MemoryFabricHealthStatus.degraded
              : MemoryFabricHealthStatus.healthy;

      return MemoryFabricHealth(
        providerId: descriptor.providerId,
        status: status,
        readable: readable,
        writable: writable,
        checkedAt: checkedAt,
        details: <String, Object?>{
          'remote_providers': providers,
        },
      );
    } on Object catch (error) {
      return MemoryFabricHealth(
        providerId: descriptor.providerId,
        status: MemoryFabricHealthStatus.unavailable,
        readable: false,
        writable: false,
        checkedAt: checkedAt,
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  void _ensureRemoteEligible(MemoryFabricRecord record) {
    if (!record.checksumValid) {
      throw const FormatException(
        'Memory record checksum is invalid.',
      );
    }
    if (!descriptor.allowedPrivacy.contains(record.privacyLevel)) {
      throw MemoryFabricRemotePrivacyException(record.privacyLevel);
    }
  }

  MemoryFabricRecord _decodeRemoteRecord(Map<String, dynamic> raw) {
    final record = MemoryFabricRecord.fromJson(
      Map<String, Object?>.from(raw),
    );
    if (!record.checksumValid) {
      throw const FormatException(
        'AIrLab Memory returned an invalid checksum.',
      );
    }
    if (!descriptor.allowedPrivacy.contains(record.privacyLevel)) {
      throw MemoryFabricRemotePrivacyException(record.privacyLevel);
    }
    return record;
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    try {
      final response = await _httpClient
          .get(_baseUri.resolve(path), headers: _headers())
          .timeout(timeout);
      return _decode(response);
    } on TimeoutException {
      throw const AirLabMemoryFabricException(
        'AIrLab Memory request timed out.',
        code: 'transport_timeout',
      );
    } on http.ClientException catch (error) {
      throw AirLabMemoryFabricException(
        'AIrLab Memory request is unavailable: ${error.message}',
        code: 'transport_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _httpClient
          .post(
            _baseUri.resolve(path),
            headers: _headers(contentTypeJson: true),
            body: jsonEncode(payload),
          )
          .timeout(timeout);
      return _decode(response);
    } on TimeoutException {
      throw const AirLabMemoryFabricException(
        'AIrLab Memory request timed out.',
        code: 'transport_timeout',
      );
    } on http.ClientException catch (error) {
      throw AirLabMemoryFabricException(
        'AIrLab Memory request is unavailable: ${error.message}',
        code: 'transport_unavailable',
      );
    }
  }

  Map<String, String> _headers({bool contentTypeJson = false}) =>
      <String, String>{
        'Accept': 'application/json',
        if (contentTypeJson) 'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  Map<String, dynamic> _decode(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const FormatException(
        'AIrLab Memory response is not valid JSON.',
      );
    }
    if (decoded is! Map) {
      throw const FormatException(
        'AIrLab Memory response must be a JSON object.',
      );
    }
    final payload = Map<String, dynamic>.from(decoded);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = payload['error']?.toString() ?? 'memory_request_failed';
      throw AirLabMemoryFabricException(
        error,
        statusCode: response.statusCode,
        code: error,
      );
    }
    return payload;
  }

  static Uri _normalizeBaseUri(Uri value) {
    final text = value.toString();
    return text.endsWith('/') ? value : Uri.parse('$text/');
  }
}

final class AirLabMemoryFabricException implements Exception {
  const AirLabMemoryFabricException(
    this.message, {
    this.statusCode,
    this.code,
  });

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() =>
      'AirLabMemoryFabricException($statusCode, $code, $message)';
}

final class MemoryFabricRemotePrivacyException implements Exception {
  const MemoryFabricRemotePrivacyException(this.privacyLevel);

  final MemoryFabricPrivacyLevel privacyLevel;

  @override
  String toString() =>
      'Memory privacy ${privacyLevel.wireName} cannot use a remote node.';
}

String? _optional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int _nonNegativeInt(Object? value) {
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
  return parsed < 0 ? 0 : parsed;
}
