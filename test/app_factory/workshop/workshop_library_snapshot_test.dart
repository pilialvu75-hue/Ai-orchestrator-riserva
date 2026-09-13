import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_snapshot.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLibrarySnapshotReader', () {
    const reader = WorkshopLibrarySnapshotReader();

    test('maps certified records into planner candidates with integrity', () {
      final fixture = _snapshot();
      final snapshot = reader.decode(
        snapshotJson: fixture.json,
        expectedSnapshotSha256: fixture.sha,
      );

      expect(snapshot.libraryId, 'fixture-library');
      expect(snapshot.catalogVersion, '1.2.3');
      expect(snapshot.assets, hasLength(3));

      final active = snapshot.assetByPin('demo.active@1.0.0');
      expect(active, isNotNull);
      expect(
        active!.candidate.availability,
        WorkshopLibraryCandidateAvailability.active,
      );
      expect(active.candidate.validationScore, 0.95);
      expect(active.candidate.resolutionScore, 0.82);
      expect(active.candidate.observedSuccessRate, 0.75);
      expect(active.candidate.evidenceCount, 4);
      expect(active.moduleTreeSha256, List<String>.filled(64, 'b').join());
      expect(active.manifestSha256, List<String>.filled(64, 'a').join());

      final revoked = snapshot.assetByPin('demo.revoked@1.0.0');
      expect(
        revoked!.candidate.availability,
        WorkshopLibraryCandidateAvailability.revoked,
      );
    });

    test('non-certified records never enter the Cantiere planner surface', () {
      final fixture = _snapshot(includeDiscovered: true);
      final snapshot = reader.decode(
        snapshotJson: fixture.json,
        expectedSnapshotSha256: fixture.sha,
      );
      expect(snapshot.assetByPin('demo.discovered@1.0.0'), isNull);
    });

    test('snapshot can feed existing reuse planner without transport knowledge', () {
      final fixture = _snapshot();
      final snapshot = reader.decode(
        snapshotJson: fixture.json,
        expectedSnapshotSha256: fixture.sha,
      );

      final need = WorkshopCapabilityNeed(
        capabilityId: 'demo.capability',
        preferredContractId: 'demo.capability.v1',
        required: true,
        reason: 'fixture',
      );
      final shoppingList = WorkshopCapabilityShoppingList(
        projectId: 'project-1',
        generatedAt: DateTime.utc(2026, 9, 13),
        needs: <WorkshopCapabilityNeed>[need],
      );
      final result = const WorkshopCapabilityReusePlanner().plan(
        shoppingList: shoppingList,
        candidates: snapshot.candidates,
      );

      expect(result.decisions.single.candidate?.pin, 'demo.active@1.0.0');
      expect(
        result.decisions.single.action,
        WorkshopCapabilityReuseAction.reuse,
      );
    });

    test('fails closed on self-hash or trusted-hash mismatch', () {
      final fixture = _snapshot();
      final wrong = List<String>.filled(64, 'f').join();
      expect(
        () => reader.decode(
          snapshotJson: fixture.json,
          expectedSnapshotSha256: wrong,
        ),
        throwsFormatException,
      );

      final decoded = jsonDecode(fixture.json) as Map<String, dynamic>;
      decoded['catalog_version'] = '9.9.9';
      expect(
        () => reader.decode(
          snapshotJson: jsonEncode(decoded),
          expectedSnapshotSha256: fixture.sha,
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed certified integrity and duplicate pins', () {
      final badIntegrity = _snapshot(badIntegrity: true);
      expect(
        () => reader.decode(
          snapshotJson: badIntegrity.json,
          expectedSnapshotSha256: badIntegrity.sha,
        ),
        throwsFormatException,
      );

      final duplicate = _snapshot(duplicateActive: true);
      expect(
        () => reader.decode(
          snapshotJson: duplicate.json,
          expectedSnapshotSha256: duplicate.sha,
        ),
        throwsFormatException,
      );
    });
  });
}

({String json, String sha}) _snapshot({
  bool includeDiscovered = false,
  bool badIntegrity = false,
  bool duplicateActive = false,
}) {
  final assets = <Map<String, Object?>>[
    _asset(
      id: 'demo.active',
      availability: 'active',
      manifestSha: badIntegrity ? 'bad' : List<String>.filled(64, 'a').join(),
      treeSha: List<String>.filled(64, 'b').join(),
      successes: 3,
      failures: 1,
      validation: 0.95,
      ranking: 0.82,
    ),
    _asset(
      id: 'demo.deprecated',
      availability: 'deprecated',
      manifestSha: List<String>.filled(64, 'c').join(),
      treeSha: List<String>.filled(64, 'd').join(),
      successes: 0,
      failures: 0,
      validation: 0.90,
      ranking: 0.70,
    ),
    _asset(
      id: 'demo.revoked',
      availability: 'revoked',
      manifestSha: List<String>.filled(64, 'e').join(),
      treeSha: List<String>.filled(64, 'f').join(),
      successes: 5,
      failures: 0,
      validation: 1.0,
      ranking: 0.99,
    ),
    if (duplicateActive)
      _asset(
        id: 'demo.active',
        availability: 'active',
        manifestSha: List<String>.filled(64, '1').join(),
        treeSha: List<String>.filled(64, '2').join(),
        successes: 1,
        failures: 0,
        validation: 0.9,
        ranking: 0.7,
      ),
    if (includeDiscovered)
      <String, Object?>{
        ..._asset(
          id: 'demo.discovered',
          availability: 'active',
          manifestSha: List<String>.filled(64, '3').join(),
          treeSha: List<String>.filled(64, '4').join(),
          successes: 0,
          failures: 0,
          validation: 0.5,
          ranking: 0.2,
        ),
        'status': 'discovered',
      },
  ];

  final payload = <String, Object?>{
    'schema_version': 1,
    'library_id': 'fixture-library',
    'catalog_version': '1.2.3',
    'source_state': <String, Object?>{
      'catalog_updated_at': '2026-09-13T19:00:00Z',
      'contracts_updated_at': '2026-09-13T19:00:00Z',
      'needs_updated_at': '2026-09-13T19:00:00Z',
      'lifecycle_revision': 1,
      'lifecycle_updated_at': '2026-09-13T19:00:00Z',
    },
    'resolution_policy': <String, Object?>{
      'id': 'balanced-v1',
      'weights': <String, Object?>{
        'validation': 0.45,
        'integration_effort': 0.25,
        'operational_reliability': 0.20,
        'evidence_confidence': 0.10,
      },
    },
    'contracts': const <Object?>[],
    'needs': const <Object?>[],
    'assets': assets,
  };
  final canonical = jsonEncode(_canonicalize(payload));
  final sha = sha256.convert(utf8.encode(canonical)).toString();
  final snapshot = <String, Object?>{...payload, 'snapshot_sha256': sha};
  return (json: jsonEncode(snapshot), sha: sha);
}

Map<String, Object?> _asset({
  required String id,
  required String availability,
  required String manifestSha,
  required String treeSha,
  required int successes,
  required int failures,
  required double validation,
  required double ranking,
}) {
  return <String, Object?>{
    'id': id,
    'version': '1.0.0',
    'kind': 'module',
    'status': 'certified',
    'availability': availability,
    'description': 'fixture',
    'capabilities': <String>['demo.capability'],
    'platforms': <String>['android'],
    'contracts': <Map<String, Object?>>[
      <String, Object?>{
        'contract_id': 'demo.capability.v1',
        'status': 'stable',
        'contract_version': '1.0',
        'known': true,
      },
    ],
    'dependencies': const <Object?>[],
    'provenance': const <String, Object?>{},
    'validation': <String, Object?>{'score': validation, 'tests_passed': true},
    'security': const <String, Object?>{'reviewed': true, 'known_vulnerabilities': 0},
    'integration': const <String, Object?>{
      'estimated_effort': 'low',
      'adaptation_allowed': true,
    },
    'connector': const <String, Object?>{},
    'payload': const <String, Object?>{},
    'observations': <String, Object?>{
      'successful_integrations': successes,
      'failed_integrations': failures,
      'integration_attempts': successes + failures,
    },
    'ranking': <String, Object?>{
      'policy': 'balanced-v1',
      'score': ranking,
      'components': const <String, Object?>{},
      'weights': const <String, Object?>{},
      'evidence': <String, Object?>{
        'successful_integrations': successes,
        'failed_integrations': failures,
        'attempts': successes + failures,
        'estimated_effort': 'low',
      },
      'note': 'fixture',
    },
    'integrity': <String, Object?>{
      'manifest_sha256': manifestSha,
      'module_tree_sha256': treeSha,
    },
    'paths': const <String, Object?>{
      'manifest': 'modules/demo/1.0.0/manifest.json',
      'module': 'modules/demo/1.0.0',
    },
    'warnings': const <Object?>[],
  };
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}
