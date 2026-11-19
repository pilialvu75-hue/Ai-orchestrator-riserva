import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_library_development_source.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const pin = 'utility.llm_generated.fixed_chunks@0.1.0';
  const path = 'packages/experimental/utility.llm_generated.fixed_chunks/0.1.0/package.json';

  Map<String, dynamic> package() => <String, dynamic>{
        'schema': 'ai-orchestrator.library-module-package.v1',
        'asset_id': 'utility.llm_generated.fixed_chunks',
        'version': '0.1.0',
        'pin': pin,
        'tier': 'sandbox_preview',
        'status': 'tested',
        'certified': false,
        'availability': 'experimental',
        'usage_policy': 'internal-isolated-evaluation-only',
        'review': <String, Object?>{
          'security_reviewed': false,
          'license_verified': false,
          'production_approved': false,
        },
        'capabilities': <String>['utility.llm_generated.fixed_chunks'],
        'contracts': <String>['utility.llm_generated.fixed_chunks.v1'],
        'files': <Map<String, String>>[
          <String, String>{
            'source_path': 'payload/src/pubspec.yaml',
            'target_path': 'pubspec.yaml',
            'content': 'name: aivexus_fixed_chunks\n',
          },
          <String, String>{
            'source_path': 'payload/src/lib/fixed_chunks.dart',
            'target_path': 'lib/fixed_chunks.dart',
            'content': 'List<List<int>> chunkIntegers(List<int> x,int n) => [];\n',
          },
        ],
      };

  Object? ordered(Object? data) {
    if (data is Map) {
      final keys = data.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: ordered(data[key]),
      };
    }
    if (data is List) return data.map(ordered).toList();
    return data;
  }

  String packageHash(Map<String, dynamic> value) =>
      sha256.convert(utf8.encode(jsonEncode(ordered(value)))).toString();

  Map<String, dynamic> index(String sha) => <String, dynamic>{
        'schema': ModuleLibraryDevelopmentSource.schema,
        'policy': 'internal-development-only-no-production-or-redistribution',
        'production_certified': false,
        'production_approved': false,
        'packages': <Map<String, Object?>>[
          <String, Object?>{
            'pin': pin,
            'path': path,
            'package_sha256': sha,
            'consumer_workflow_run_id': 123456,
            'validated_targets': <String>['linux'],
            'status': 'development_qualified',
            'development_qualified': true,
            'independent_export_consumer': 'PASS',
            'security_reviewed': false,
            'license_approved': false,
            'production_certified': false,
            'production_approved': false,
          },
        ],
      };

  http.Response answer(Object data, {int status = 200}) => http.Response(
        jsonEncode(<String, Object>{
          'encoding': 'base64',
          'content': base64Encode(utf8.encode(jsonEncode(data))),
        }),
        status,
      );

  test('reads a real qualification separately from the certified catalog', () async {
    final pkg = package();
    final hash = packageHash(pkg);
    final client = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer test-token');
      expect(req.url.host, 'api.github.com');
      expect(req.url.queryParameters['ref'], 'main');
      if (req.url.path.endsWith('packages/development-index.json')) {
        return answer(index(hash));
      }
      if (req.url.path.endsWith(path)) {
        return answer(<String, Object>{
          'schema': 'ai-orchestrator.library-module-package-envelope.v1',
          'package': pkg,
          'package_sha256': hash,
        });
      }
      return http.Response('not found', 404);
    });
    final source = ModuleLibraryDevelopmentSource(client: client);
    final entries = await source.load(token: 'test-token');
    expect(entries, hasLength(1));
    expect(entries.single.pin, pin);
    expect(entries.single.targets, <String>['linux']);
    final bundle = await source.loadPackage(
        token: 'test-token', entry: entries.single);
    expect(bundle.files['pubspec.yaml'], contains('aivexus_fixed_chunks'));
    expect(bundle.sourceSummary, contains('chunkIntegers'));
    expect(bundle.entry.consumerRunId, 123456);
  });

  test('rejects index that falsely claims production certification', () async {
    final invalid = index(List<String>.filled(64, 'a').join())..['production_certified'] = true;
    final source = ModuleLibraryDevelopmentSource(
        client: MockClient((_) async => answer(invalid)));
    await expectLater(source.load(token: 't'), throwsFormatException);
  });

  test('rejects a dev entry with fabricated consumer PASS', () async {
    final invalid = index('a' * 64);
    (invalid['packages'] as List).first['independent_export_consumer'] = 'FAILED';
    final source = ModuleLibraryDevelopmentSource(
        client: MockClient((_) async => answer(invalid)));
    await expectLater(source.load(token: 't'), throwsFormatException);
  });

  test('rejects altered source without matching SHA256', () async {
    final pkg = package();
    final original = packageHash(pkg);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('packages/development-index.json')) {
        return answer(index(original));
      }
      final changed = package();
      ((changed['files'] as List)[1] as Map)['content'] = 'malicious alteration';
      return answer(<String, Object>{
        'schema': 'ai-orchestrator.library-module-package-envelope.v1',
        'package': changed,
        'package_sha256': original,
      });
    });
    final source = ModuleLibraryDevelopmentSource(client: client);
    final entries = await source.load(token: 'test-token');
    await expectLater(
      source.loadPackage(token: 'test-token', entry: entries.single),
      throwsFormatException,
    );
  });

  test('rejects unsafe file traversal even with matching package SHA', () async {
    final pkg = package();
    ((pkg['files'] as List)[1] as Map)['target_path'] = '../evil.dart';
    final hash = packageHash(pkg);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('packages/development-index.json')) {
        return answer(index(hash));
      }
      return answer(<String, Object>{
        'schema': 'ai-orchestrator.library-module-package-envelope.v1',
        'package': pkg,
        'package_sha256': hash,
      });
    });
    final source = ModuleLibraryDevelopmentSource(client: client);
    final entries = await source.load(token: 'test-token');
    await expectLater(
      source.loadPackage(token: 'test-token', entry: entries.single),
      throwsFormatException,
    );
  });

  test('rejects non-200 read instead of displaying a fictitious module', () async {
    final source = ModuleLibraryDevelopmentSource(
      client: MockClient((_) async => http.Response('forbidden', 403)),
    );
    await expectLater(source.load(token: 't'), throwsStateError);
  });
}
