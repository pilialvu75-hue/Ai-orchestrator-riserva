import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_github_actions_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_orchestrator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_durable_artifact_finalizer.dart';

void main() {
  const stagedCommit = '6666666666666666666666666666666666666666';
  const runId = 77;
  const correlation = 'durable-finalize-correlation';

  group('WorkshopPrivateGitHubDurableArtifactFinalizer', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('durable-finalize-');
    });

    tearDown(() async {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    });

    test('verifies provenance/hash/validation before materializing APK',
        () async {
      final apkBytes = utf8.encode('verified-apk-payload');
      final remoteId = _remoteId(correlation);
      final zipBytes = _artifactZip(
        request: _request(workspace.path),
        remoteId: remoteId,
        sourceCommit: stagedCommit,
        apkBytes: apkBytes,
      );
      var cleanupCalls = 0;

      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path.endsWith('/git/ref/heads/cantiere-build/$remoteId')) {
          return http.Response(
            '{"object":{"sha":"$stagedCommit"}}',
            200,
          );
        }
        if (request.method == 'GET' &&
            path.endsWith('/actions/runs/$runId/artifacts')) {
          return http.Response(
            jsonEncode(_artifactList(remoteId)),
            200,
          );
        }
        if (request.method == 'GET' &&
            path.endsWith('/actions/artifacts/901/zip')) {
          return http.Response.bytes(zipBytes, 200);
        }
        if (request.method == 'DELETE' &&
            path.endsWith('/git/refs/heads/cantiere-build/$remoteId')) {
          cleanupCalls += 1;
          return http.Response('', 204);
        }
        return http.Response('unexpected ${request.method} $path', 500);
      });

      final result = await _finalizer(client).finalize(
        request: _request(workspace.path),
        correlationId: correlation,
        runId: runId,
      );

      expect(result.succeeded, isTrue);
      expect(result.testsPassed, isTrue);
      expect(result.analysisPassed, isTrue);
      expect(result.formatPassed, isTrue);
      expect(cleanupCalls, 1);

      final artifact = File(result.artifactPath!);
      expect(await artifact.exists(), isTrue);
      expect(await artifact.readAsBytes(), apkBytes);
    });

    test('wrong source_commit is definitive invalid artifact and is not cleaned',
        () async {
      final apkBytes = utf8.encode('apk-with-wrong-source');
      final remoteId = _remoteId(correlation);
      final zipBytes = _artifactZip(
        request: _request(workspace.path),
        remoteId: remoteId,
        sourceCommit: '7777777777777777777777777777777777777777',
        apkBytes: apkBytes,
      );
      var cleanupCalls = 0;

      final client = _clientForArtifact(
        remoteId: remoteId,
        stagedCommit: stagedCommit,
        zipBytes: zipBytes,
        onCleanup: () => cleanupCalls += 1,
      );

      await expectLater(
        () => _finalizer(client).finalize(
          request: _request(workspace.path),
          correlationId: correlation,
          runId: runId,
        ),
        throwsA(
          isA<WorkshopDurableGitHubGatewayException>()
              .having(
                (error) => error.failureClass,
                'failureClass',
                WorkshopDurableFailureClass.invalidArtifact,
              )
              .having((error) => error.definitive, 'definitive', isTrue),
        ),
      );

      expect(cleanupCalls, 0);
      expect(await _materializedApk(workspace.path, remoteId).exists(), isFalse);
    });

    test('wrong APK hash is definitive invalid artifact', () async {
      final apkBytes = utf8.encode('actual-apk');
      final remoteId = _remoteId(correlation);
      final zipBytes = _artifactZip(
        request: _request(workspace.path),
        remoteId: remoteId,
        sourceCommit: stagedCommit,
        apkBytes: apkBytes,
        apkHashOverride: sha256.convert(utf8.encode('other-apk')).toString(),
      );

      await expectLater(
        () => _finalizer(
          _clientForArtifact(
            remoteId: remoteId,
            stagedCommit: stagedCommit,
            zipBytes: zipBytes,
          ),
        ).finalize(
          request: _request(workspace.path),
          correlationId: correlation,
          runId: runId,
        ),
        throwsA(
          isA<WorkshopDurableGitHubGatewayException>()
              .having(
                (error) => error.failureClass,
                'failureClass',
                WorkshopDurableFailureClass.invalidArtifact,
              )
              .having((error) => error.definitive, 'definitive', isTrue),
        ),
      );

      expect(await _materializedApk(workspace.path, remoteId).exists(), isFalse);
    });

    test('incomplete validation receipt fails as validationFailed', () async {
      final apkBytes = utf8.encode('apk-invalid-validation');
      final remoteId = _remoteId(correlation);
      final zipBytes = _artifactZip(
        request: _request(workspace.path),
        remoteId: remoteId,
        sourceCommit: stagedCommit,
        apkBytes: apkBytes,
        validation: const <String, String>{
          'format': 'passed',
          'analyze': 'failed',
          'build': 'passed',
        },
      );

      await expectLater(
        () => _finalizer(
          _clientForArtifact(
            remoteId: remoteId,
            stagedCommit: stagedCommit,
            zipBytes: zipBytes,
          ),
        ).finalize(
          request: _request(workspace.path),
          correlationId: correlation,
          runId: runId,
        ),
        throwsA(
          isA<WorkshopDurableGitHubGatewayException>()
              .having(
                (error) => error.failureClass,
                'failureClass',
                WorkshopDurableFailureClass.validationFailed,
              )
              .having((error) => error.definitive, 'definitive', isTrue),
        ),
      );
    });

    test('transient artifact observation failure remains non-definitive',
        () async {
      final remoteId = _remoteId(correlation);
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/git/ref/heads/cantiere-build/$remoteId')) {
          return http.Response(
            '{"object":{"sha":"$stagedCommit"}}',
            200,
          );
        }
        if (path.endsWith('/actions/runs/$runId/artifacts')) {
          return http.Response('temporary outage', 503);
        }
        return http.Response('unexpected', 500);
      });

      await expectLater(
        () => _finalizer(client).finalize(
          request: _request(workspace.path),
          correlationId: correlation,
          runId: runId,
        ),
        throwsA(
          isA<WorkshopDurableGitHubGatewayException>()
              .having(
                (error) => error.failureClass,
                'failureClass',
                WorkshopDurableFailureClass.providerUnavailable,
              )
              .having((error) => error.definitive, 'definitive', isFalse),
        ),
      );
    });
  });
}

WorkshopPrivateGitHubDurableArtifactFinalizer _finalizer(http.Client client) {
  return WorkshopPrivateGitHubDurableArtifactFinalizer(
    configuration: const WorkshopPrivateGitHubBuildConfiguration(
      repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
      workflowFile: 'build-cantiere-android.yml',
      baseBranch: 'main',
      requirePrivateRepository: true,
    ),
    accessTokenProvider: () async => 'token',
    client: client,
    now: () => DateTime.utc(2026, 10, 3, 20),
  );
}

http.Client _clientForArtifact({
  required String remoteId,
  required String stagedCommit,
  required List<int> zipBytes,
  void Function()? onCleanup,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' &&
        path.endsWith('/git/ref/heads/cantiere-build/$remoteId')) {
      return http.Response(
        '{"object":{"sha":"$stagedCommit"}}',
        200,
      );
    }
    if (request.method == 'GET' &&
        path.endsWith('/actions/runs/77/artifacts')) {
      return http.Response(jsonEncode(_artifactList(remoteId)), 200);
    }
    if (request.method == 'GET' &&
        path.endsWith('/actions/artifacts/901/zip')) {
      return http.Response.bytes(zipBytes, 200);
    }
    if (request.method == 'DELETE' &&
        path.endsWith('/git/refs/heads/cantiere-build/$remoteId')) {
      onCleanup?.call();
      return http.Response('', 204);
    }
    return http.Response('unexpected ${request.method} $path', 500);
  });
}

Map<String, Object?> _artifactList(String remoteId) => <String, Object?>{
      'artifacts': <Object?>[
        <String, Object?>{
          'id': 901,
          'name': 'cantiere-android-$remoteId',
          'expired': false,
        },
      ],
    };

List<int> _artifactZip({
  required WorkshopBuildRequest request,
  required String remoteId,
  required String sourceCommit,
  required List<int> apkBytes,
  String? apkHashOverride,
  Map<String, String> validation = const <String, String>{
    'format': 'passed',
    'analyze': 'passed',
    'build': 'passed',
  },
}) {
  final manifest = <String, Object?>{
    'request_id': remoteId,
    'project_name': WorkshopGeneratedAppIdentity.projectNameFor(request.projectId),
    'display_name': WorkshopGeneratedAppIdentity.displayNameFor(
      request.appDisplayName,
    ),
    'application_id':
        WorkshopGeneratedAppIdentity.applicationIdFor(request.projectId),
    'target': 'android',
    'source_commit': sourceCommit,
    'apk': 'app-release.apk',
    'apk_bytes': apkBytes.length,
    'apk_sha256': apkHashOverride ?? sha256.convert(apkBytes).toString(),
    'validation': validation,
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final archive = Archive()
    ..addFile(ArchiveFile('app-release.apk', apkBytes.length, apkBytes))
    ..addFile(
      ArchiveFile(
        'build-manifest.json',
        manifestBytes.length,
        manifestBytes,
      ),
    );
  return ZipEncoder().encode(archive)!;
}

WorkshopBuildRequest _request(String projectPath) => WorkshopBuildRequest(
      id: 'caller-build-id',
      projectId: 'project-1',
      projectPath: projectPath,
      target: WorkshopBuildTarget.android,
      appDisplayName: 'Durable Finalizer Demo',
      mode: WorkshopBuildExecutionMode.remote,
    );

String _remoteId(String correlationId) {
  final digest = sha256.convert(utf8.encode(correlationId)).toString();
  return 'b-${digest.substring(0, 24)}';
}

File _materializedApk(String projectPath, String remoteId) => File(
      '$projectPath/.cantiere_artifacts/$remoteId/app-release.apk',
    );
