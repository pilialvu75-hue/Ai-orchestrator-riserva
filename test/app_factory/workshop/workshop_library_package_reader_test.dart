import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_package_reader.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLibraryPackageReader', () {
    const reader = WorkshopLibraryPackageReader();
    final treeSha = List<String>.filled(64, 'a').join();

    test('decodes exact verified certified package for assembly', () {
      final fixture = _envelope(treeSha: treeSha);
      final package = reader.decode(
        envelopeJson: fixture.json,
        expectedPin: 'demo.asset@1.0.0',
        expectedPackageSha256: fixture.packageSha,
        expectedModuleTreeSha256: treeSha,
      );

      expect(package.pin, 'demo.asset@1.0.0');
      expect(package.artifactDigest, treeSha);
      expect(package.capabilities, <String>['demo.capability']);
      expect(package.contracts, <String>['demo.capability.v1']);
      expect(package.files, hasLength(1));
      expect(package.files.single.targetPath, 'lib/demo.dart');
      expect(package.files.single.content, 'class Demo {}\n');
      expect(package.requirements, hasLength(2));
      expect(
        package.requirements.first.kind,
        WorkshopAssemblyRequirementKind.dependency,
      );
    });

    test('fails closed when authenticated package digest differs', () {
      final fixture = _envelope(treeSha: treeSha);
      final wrong = List<String>.filled(64, 'b').join();
      expect(
        () => reader.decode(
          envelopeJson: fixture.json,
          expectedPin: 'demo.asset@1.0.0',
          expectedPackageSha256: wrong,
          expectedModuleTreeSha256: treeSha,
        ),
        throwsFormatException,
      );
    });

    test('fails closed when selected module tree digest differs', () {
      final fixture = _envelope(treeSha: treeSha);
      final wrong = List<String>.filled(64, 'c').join();
      expect(
        () => reader.decode(
          envelopeJson: fixture.json,
          expectedPin: 'demo.asset@1.0.0',
          expectedPackageSha256: fixture.packageSha,
          expectedModuleTreeSha256: wrong,
        ),
        throwsFormatException,
      );
    });

    test('rejects a different pin and revoked availability', () {
      final fixture = _envelope(treeSha: treeSha);
      expect(
        () => reader.decode(
          envelopeJson: fixture.json,
          expectedPin: 'other.asset@1.0.0',
          expectedPackageSha256: fixture.packageSha,
          expectedModuleTreeSha256: treeSha,
        ),
        throwsFormatException,
      );

      final revoked = _envelope(treeSha: treeSha, availability: 'revoked');
      expect(
        () => reader.decode(
          envelopeJson: revoked.json,
          expectedPin: 'demo.asset@1.0.0',
          expectedPackageSha256: revoked.packageSha,
          expectedModuleTreeSha256: treeSha,
        ),
        throwsFormatException,
      );
    });

    test('rejects unsafe or duplicate target paths', () {
      for (final path in <String>[
        '../escape.dart',
        '.git/config',
        'android/key.properties',
      ]) {
        final fixture = _envelope(treeSha: treeSha, targetPath: path);
        expect(
          () => reader.decode(
            envelopeJson: fixture.json,
            expectedPin: 'demo.asset@1.0.0',
            expectedPackageSha256: fixture.packageSha,
            expectedModuleTreeSha256: treeSha,
          ),
          throwsFormatException,
          reason: path,
        );
      }

      final duplicate = _envelope(treeSha: treeSha, duplicateFile: true);
      expect(
        () => reader.decode(
          envelopeJson: duplicate.json,
          expectedPin: 'demo.asset@1.0.0',
          expectedPackageSha256: duplicate.packageSha,
          expectedModuleTreeSha256: treeSha,
        ),
        throwsFormatException,
      );
    });

    test('supports source-less upstream package only through explicit requirement', () {
      final fixture = _envelope(
        treeSha: treeSha,
        files: const <Map<String, Object?>>[],
        requirements: const <Map<String, Object?>>[
          <String, Object?>{
            'kind': 'manualReview',
            'description':
                'Resolve immutable upstream source https://github.com/example/demo@0123456789abcdef',
            'required': true,
          },
        ],
      );
      final package = reader.decode(
        envelopeJson: fixture.json,
        expectedPin: 'demo.asset@1.0.0',
        expectedPackageSha256: fixture.packageSha,
        expectedModuleTreeSha256: treeSha,
      );
      expect(package.files, isEmpty);
      expect(package.requirements.single.required, isTrue);
      expect(
        package.requirements.single.kind,
        WorkshopAssemblyRequirementKind.manualReview,
      );
    });
  });
}

({String json, String packageSha}) _envelope({
  required String treeSha,
  String availability = 'active',
  String targetPath = 'lib/demo.dart',
  bool duplicateFile = false,
  List<Map<String, Object?>>? files,
  List<Map<String, Object?>>? requirements,
}) {
  final packageFiles = files ??
      <Map<String, Object?>>[
        <String, Object?>{
          'source_path': 'lib/demo.dart',
          'target_path': targetPath,
          'content': 'class Demo {}\n',
        },
        if (duplicateFile)
          <String, Object?>{
            'source_path': 'lib/other.dart',
            'target_path': targetPath,
            'content': 'class Other {}\n',
          },
      ];
  final packageRequirements = requirements ??
      const <Map<String, Object?>>[
        <String, Object?>{
          'kind': 'dependency',
          'description': 'demo_dep ^1.0.0 (pub)',
          'required': true,
        },
        <String, Object?>{
          'kind': 'manualReview',
          'description': 'Check host configuration',
          'required': false,
        },
      ];
  final package = <String, Object?>{
    'schema': 'ai-orchestrator.library-module-package.v1',
    'asset_id': 'demo.asset',
    'version': '1.0.0',
    'pin': 'demo.asset@1.0.0',
    'availability': availability,
    'capabilities': <String>['demo.capability'],
    'contracts': <String>['demo.capability.v1'],
    'targets': <String>['android'],
    'files': packageFiles,
    'requirements': packageRequirements,
    'integrity': <String, Object?>{
      'manifest_sha256': List<String>.filled(64, 'd').join(),
      'module_tree_sha256': treeSha,
    },
    'source': <String, Object?>{
      'payload_type': files != null && files.isEmpty
          ? 'upstream_reference'
          : 'archive',
      'upstream_repository': files != null && files.isEmpty
          ? 'https://github.com/example/demo'
          : null,
      'upstream_commit': files != null && files.isEmpty
          ? '0123456789abcdef'
          : null,
    },
  };
  final canonical = jsonEncode(_canonicalize(package));
  final packageSha = sha256.convert(utf8.encode(canonical)).toString();
  return (
    json: jsonEncode(<String, Object?>{
      'schema': 'ai-orchestrator.library-module-package-envelope.v1',
      'package': package,
      'package_sha256': packageSha,
    }),
    packageSha: packageSha,
  );
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
