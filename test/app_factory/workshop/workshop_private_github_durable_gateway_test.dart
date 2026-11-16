import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_build_generation_ledger.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_dispatch_resolver.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_frozen_source_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_github_actions_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_source_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_monitor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_durable_gateway.dart';

void main() {
  const baseCommit = '1111111111111111111111111111111111111111';
  const baseTree = '2222222222222222222222222222222222222222';
  const sourceBlob = '3333333333333333333333333333333333333333';
  const manifestBlob = '4444444444444444444444444444444444444444';
  const stagedTree = '5555555555555555555555555555555555555555';
  const stagedCommit = '6666666666666666666666666666666666666666';

  group('WorkshopPrivateGitHubDurableGateway', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('durable-github-');
      final main = File('${workspace.path}/lib/main.dart');
      await main.parent.create(recursive: true);
      await main.writeAsString('void main() {}\n');
    });

    tearDown(() async {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    });

    test('stages and dispatches once without polling for a run', () async {
      var blobCalls = 0;
      var dispatchCalls = 0;
      var runListCalls = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && _isRepositoryRoot(path)) {
          return http.Response('{"private":true}', 200);
        }
        if (request.method == 'GET' && path.endsWith('/git/ref/heads/main')) {
          return http.Response('{"object":{"sha":"$baseCommit"}}', 200);
        }
        if (request.method == 'GET' &&
            path.endsWith('/git/commits/$baseCommit')) {
          return http.Response('{"tree":{"sha":"$baseTree"}}', 200);
        }
        if (request.method == 'POST' && path.endsWith('/git/blobs')) {
          blobCalls += 1;
          final sha = blobCalls == 1 ? sourceBlob : manifestBlob;
          return http.Response('{"sha":"$sha"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/trees')) {
          return http.Response('{"sha":"$stagedTree"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/commits')) {
          return http.Response('{"sha":"$stagedCommit"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/refs')) {
          return http.Response('{"ref":"refs/heads/test"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/dispatches')) {
          dispatchCalls += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final inputs = body['inputs'] as Map<String, dynamic>;
          expect(inputs['request_id'], _remoteId('stable-correlation'));
          return http.Response('', 204);
        }
        if (path.contains('/runs')) runListCalls += 1;
        return http.Response('not expected: ${request.method} $path', 500);
      });

      final gateway = _gateway(client);
      final outcome = await gateway.dispatch(
        request: _request(workspace.path),
        correlationId: 'stable-correlation',
      );

      expect(
        outcome.disposition,
        WorkshopDurableGitHubDispatchDisposition.accepted,
      );
      expect(blobCalls, 2);
      expect(dispatchCalls, 1);
      expect(runListCalls, 0);
    });

    test('durable dispatch stages frozen bytes after workspace mutation',
        () async {
      final request = _request(workspace.path);
      final privateRoot =
          await Directory.systemTemp.createTemp('cantiere-private-frozen-');
      addTearDown(() async {
        if (await privateRoot.exists()) await privateRoot.delete(recursive: true);
      });
      final frozen = WorkshopDurableFrozenSourceStore(root: privateRoot);
      final ledgerStorage = _MemoryGenerationStorage();
      final ledger =
          WorkshopDurableBuildGenerationLedger(storage: ledgerStorage);
      final source =
          await const WorkshopBuildSourceSnapshotter().capture(workspace.path);
      await frozen.persist(
        request: request, source: source, namespace: 'account-one',
      );
      final ticket = await ledger.reserveNew(
        request: request, source: source,
      );

      // The original project may change while an already-selected build waits.
      final original = utf8.decode(source.files.single.bytes);
      expect(original, 'void main() {}\\n');
      await File('${workspace.path}/lib/main.dart').writeAsString(
        'void main() { print("MUTATED AFTER RESERVATION"); }',
      );

      var blobCalls = 0;
      var dispatchCalls = 0;
      final client = MockClient((http.Request call) async {
        final path = call.url.path;
        if (call.method == 'GET' && _isRepositoryRoot(path)) {
          return http.Response('{"private":true}', 200);
        }
        if (call.method == 'GET' && path.endsWith('/git/ref/heads/main')) {
          return http.Response('{"object":{"sha":"$baseCommit"}}', 200);
        }
        if (call.method == 'GET' &&
            path.endsWith('/git/commits/$baseCommit')) {
          return http.Response('{"tree":{"sha":"$baseTree"}}', 200);
        }
        if (call.method == 'POST' && path.endsWith('/git/blobs')) {
          blobCalls++;
          final payload = jsonDecode(call.body) as Map<String, dynamic>;
          if (blobCalls == 1) {
            final restored = utf8.decode(
              base64Decode(payload['content'] as String),
            );
            expect(restored, original);
            expect(restored, isNot(contains('MUTATED AFTER RESERVATION')));
          }
          return http.Response(
            '{"sha":"${blobCalls == 1 ? sourceBlob : manifestBlob}"}',
            201,
          );
        }
        if (call.method == 'POST' && path.endsWith('/git/trees')) {
          return http.Response('{"sha":"$stagedTree"}', 201);
        }
        if (call.method == 'POST' && path.endsWith('/git/commits')) {
          return http.Response('{"sha":"$stagedCommit"}', 201);
        }
        if (call.method == 'POST' && path.endsWith('/git/refs')) {
          return http.Response('{"ref":"refs/heads/test"}', 201);
        }
        if (call.method == 'POST' && path.endsWith('/dispatches')) {
          dispatchCalls++;
          return http.Response('', 204);
        }
        return http.Response('unexpected $path', 500);
      });
      final resolver = WorkshopDurableFrozenDispatchResolver(
        ledger: ledger, frozenStore: frozen, namespace: 'account-one',
      );
      final result = await _gateway(
        client, sourceResolver: resolver.resolve,
      ).dispatch(
        request: _request(workspace.path),
        correlationId: '${ticket.buildId}:attempt:1',
      );
      expect(result.disposition,
          WorkshopDurableGitHubDispatchDisposition.accepted);
      expect(blobCalls, 2);
      expect(dispatchCalls, 1);
    });

    test('missing generation fails before any source or dispatch staging',
        () async {
      final client = MockClient((call) async {
        if (_isRepositoryRoot(call.url.path)) {
          return http.Response('{"private":true}', 200);
        }
        fail('No GitHub staging or workflow dispatch permitted: ${call.url}');
      });
      final privateRoot =
          await Directory.systemTemp.createTemp('cantiere-private-missing-');
      addTearDown(() async {
        if (await privateRoot.exists()) await privateRoot.delete(recursive: true);
      });
      final resolver = WorkshopDurableFrozenDispatchResolver(
        ledger: WorkshopDurableBuildGenerationLedger(
          storage: _MemoryGenerationStorage(),
        ),
        frozenStore: WorkshopDurableFrozenSourceStore(root: privateRoot),
        namespace: 'account-one',
      );
      await expectLater(
        _gateway(client, sourceResolver: resolver.resolve).dispatch(
          request: _request(workspace.path),
          correlationId: 'durable-v2-0000000000000000000000000000000000000000:attempt:1',
        ),
        throwsA(isA<WorkshopDurableGitHubGatewayException>()),
      );
    });

    test('resolver rejects wrong generation, malformed attempt and lost archive',
        () async {
      final req = _request(workspace.path);
      final privateRoot =
          await Directory.systemTemp.createTemp('cantiere-private-recover-');
      addTearDown(() async {
        if (await privateRoot.exists()) await privateRoot.delete(recursive: true);
      });
      final frozen = WorkshopDurableFrozenSourceStore(root: privateRoot);
      final source =
          await const WorkshopBuildSourceSnapshotter().capture(workspace.path);
      final handle = await frozen.persist(
        request: req, source: source, namespace: 'account-one',
      );
      final ledger = WorkshopDurableBuildGenerationLedger(
        storage: _MemoryGenerationStorage(),
      );
      final ticket = await ledger.reserveNew(request: req, source: source);
      final resolver = WorkshopDurableFrozenDispatchResolver(
        ledger: ledger, frozenStore: frozen, namespace: 'account-one',
      );
      for (final correlation in <String>[
        'durable-v2-0000000000000000000000000000000000000000:attempt:1',
        '${ticket.buildId}:attempt:0',
        '${ticket.buildId}:attempt:01',
        '${ticket.buildId}:attempt:garbage',
      ]) {
        await expectLater(
          resolver.resolve(request: req, correlationId: correlation),
          throwsStateError,
        );
      }
      final archived = File('${privateRoot.path}/${handle.key}.avxf');
      await archived.delete();
      await expectLater(
        resolver.resolve(
          request: req, correlationId: '${ticket.buildId}:attempt:1',
        ),
        throwsStateError,
      );
    });

    test('server failure after dispatch request is treated as ambiguous',
        () async {
      var blobCalls = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && _isRepositoryRoot(path)) {
          return http.Response('{"private":true}', 200);
        }
        if (request.method == 'GET' && path.endsWith('/git/ref/heads/main')) {
          return http.Response('{"object":{"sha":"$baseCommit"}}', 200);
        }
        if (request.method == 'GET' &&
            path.endsWith('/git/commits/$baseCommit')) {
          return http.Response('{"tree":{"sha":"$baseTree"}}', 200);
        }
        if (request.method == 'POST' && path.endsWith('/git/blobs')) {
          blobCalls += 1;
          final sha = blobCalls == 1 ? sourceBlob : manifestBlob;
          return http.Response('{"sha":"$sha"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/trees')) {
          return http.Response('{"sha":"$stagedTree"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/commits')) {
          return http.Response('{"sha":"$stagedCommit"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/git/refs')) {
          return http.Response('{"ref":"refs/heads/test"}', 201);
        }
        if (request.method == 'POST' && path.endsWith('/dispatches')) {
          return http.Response('upstream unavailable', 502);
        }
        return http.Response('unexpected', 500);
      });

      final outcome = await _gateway(client).dispatch(
        request: _request(workspace.path),
        correlationId: 'ambiguous-correlation',
      );

      expect(
        outcome.disposition,
        WorkshopDurableGitHubDispatchDisposition.ambiguous,
      );
    });

    test('fresh gateway adopts only run bound to exact staged branch commit',
        () async {
      final correlation = 'restart-correlation';
      final remoteId = _remoteId(correlation);
      final branch = 'cantiere-build/$remoteId';
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path.endsWith('/git/ref/heads/$branch')) {
          return http.Response(
            '{"object":{"sha":"$stagedCommit"}}',
            200,
          );
        }
        if (request.method == 'GET' && path.endsWith('/runs')) {
          expect(request.url.queryParameters['branch'], branch);
          return http.Response(
            jsonEncode(<String, Object?>{
              'workflow_runs': <Object?>[
                _runJson(
                  id: 40,
                  remoteId: remoteId,
                  headSha: baseCommit,
                  status: 'completed',
                  conclusion: 'success',
                ),
                _runJson(
                  id: 41,
                  remoteId: remoteId,
                  headSha: stagedCommit,
                  status: 'in_progress',
                ),
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected: ${request.method} $path', 500);
      });

      final recovered = await _gateway(client).discoverRun(
        request: _request(workspace.path),
        correlationId: correlation,
      );

      expect(recovered, isNotNull);
      expect(recovered!.id, 41);
      expect(recovered.headSha, stagedCommit);
      expect(recovered.status, WorkshopGitHubRunStatus.inProgress);
    });

    test('matching title with wrong source commit is not adopted', () async {
      final correlation = 'provenance-correlation';
      final remoteId = _remoteId(correlation);
      final branch = 'cantiere-build/$remoteId';
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/git/ref/heads/$branch')) {
          return http.Response(
            '{"object":{"sha":"$stagedCommit"}}',
            200,
          );
        }
        if (path.endsWith('/runs')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'workflow_runs': <Object?>[
                _runJson(
                  id: 42,
                  remoteId: remoteId,
                  headSha: baseCommit,
                  status: 'completed',
                  conclusion: 'success',
                ),
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });

      final recovered = await _gateway(client).discoverRun(
        request: _request(workspace.path),
        correlationId: correlation,
      );

      expect(recovered, isNull);
    });

    test('normalizes one-shot run and artifact observations', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/actions/runs/77')) {
          return http.Response(
            jsonEncode(
              _runJson(
                id: 77,
                remoteId: 'unused',
                headSha: stagedCommit,
                status: 'completed',
                conclusion: 'success',
              ),
            ),
            200,
          );
        }
        if (path.endsWith('/actions/runs/77/artifacts')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'artifacts': <Object?>[
                <String, Object?>{
                  'id': 901,
                  'name': 'cantiere-android-demo',
                  'archive_download_url': 'https://api.github.test/artifacts/901',
                  'size_in_bytes': 12345,
                  'expired': false,
                  'created_at': '2026-10-03T18:00:00Z',
                  'expires_at': '2026-10-10T18:00:00Z',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });

      final gateway = _gateway(client);
      final run = await gateway.getRun(77);
      final artifacts = await gateway.getArtifacts(77);

      expect(run, isNotNull);
      expect(run!.succeeded, isTrue);
      expect(run.runNumber, 7);
      expect(artifacts, hasLength(1));
      expect(artifacts.single.id, 901);
      expect(artifacts.single.isDownloadable, isTrue);
    });

    test('invalid generated source fails definitively before dispatch', () async {
      await File('${workspace.path}/lib/main.dart').delete();
      await File('${workspace.path}/pubspec.yaml').writeAsString('name: demo\n');
      final client = MockClient((request) async {
        if (_isRepositoryRoot(request.url.path)) {
          return http.Response('{"private":true}', 200);
        }
        return http.Response('unexpected', 500);
      });

      try {
        await _gateway(client).dispatch(
          request: _request(workspace.path),
          correlationId: 'invalid-source',
        );
        fail('dispatch should have failed before staging');
      } on WorkshopDurableGitHubGatewayException catch (error) {
        expect(error.definitive, isTrue);
        expect(error.failureClass, WorkshopDurableFailureClass.codeError);
      }
    });
  });
}

WorkshopPrivateGitHubDurableGateway _gateway(
  http.Client client, {
  WorkshopDurableSourceResolve? sourceResolver,
}) {
  return WorkshopPrivateGitHubDurableGateway(
    configuration: const WorkshopPrivateGitHubBuildConfiguration(
      repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
      workflowFile: 'build-cantiere-android.yml',
      baseBranch: 'main',
      requirePrivateRepository: true,
    ),
    accessTokenProvider: () async => 'token',
    client: client,
    // Only the historical gateway tests use an explicitly provided, mutable
    // source resolver. There is NO live-snapshot fallback in production.
    sourceResolver: sourceResolver ??
        ({required request, required correlationId}) =>
            const WorkshopBuildSourceSnapshotter().capture(
              request.projectPath,
            ),
  );
}

WorkshopBuildRequest _request(String path) {
  return WorkshopBuildRequest(
    id: 'build-v1-test',
    projectId: 'project-1',
    projectPath: path,
    target: WorkshopBuildTarget.android,
    appDisplayName: 'Durable Demo',
    mode: WorkshopBuildExecutionMode.remote,
  );
}

bool _isRepositoryRoot(String path) {
  return path == '/repos/pilialvu75-hue/AI-Orchestrator-Module-Library';
}

String _remoteId(String correlationId) {
  final digest = sha256.convert(utf8.encode(correlationId)).toString();
  return 'b-${digest.substring(0, 24)}';
}

Map<String, Object?> _runJson({
  required int id,
  required String remoteId,
  required String headSha,
  required String status,
  String? conclusion,
}) {
  return <String, Object?>{
    'id': id,
    'display_title': 'Cantiere Android build [$remoteId]',
    'status': status,
    'conclusion': conclusion,
    'html_url': 'https://github.test/actions/runs/$id',
    'name': 'Cantiere Private Android Build',
    'head_branch': 'cantiere-build/$remoteId',
    'head_sha': headSha,
    'run_number': 7,
    'created_at': '2026-10-03T18:00:00Z',
    'updated_at': '2026-10-03T18:01:00Z',
  };
}

final class _MemoryGenerationStorage implements WorkshopDurableGenerationStorage {
  String? _record;

  @override
  Future<String?> read() async => _record;

  @override
  Future<bool> write(String value) async {
    _record = value;
    return true;
  }
}
