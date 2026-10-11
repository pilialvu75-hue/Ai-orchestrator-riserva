import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'aivexus_project_extension.dart';

/// Persisted request/result hooks for Cantiere jobs, not a second job runner.
final class AivexusResourceExchange {
  AivexusResourceExchange._(this._encoded);

  factory AivexusResourceExchange.request(Map<String, Object?> request) =>
      AivexusResourceExchange.read(<String, Object?>{
        'recordRevision': 0,
        'request': request,
        'result': null,
      });

  factory AivexusResourceExchange.read(Object? value) {
    final encoded = jsonEncode(value);
    final data = aivexusObject(jsonDecode(encoded), const [
      'recordRevision',
      'request',
      'result',
    ]);
    aivexusRequire(
      data['recordRevision'] is int && (data['recordRevision'] as int) >= 0,
      'recordRevision',
    );
    aivexusRequire(data['request'] is Map, 'request');
    final request = Map<String, dynamic>.from(data['request'] as Map);
    for (final key in const [
      'requestId',
      'requesterProjectId',
      'producerDomain',
      'consumerDomain',
      'requestedRole',
      'requestedFormat',
      'jobRef',
    ]) {
      _text(request[key], key);
    }
    _revision(request['requesterSpecRevision']);
    aivexusRequire(request['requirements'] is Map, 'requirements');
    final license = request['licenseRequirement'];
    aivexusRequire(
      (license is String && license.trim().isNotEmpty) ||
          (license is Map && license.isNotEmpty),
      'licenseRequirement',
    );
    aivexusRequire(request['sourceRefs'] is List, 'sourceRefs');
    for (final source in request['sourceRefs'] as List) {
      aivexusRequire(source is Map, 'sourceRef');
      _text((source as Map)['ref'], 'sourceRef.ref');
      _hash(source['sha256']);
    }
    aivexusRequire(_transitions.containsKey(request['status']), 'status');
    for (final key in ['createdAt', 'updatedAt']) {
      aivexusRequire(
        request[key] is String &&
            DateTime.tryParse(request[key] as String) != null,
        key,
      );
    }
    final result = data['result'];
    if (request['status'] == 'produced') {
      aivexusRequire(result is Map, 'produced result');
      final produced = result as Map;
      for (final key in [
        'requestId',
        'producerProjectId',
        'artifactRef',
        'role',
        'format',
        'mimeType',
        'licenseRef',
      ]) {
        _text(produced[key], key);
      }
      aivexusRequire(
        produced['requestId'] == request['requestId'],
        'result requestId',
      );
      aivexusRequire(
        produced['role'] == request['requestedRole'] &&
            produced['format'] == request['requestedFormat'],
        'result role/format',
      );
      _revision(produced['producerSpecRevision']);
      _revision(produced['sizeBytes']);
      _hash(produced['sha256']);
      aivexusRequire(
        produced['result'] == 'produced',
        'produced result status',
      );
      aivexusRequire(
        produced['provenance'] is Map ||
            (produced['provenance'] is String &&
                (produced['provenance'] as String).isNotEmpty),
        'provenance',
      );
      aivexusRequire(produced['transformations'] is List, 'transformations');
      final generator = aivexusObject(produced['generator'], const [
        'name',
        'version',
        'jobRef',
      ]);
      for (final value in generator.values) {
        _text(value, 'generator');
      }
      aivexusRequire(produced['validationRefs'] is List, 'validationRefs');
      for (final ref in produced['validationRefs'] as List) {
        _text(ref, 'validationRef');
      }
    } else {
      aivexusRequire(
        result == null,
        'Non-produced request cannot contain an artifact',
      );
      if (const ['rejected', 'unavailable'].contains(request['status'])) {
        _text(request['reasonCode'], 'reasonCode');
      }
    }
    return AivexusResourceExchange._(encoded);
  }

  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  Map<String, dynamic> get request =>
      Map<String, dynamic>.from(toJson()['request'] as Map);
  Map<String, dynamic>? get result {
    final raw = toJson()['result'];
    return raw == null ? null : Map<String, dynamic>.from(raw as Map);
  }

  String get requestId => request['requestId'] as String;
  String get requesterProjectId => request['requesterProjectId'] as String;
  int get requesterSpecRevision => request['requesterSpecRevision'] as int;
  int get recordRevision => toJson()['recordRevision'] as int;
  String get status => request['status'] as String;

  /// Timestamps and state may change; the semantic request identity may not.
  String get semanticIdentity {
    final value = request
      ..remove('status')
      ..remove('createdAt')
      ..remove('updatedAt')
      ..remove('reasonCode');
    return aivexusCanonicalJson(value);
  }

  static String idempotentRequestId({
    required String projectId,
    required int specRevision,
    required String operation,
    required List<Map<String, Object?>> sourceRefs,
    required Map<String, Object?> toolchain,
    required Map<String, Object?> requirements,
  }) =>
      'aivexus-request:${sha256.convert(utf8.encode(aivexusCanonicalJson({'projectId': projectId, 'specRevision': specRevision, 'operation': operation, 'sourceRefs': sourceRefs, 'toolchain': toolchain, 'requirements': requirements})))}';

  static const Map<String, List<String>> _transitions = {
    'requested': [
      'accepted',
      'rejected',
      'unavailable',
      'superseded',
      'cancelled',
    ],
    'accepted': [
      'produced',
      'rejected',
      'unavailable',
      'superseded',
      'cancelled',
    ],
    'produced': [],
    'rejected': [],
    'unavailable': [],
    'superseded': [],
    'cancelled': [],
  };

  bool canTransitionTo(String next) => _transitions[status]!.contains(next);

  AivexusResourceExchange transition(
    String next, {
    Map<String, Object?>? producedResult,
    String? reasonCode,
  }) {
    if (!canTransitionTo(next))
      throw StateError('Invalid exchange transition $status -> $next');
    return AivexusResourceExchange.read({
      ...toJson(),
      'request': <String, Object?>{
        ...request,
        'status': next,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        if (reasonCode != null) 'reasonCode': reasonCode,
      },
      'result': producedResult,
    });
  }

  AivexusResourceExchange withRecordRevision(int revision) =>
      AivexusResourceExchange.read({...toJson(), 'recordRevision': revision});
}

void _text(Object? value, String key) =>
    aivexusRequire(value is String && value.trim().isNotEmpty, key);
void _revision(Object? value) =>
    aivexusRequire(value is int && value > 0, 'positive integer');
void _hash(Object? value) => aivexusRequire(
  value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
  'sha256',
);
