import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'workshop_capability_reuse_planner.dart';

final class WorkshopLibrarySnapshotAsset {
  const WorkshopLibrarySnapshotAsset({
    required this.candidate,
    required this.manifestSha256,
    required this.moduleTreeSha256,
  });

  final WorkshopLibraryCandidate candidate;
  final String manifestSha256;
  final String moduleTreeSha256;
}

final class WorkshopLibrarySnapshot {
  const WorkshopLibrarySnapshot({
    required this.libraryId,
    required this.catalogVersion,
    required this.snapshotSha256,
    required this.assets,
  });

  final String libraryId;
  final String catalogVersion;
  final String snapshotSha256;
  final List<WorkshopLibrarySnapshotAsset> assets;

  List<WorkshopLibraryCandidate> get candidates =>
      List<WorkshopLibraryCandidate>.unmodifiable(
        assets.map((item) => item.candidate),
      );

  WorkshopLibrarySnapshotAsset? assetByPin(String pin) {
    for (final asset in assets) {
      if (asset.candidate.pin == pin) return asset;
    }
    return null;
  }
}

/// Decodes the deterministic offline snapshot exported by
/// `AI-Orchestrator-Module-Library/tools/library_resolver.py`.
///
/// The self-hash is recomputed and must also equal the digest obtained through
/// the trusted transport/storage channel. No network, workspace or AI call is
/// performed here.
final class WorkshopLibrarySnapshotReader {
  const WorkshopLibrarySnapshotReader();

  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  WorkshopLibrarySnapshot decode({
    required String snapshotJson,
    required String expectedSnapshotSha256,
  }) {
    final expected = expectedSnapshotSha256.trim().toLowerCase();
    if (!_sha256.hasMatch(expected)) {
      throw const FormatException('Expected Library snapshot SHA-256 is invalid.');
    }

    final decoded = jsonDecode(snapshotJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Library snapshot must be a JSON object.');
    }
    if (decoded['schema_version'] != 1) {
      throw const FormatException('Unsupported Library snapshot schema version.');
    }

    final declared = decoded['snapshot_sha256']?.toString().trim().toLowerCase() ?? '';
    if (!_sha256.hasMatch(declared)) {
      throw const FormatException('Library snapshot self hash is missing or invalid.');
    }

    final payload = Map<String, dynamic>.from(decoded)..remove('snapshot_sha256');
    final computed = sha256.convert(utf8.encode(_canonicalJson(payload))).toString();
    if (computed != declared || computed != expected) {
      throw const FormatException('Library snapshot SHA-256 mismatch.');
    }

    final libraryId = decoded['library_id']?.toString().trim() ?? '';
    final catalogVersion = decoded['catalog_version']?.toString().trim() ?? '';
    if (libraryId.isEmpty || catalogVersion.isEmpty) {
      throw const FormatException('Library snapshot identity is incomplete.');
    }

    final rawAssets = decoded['assets'];
    if (rawAssets is! List) {
      throw const FormatException('Library snapshot assets must be an array.');
    }

    final assets = <WorkshopLibrarySnapshotAsset>[];
    final seenPins = <String>{};
    for (final raw in rawAssets) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Library snapshot asset must be an object.');
      }
      // Non-certified records remain useful to Library tooling but can never
      // enter the Cantiere reuse planner.
      if (raw['status'] != 'certified') continue;

      final assetId = raw['id']?.toString().trim() ?? '';
      final version = raw['version']?.toString().trim() ?? '';
      if (assetId.isEmpty || version.isEmpty) {
        throw const FormatException('Certified Library asset identity is incomplete.');
      }
      final pin = '$assetId@$version';
      if (!seenPins.add(pin)) {
        throw const FormatException('Library snapshot contains duplicate certified pins.');
      }

      final availability = _availability(raw['availability']?.toString() ?? '');
      final capabilities = _strings(raw['capabilities'], 'capabilities');
      final targets = _strings(raw['platforms'], 'platforms');
      if (capabilities.isEmpty || targets.isEmpty) {
        throw const FormatException(
          'Certified Library asset must expose capabilities and platforms.',
        );
      }

      final rawContracts = raw['contracts'];
      if (rawContracts is! List) {
        throw const FormatException('Library asset contracts must be an array.');
      }
      final contracts = <String>[];
      final contractSeen = <String>{};
      for (final item in rawContracts) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Library contract metadata must be an object.');
        }
        final id = item['contract_id']?.toString().trim() ?? '';
        if (id.isEmpty || !contractSeen.add(id)) {
          throw const FormatException('Library contract id is empty or duplicated.');
        }
        contracts.add(id);
      }
      contracts.sort();
      if (contracts.isEmpty) {
        throw const FormatException('Certified Library asset has no contracts.');
      }

      final validation = _object(raw['validation'], 'validation');
      final validationScore = _score(validation['score'], 'validation.score');
      final ranking = _object(raw['ranking'], 'ranking');
      final resolutionScore = _score(ranking['score'], 'ranking.score');
      final integration = _object(raw['integration'], 'integration');
      final effort = _effort(integration['estimated_effort']?.toString() ?? '');
      final observations = _object(raw['observations'], 'observations');
      final successes = _nonNegativeInt(
        observations['successful_integrations'],
        'observations.successful_integrations',
      );
      final failures = _nonNegativeInt(
        observations['failed_integrations'],
        'observations.failed_integrations',
      );
      final evidenceCount = successes + failures;
      final successRate = evidenceCount == 0 ? null : successes / evidenceCount;

      final integrity = _object(raw['integrity'], 'integrity');
      final manifestSha =
          integrity['manifest_sha256']?.toString().trim().toLowerCase() ?? '';
      final treeSha =
          integrity['module_tree_sha256']?.toString().trim().toLowerCase() ?? '';
      if (!_sha256.hasMatch(manifestSha) || !_sha256.hasMatch(treeSha)) {
        throw const FormatException('Library asset integrity hashes are invalid.');
      }

      assets.add(
        WorkshopLibrarySnapshotAsset(
          candidate: WorkshopLibraryCandidate(
            assetId: assetId,
            version: version,
            capabilities: List<String>.unmodifiable(capabilities),
            contracts: List<String>.unmodifiable(contracts),
            targets: List<String>.unmodifiable(targets),
            availability: availability,
            validationScore: validationScore,
            resolutionScore: resolutionScore,
            integrationEffort: effort,
            observedSuccessRate: successRate,
            evidenceCount: evidenceCount,
          ),
          manifestSha256: manifestSha,
          moduleTreeSha256: treeSha,
        ),
      );
    }

    assets.sort((left, right) => left.candidate.pin.compareTo(right.candidate.pin));
    return WorkshopLibrarySnapshot(
      libraryId: libraryId,
      catalogVersion: catalogVersion,
      snapshotSha256: computed,
      assets: List<WorkshopLibrarySnapshotAsset>.unmodifiable(assets),
    );
  }

  static WorkshopLibraryCandidateAvailability _availability(String raw) =>
      switch (raw.trim()) {
        'active' => WorkshopLibraryCandidateAvailability.active,
        'deprecated' => WorkshopLibraryCandidateAvailability.deprecated,
        'revoked' => WorkshopLibraryCandidateAvailability.revoked,
        _ => throw const FormatException('Invalid Library asset availability.'),
      };

  static WorkshopLibraryIntegrationEffort _effort(String raw) =>
      switch (raw.trim()) {
        'trivial' => WorkshopLibraryIntegrationEffort.trivial,
        'low' => WorkshopLibraryIntegrationEffort.low,
        'medium' => WorkshopLibraryIntegrationEffort.medium,
        'high' => WorkshopLibraryIntegrationEffort.high,
        _ => throw const FormatException('Invalid Library integration effort.'),
      };

  static Map<String, dynamic> _object(Object? raw, String field) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('Library asset $field must be an object.');
    }
    return raw;
  }

  static List<String> _strings(Object? raw, String field) {
    if (raw is! List) {
      throw FormatException('Library asset $field must be an array.');
    }
    final values = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! String || item.trim().isEmpty || !seen.add(item.trim())) {
        throw FormatException('Library asset $field contains invalid values.');
      }
      values.add(item.trim());
    }
    values.sort();
    return values;
  }

  static double _score(Object? raw, String field) {
    if (raw is! num) {
      throw FormatException('Library $field must be numeric.');
    }
    final value = raw.toDouble();
    if (value < 0 || value > 1) {
      throw FormatException('Library $field must be within 0..1.');
    }
    return value;
  }

  static int _nonNegativeInt(Object? raw, String field) {
    if (raw is! int || raw < 0) {
      throw FormatException('Library $field must be a non-negative integer.');
    }
    return raw;
  }

  static String _canonicalJson(Object? value) => jsonEncode(_canonicalize(value));

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('Library snapshot contains a non-JSON value.');
  }
}
