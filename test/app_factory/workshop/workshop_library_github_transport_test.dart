import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_transport.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('WorkshopLibraryGitHubTransport', () {
    test('fails closed before network when GitHub authorization is missing', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests += 1;
        return http.Response('{}', 500);
      });
      final store = WorkshopLibraryGitHubCredentialStore(
        storage: _MemorySecretStorage(),
      );
      final transport = WorkshopLibraryGitHubTransport(
        credentialStore: store,
        client: client,
        sleeper: (_) async {},
      );

      await expectLater(
        transport.submit(_bundle()),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);
    });

    test('creates deterministic intake branch and PR without writing main', () async {
      final storage = _MemorySecretStorage();
      final store = WorkshopLibraryGitHubCredentialStore(storage: storage);
      await store.save(
        const WorkshopGitHubUserCredential(accessToken: 'ghu_secret'),
      );
      final bundle = _bundle();
      final writes = <String, List<int>>{};
      final requests = <http.Request>[];
      const mainSha = '0123456789abcdef0123456789abcdef01234567';
      var branchCreated = false;

      final client = MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer ghu_secret');
        final path = request.url.path;
        final method = request.method;
        final ref = request.url.queryParameters['ref'];

        if (method == 'GET' && path.contains('/contents/')) {
          final repoPath = Uri.decodeFull(path.split('/contents/').last);
          if (ref == 'main') return http.Response('{}', 404);
          final bytes = writes[repoPath];
          if (bytes == null) return http.Response('{}', 404);
          return http.Response(
            jsonEncode(<String, Object?>{
              'content': base64Encode(bytes),
              'encoding': 'base64',
            }),
            200,
          );
        }

        if (method == 'GET' && path.endsWith('/git/ref/heads/main')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': <String, Object?>{'sha': mainSha},
            }),
            200,
          );
        }

        if (method == 'GET' && path.contains('/git/ref/heads/library-intake/')) {
          return http.Response('{}', branchCreated ? 200 : 404);
        }

        if (method == 'POST' && path.endsWith('/git/refs')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['sha'], mainSha);
          expect(body['ref'].toString(), startsWith('refs/heads/library-intake/'));
          branchCreated = true;
          return http.Response(jsonEncode(body), 201);
        }

        if (method == 'PUT' && path.contains('/contents/')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['branch'].toString(), startsWith('library-intake/'));
          expect(body['branch'], isNot('main'));
          final repoPath = Uri.decodeFull(path.split('/contents/').last);
          writes[repoPath] = base64Decode(body['content'] as String);
          return http.Response(
            jsonEncode(<String, Object?>{'content': <String, Object?>{}}),
            201,
          );
        }

        if (method == 'GET' && path.endsWith('/pulls')) {
          expect(request.url.queryParameters['state'], 'open');
          return http.Response('[]', 200);
        }

        if (method == 'POST' && path.endsWith('/pulls')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['base'], 'main');
          expect(body['head'].toString(), startsWith('library-intake/'));
          return http.Response(
            jsonEncode(<String, Object?>{
              'number': 42,
              'html_url': 'https://github.com/pilialvu75-hue/AI-Orchestrator-Module-Library/pull/42',
            }),
            201,
          );
        }

        fail('Unexpected GitHub request: $method ${request.url}');
      });

      final transport = WorkshopLibraryGitHubTransport(
        credentialStore: store,
        client: client,
        sleeper: (_) async {},
      );
      final receipt = await transport.submit(bundle);

      expect(receipt.alreadyOnMain, isFalse);
      expect(receipt.pullRequestNumber, 42);
      expect(receipt.branch, startsWith('library-intake/demo.asset-1.0.0-'));
      expect(
        writes.keys,
        containsAll(<String>[
          'intake/demo.asset/1.0.0/manifest.json',
          'intake/demo.asset/1.0.0/payload/archive.json',
        ]),
      );
      expect(
        requests.where((request) =>
            (request.method == 'PUT' || request.method == 'POST') &&
            request.body.contains('"branch":"main"')),
        isEmpty,
      );
    });

    test('returns idempotent success when immutable intake already exists on main', () async {
      final storage = _MemorySecretStorage();
      final store = WorkshopLibraryGitHubCredentialStore(storage: storage);
      await store.save(
        const WorkshopGitHubUserCredential(accessToken: 'ghu_secret'),
      );
      final bundle = _bundle();
      var mutations = 0;
      final manifestBytes = utf8.encode(jsonEncode(bundle.manifest));
      final payloadBytes = utf8.encode(bundle.payloadJson);

      final client = MockClient((request) async {
        if (request.method != 'GET') mutations += 1;
        final path = request.url.path;
        if (request.method == 'GET' && path.contains('/contents/')) {
          final repoPath = Uri.decodeFull(path.split('/contents/').last);
          final bytes = repoPath.endsWith('/manifest.json')
              ? manifestBytes
              : payloadBytes;
          return http.Response(
            jsonEncode(<String, Object?>{'content': base64Encode(bytes)}),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      });

      final receipt = await WorkshopLibraryGitHubTransport(
        credentialStore: store,
        client: client,
        sleeper: (_) async {},
      ).submit(bundle);

      expect(receipt.alreadyOnMain, isTrue);
      expect(receipt.branch, 'main');
      expect(mutations, 0);
    });

    test('rejects divergent immutable intake and never leaks token in error', () async {
      final storage = _MemorySecretStorage();
      final store = WorkshopLibraryGitHubCredentialStore(storage: storage);
      await store.save(
        const WorkshopGitHubUserCredential(accessToken: 'ghu_super_secret'),
      );
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'content': base64Encode(utf8.encode('{"different":true}')),
          }),
          200,
        );
      });

      try {
        await WorkshopLibraryGitHubTransport(
          credentialStore: store,
          client: client,
          sleeper: (_) async {},
        ).submit(_bundle());
        fail('Expected divergent immutable intake to fail.');
      } catch (error) {
        expect(error, isA<StateError>());
        expect(error.toString(), isNot(contains('ghu_super_secret')));
      }
    });
  });
}

WorkshopLibraryIntakeBundle _bundle() {
  final files = <WorkshopLibraryIntakePayloadFile>[
    WorkshopLibraryIntakePayloadFile(
      path: 'lib/module.dart',
      bytes: utf8.encode('class Module {}\n'),
    ),
  ];
  final digest = WorkshopLibraryIntakeBundle.computePayloadSha256(files);
  final submission = WorkshopLibraryIntakeSubmission(
    assetId: 'demo.asset',
    version: '1.0.0',
    manifest: <String, Object?>{
      'id': 'demo.asset',
      'name': 'Demo asset',
      'version': '1.0.0',
      'kind': 'module',
      'status': 'discovered',
      'description': 'Fixture',
      'capabilities': <String>['demo.capability'],
      'platforms': <String>['android'],
      'provenance': <String, Object?>{'origin': 'cantiere'},
      'validation': <String, Object?>{'score': 1.0, 'tests_passed': true},
      'security': <String, Object?>{'reviewed': true, 'known_vulnerabilities': 0},
      'integration': <String, Object?>{
        'estimated_effort': 'low',
        'adaptation_allowed': true,
      },
      'connector': <String, Object?>{
        'standard': 'ai-orchestrator-lego',
        'standard_version': '1.0.0',
        'provides': <Object?>[],
        'requires': <Object?>[],
        'integration_mode': 'source_bundle',
        'healthcheck': <String, Object?>{'type': 'none', 'path': null},
      },
      'payload': <String, Object?>{
        'type': 'archive',
        'path': 'payload/archive.json',
        'sha256': digest,
        'upstream_repository': null,
        'upstream_commit': null,
      },
    },
    sourceProjectId: 'project-1',
    sourceTaskId: 'task-1',
    payloadSha256: digest,
  );
  return WorkshopLibraryIntakeBundle.build(
    submission: submission,
    files: files,
  );
}

final class _MemorySecretStorage implements WorkshopLibrarySecretStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
