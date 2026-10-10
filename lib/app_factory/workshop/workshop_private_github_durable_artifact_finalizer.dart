import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'durable/workshop_durable_github_actions_coordinator.dart';
import 'durable/workshop_durable_orchestrator.dart';
import 'workshop_build_lab.dart';
import 'workshop_private_github_build_provider.dart';

/// Final verification/materialization boundary for a durable private GitHub
/// Android build.
///
/// A successful GitHub workflow is not sufficient to complete a Cantiere
/// build. This finalizer re-derives the staged branch from the persisted
/// correlation id, binds the artifact manifest to that exact source commit,
/// verifies APK size/hash and validation receipts, then materializes the APK in
/// local Cantiere storage. Only a verified result may be promoted to COMPLETED.
final class WorkshopPrivateGitHubDurableArtifactFinalizer {
  WorkshopPrivateGitHubDurableArtifactFinalizer({
    required WorkshopPrivateGitHubBuildConfiguration configuration,
    required WorkshopBuildAccessTokenProvider accessTokenProvider,
    http.Client? client,
    DateTime Function()? now,
  })  : _configuration = configuration,
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final WorkshopPrivateGitHubBuildConfiguration _configuration;
  final WorkshopBuildAccessTokenProvider _accessTokenProvider;
  final http.Client _client;
  final DateTime Function() _now;

  Future<WorkshopBuildResult> finalize({
    required WorkshopBuildRequest request,
    required String correlationId,
    required int runId,
  }) async {
    final startedAt = _now().toUtc();
    if (request.target != WorkshopBuildTarget.android) {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable private GitHub finalization currently supports Android only.',
        failureClass: WorkshopDurableFailureClass.policyBlocked,
        definitive: true,
      );
    }
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }

    final token = await _tokenForObservation();
    final remoteId = _remoteRequestId(correlationId);
    final branch = 'cantiere-build/$remoteId';
    final expectedSourceCommit = await _stagedCommit(
      token: token,
      branch: branch,
    );

    final artifactId = await _artifactId(
      token: token,
      runId: runId,
      remoteId: remoteId,
    );
    final verified = await _downloadAndVerify(
      token: token,
      artifactId: artifactId,
      request: request,
      remoteId: remoteId,
      expectedSourceCommit: expectedSourceCommit,
    );
    final file = await _materialize(
      request: request,
      remoteId: remoteId,
      bytes: verified.apkBytes,
    );

    // Cleanup is best effort and happens only after a fully verified APK is
    // safely present locally. A cleanup failure must not invalidate the artifact.
    try {
      await _deleteBranch(token: token, branch: branch);
    } catch (_) {}

    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: startedAt,
      finishedAt: _now().toUtc(),
      artifactPath: file.path,
      message: 'Durable Android APK verified and materialized.',
      exitCode: 0,
      testsPassed: true,
      analysisPassed: true,
      formatPassed: true,
    );
  }

  Future<String> _stagedCommit({
    required String token,
    required String branch,
  }) async {
    final response = await _observeGet(
      'git/ref/heads/$branch',
      token: token,
    );
    _requireSuccess(response, 'Unable to inspect durable build source branch');
    final decoded = _decodeObject(response.body, 'GitHub branch ref');
    final object = decoded['object'];
    final sha = object is Map ? object['sha']?.toString().trim() : null;
    if (sha == null || !RegExp(r'^[a-f0-9]{40}$').hasMatch(sha)) {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable build source branch has invalid provenance.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }
    return sha;
  }

  Future<int> _artifactId({
    required String token,
    required int runId,
    required String remoteId,
  }) async {
    final response = await _observeGet(
      'actions/runs/$runId/artifacts',
      token: token,
      query: const <String, String>{'per_page': '100'},
    );
    _requireSuccess(response, 'Unable to list durable Android artifacts');
    final decoded = _decodeObject(response.body, 'GitHub artifact list');
    final artifacts = decoded['artifacts'];
    if (artifacts is! List) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub durable artifact list is invalid.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }

    final expectedName = 'cantiere-android-$remoteId';
    for (final raw in artifacts) {
      if (raw is! Map ||
          raw['name']?.toString() != expectedName ||
          raw['expired'] == true) {
        continue;
      }
      final id = raw['id'];
      if (id is num) return id.toInt();
    }
    throw WorkshopDurableGitHubGatewayException(
      'Verified durable Android artifact "$expectedName" was not found.',
      failureClass: WorkshopDurableFailureClass.invalidArtifact,
      definitive: true,
    );
  }

  Future<_VerifiedDurableArtifact> _downloadAndVerify({
    required String token,
    required int artifactId,
    required WorkshopBuildRequest request,
    required String remoteId,
    required String expectedSourceCommit,
  }) async {
    final response = await _observeGet(
      'actions/artifacts/$artifactId/zip',
      token: token,
    );
    _requireSuccess(response, 'Unable to download durable Android artifact');

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(response.bodyBytes);
    } catch (_) {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable Android artifact archive is invalid.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }

    List<int>? apk;
    Map<String, dynamic>? manifest;
    for (final file in archive.files) {
      if (!file.isFile || file.content is! List<int>) continue;
      final content = List<int>.from(file.content as List<int>);
      if (file.name.endsWith('app-release.apk')) {
        apk = content;
      } else if (file.name.endsWith('build-manifest.json')) {
        try {
          final decoded = jsonDecode(utf8.decode(content));
          if (decoded is Map) {
            manifest = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {
          throw const WorkshopDurableGitHubGatewayException(
            'Durable Android build manifest is invalid JSON.',
            failureClass: WorkshopDurableFailureClass.invalidArtifact,
            definitive: true,
          );
        }
      }
    }
    if (apk == null || apk.isEmpty || manifest == null) {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable Android artifact is incomplete.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }

    final expectedProjectName =
        WorkshopGeneratedAppIdentity.projectNameFor(request.projectId);
    final expectedDisplayName =
        WorkshopGeneratedAppIdentity.displayNameFor(request.appDisplayName);
    final expectedApplicationId =
        WorkshopGeneratedAppIdentity.applicationIdFor(request.projectId);

    if (manifest['request_id'] != remoteId ||
        manifest['project_name'] != expectedProjectName ||
        manifest['display_name'] != expectedDisplayName ||
        manifest['application_id'] != expectedApplicationId ||
        manifest['target'] != 'android' ||
        manifest['source_commit'] != expectedSourceCommit ||
        manifest['apk'] != 'app-release.apk') {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable Android artifact provenance does not match the build request.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }

    final expectedBytes = manifest['apk_bytes'];
    final expectedHash = manifest['apk_sha256']?.toString().toLowerCase();
    final actualHash = sha256.convert(apk).toString();
    if (expectedBytes is! int ||
        expectedBytes != apk.length ||
        expectedHash == null ||
        expectedHash != actualHash) {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable Android APK hash/size verification failed.',
        failureClass: WorkshopDurableFailureClass.invalidArtifact,
        definitive: true,
      );
    }

    final validation = manifest['validation'];
    if (validation is! Map ||
        validation['format'] != 'passed' ||
        validation['analyze'] != 'passed' ||
        validation['build'] != 'passed') {
      throw const WorkshopDurableGitHubGatewayException(
        'Durable Android artifact validation receipt is not fully verified.',
        failureClass: WorkshopDurableFailureClass.validationFailed,
        definitive: true,
      );
    }

    return _VerifiedDurableArtifact(apkBytes: apk);
  }

  Future<File> _materialize({
    required WorkshopBuildRequest request,
    required String remoteId,
    required List<int> bytes,
  }) async {
    final root = Directory(
      p.join(request.projectPath, '.cantiere_artifacts', remoteId),
    );
    try {
      await root.create(recursive: true);
      final file = File(p.join(root.path, 'app-release.apk'));
      await file.writeAsBytes(bytes, flush: true);
      if (!await file.exists() || await file.length() != bytes.length) {
        throw StateError('materialized APK length mismatch');
      }
      return file;
    } catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        'Verified APK could not be materialized locally: ${_boundedError(error)}',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }
  }

  Future<void> _deleteBranch({
    required String token,
    required String branch,
  }) async {
    final response = await _client.delete(
      _api('git/refs/heads/$branch'),
      headers: _headers(token),
    );
    if (response.statusCode == 204 || response.statusCode == 404) return;
    throw StateError('Durable temporary build branch could not be deleted.');
  }

  Future<String> _tokenForObservation() async {
    final token = (await _accessTokenProvider()).trim();
    if (token.isEmpty) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub build authorization is missing or expired.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }
    return token;
  }

  Future<http.Response> _observeGet(
    String path, {
    required String token,
    Map<String, String>? query,
  }) async {
    try {
      return await _client.get(_api(path, query), headers: _headers(token));
    } on TimeoutException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: false,
      );
    } on http.ClientException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: false,
      );
    } on SocketException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: false,
      );
    }
  }

  void _requireSuccess(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw WorkshopDurableGitHubGatewayException(
      '$operation (HTTP ${response.statusCode}).',
      failureClass: response.statusCode == 429
          ? WorkshopDurableFailureClass.rateLimit
          : WorkshopDurableFailureClass.providerUnavailable,
      definitive: false,
    );
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-cantiere-durable-finalizer/1',
      };

  Uri _api(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    final suffix = normalized.isEmpty ? '' : '/$normalized';
    return Uri.https(
      'api.github.com',
      '/repos/${_configuration.repository}$suffix',
      query,
    );
  }

  static Map<String, dynamic> _decodeObject(String body, String label) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw WorkshopDurableGitHubGatewayException(
      '$label returned invalid JSON.',
      failureClass: WorkshopDurableFailureClass.invalidArtifact,
      definitive: true,
    );
  }

  static String _remoteRequestId(String correlationId) {
    final normalized = correlationId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        correlationId,
        'correlationId',
        'must not be empty',
      );
    }
    final digest = sha256.convert(utf8.encode(normalized)).toString();
    return 'b-${digest.substring(0, 24)}';
  }

  static String _boundedError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return text.length <= 500 ? text : '${text.substring(0, 500)}…';
  }
}

final class _VerifiedDurableArtifact {
  const _VerifiedDurableArtifact({required this.apkBytes});

  final List<int> apkBytes;
}
