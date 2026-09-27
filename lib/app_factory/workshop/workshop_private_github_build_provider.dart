import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'workshop_build_lab.dart';
import 'workshop_build_source_snapshot.dart';

typedef WorkshopBuildAccessTokenProvider = Future<String> Function();
typedef WorkshopBuildDelay = Future<void> Function(Duration duration);
typedef WorkshopBuildNow = DateTime Function();

final class WorkshopPrivateGitHubBuildConfiguration {
  const WorkshopPrivateGitHubBuildConfiguration({
    required this.repository,
    this.workflowFile = 'build-cantiere-android.yml',
    this.baseBranch = 'main',
    this.requirePrivateRepository = true,
  });

  final String repository;
  final String workflowFile;
  final String baseBranch;
  final bool requirePrivateRepository;
}

/// Remote build executor used when the device cannot host a Flutter/Android
/// toolchain itself.
///
/// Cantiere still owns Project/Execution and the generated workspace. This
/// provider only moves one bounded snapshot to a temporary branch in a private
/// GitHub repository, invokes a generic build workflow, verifies the returned
/// artifact and materializes the APK back into local Cantiere storage.
final class WorkshopPrivateGitHubBuildProvider implements WorkshopBuildProvider {
  WorkshopPrivateGitHubBuildProvider({
    required WorkshopPrivateGitHubBuildConfiguration configuration,
    required WorkshopBuildAccessTokenProvider accessTokenProvider,
    http.Client? client,
    WorkshopBuildSourceSnapshotter snapshotter =
        const WorkshopBuildSourceSnapshotter(),
    WorkshopBuildDelay? delay,
    WorkshopBuildNow? now,
    this.pollInterval = const Duration(seconds: 3),
    this.timeout = const Duration(minutes: 30),
  })  : _configuration = configuration,
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client(),
        _snapshotter = snapshotter,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now {
    _validateConfiguration(configuration);
  }

  final WorkshopPrivateGitHubBuildConfiguration _configuration;
  final WorkshopBuildAccessTokenProvider _accessTokenProvider;
  final http.Client _client;
  final WorkshopBuildSourceSnapshotter _snapshotter;
  final WorkshopBuildDelay _delay;
  final WorkshopBuildNow _now;

  final Duration pollInterval;
  final Duration timeout;

  final Set<String> _cancelled = <String>{};

  @override
  WorkshopBuildExecutionMode get executionMode => WorkshopBuildExecutionMode.remote;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    if (target != WorkshopBuildTarget.android) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode: executionMode,
        name: 'Private GitHub Actions',
        message: 'This executor currently supports Android only.',
      );
    }

    try {
      final token = await _token();
      final repo = await _getJson('', token: token);
      if (_configuration.requirePrivateRepository && repo['private'] != true) {
        return WorkshopToolchainInfo(
          target: target,
          status: WorkshopToolchainStatus.unavailable,
          executionMode: executionMode,
          name: 'Private GitHub Actions',
          message: 'Configured build repository is not private.',
        );
      }

      await _getJson(
        'actions/workflows/${Uri.encodeComponent(_configuration.workflowFile)}',
        token: token,
      );
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.available,
        executionMode: executionMode,
        name: 'Private GitHub Actions',
        message: 'Private Android build executor is available.',
      );
    } catch (error) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode: executionMode,
        name: 'Private GitHub Actions',
        message: _boundedError(error),
      );
    }
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    final startedAt = _now().toUtc();
    if (request.target != WorkshopBuildTarget.android) {
      return _failure(
        request,
        startedAt,
        'Private GitHub build currently supports Android only.',
        'remote_target_unsupported',
      );
    }

    final remoteId = _remoteRequestId(request.id);
    String? branch;
    String? token;

    try {
      _throwIfCancelled(request.id);
      token = await _token();
      await _requirePrivateRepository(token);

      final snapshot = await _snapshotter.capture(request.projectPath);
      _throwIfCancelled(request.id);

      final staged = await _stageSnapshot(
        token: token,
        snapshot: snapshot,
        request: request,
        remoteId: remoteId,
      );
      branch = staged.branch;
      _throwIfCancelled(request.id);

      await _dispatch(
        token: token,
        branch: staged.branch,
        remoteId: remoteId,
      );

      final deadline = _now().toUtc().add(timeout);
      final runId = await _waitForRun(
        token: token,
        branch: staged.branch,
        remoteId: remoteId,
        stagedCommit: staged.commitSha,
        deadline: deadline,
        requestId: request.id,
      );
      await _waitForCompletion(
        token: token,
        runId: runId,
        deadline: deadline,
        requestId: request.id,
      );
      _throwIfCancelled(request.id);

      final artifact = await _downloadAndVerifyArtifact(
        token: token,
        runId: runId,
        remoteId: remoteId,
        expectedSourceCommit: staged.commitSha,
      );
      final localArtifact = await _materializeArtifact(
        request: request,
        remoteId: remoteId,
        bytes: artifact.apkBytes,
      );

      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.succeeded,
        startedAt: startedAt,
        finishedAt: _now().toUtc(),
        artifactPath: localArtifact.path,
        message: 'Android APK built and verified by the private remote executor.',
        exitCode: 0,
        testsPassed: true,
        analysisPassed: true,
        formatPassed: true,
      );
    } on _WorkshopRemoteBuildCancelled {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.cancelled,
        startedAt: startedAt,
        finishedAt: _now().toUtc(),
        message: 'Remote Android build monitoring was cancelled.',
      );
    } on _WorkshopRemoteBuildFailure catch (error) {
      return _failure(
        request,
        startedAt,
        error.message,
        error.code,
        stderr: error.diagnostics,
        exitCode: 1,
      );
    } on TimeoutException catch (error) {
      return _failure(
        request,
        startedAt,
        _boundedError(error),
        'remote_build_timeout',
      );
    } catch (error) {
      return _failure(
        request,
        startedAt,
        _boundedError(error),
        'remote_build_failed',
      );
    } finally {
      if (branch != null && token != null) {
        try {
          await _deleteBranch(token: token, branch: branch);
        } catch (_) {
          // Source cleanup is best-effort and must never turn a verified APK
          // into a failed build. Branch names contain no secret material.
        }
      }
      _cancelled.remove(request.id);
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    _cancelled.add(requestId);
  }

  Future<String> _token() async {
    final token = (await _accessTokenProvider()).trim();
    if (token.isEmpty) {
      throw StateError('GitHub build authorization is missing or expired.');
    }
    return token;
  }

  Future<void> _requirePrivateRepository(String token) async {
    final repo = await _getJson('', token: token);
    if (_configuration.requirePrivateRepository && repo['private'] != true) {
      throw StateError(
        'Refusing to stage Cantiere project source in a public repository.',
      );
    }
  }

  Future<_StagedBuildSource> _stageSnapshot({
    required String token,
    required WorkshopBuildSourceSnapshot snapshot,
    required WorkshopBuildRequest request,
    required String remoteId,
  }) async {
    final baseRef = await _getJson(
      'git/ref/heads/${_configuration.baseBranch}',
      token: token,
    );
    final object = baseRef['object'];
    if (object is! Map || object['sha'] is! String) {
      throw const FormatException('GitHub base ref is missing its commit SHA.');
    }
    final baseCommitSha = (object['sha'] as String).trim();
    _requireSha(baseCommitSha, 'base commit');

    final baseCommit = await _getJson(
      'git/commits/$baseCommitSha',
      token: token,
    );
    final tree = baseCommit['tree'];
    if (tree is! Map || tree['sha'] is! String) {
      throw const FormatException('GitHub base commit is missing its tree SHA.');
    }
    final baseTreeSha = (tree['sha'] as String).trim();
    _requireSha(baseTreeSha, 'base tree');

    final entries = <Map<String, Object?>>[];
    for (final file in snapshot.files) {
      _throwIfCancelled(request.id);
      final blob = await _postJson(
        'git/blobs',
        token: token,
        body: <String, Object?>{
          'content': base64Encode(file.bytes),
          'encoding': 'base64',
        },
      );
      final sha = blob['sha']?.toString().trim() ?? '';
      _requireSha(sha, 'source blob');
      entries.add(<String, Object?>{
        'path': '.cantiere-build/source/${file.relativePath}',
        'mode': '100644',
        'type': 'blob',
        'sha': sha,
      });
    }

    final manifestBytes = utf8.encode(jsonEncode(<String, Object?>{
      'version': 1,
      'request_id': remoteId,
      'project_id': request.projectId,
      'target': request.target.name,
      'file_count': snapshot.files.length,
      'source_bytes': snapshot.totalBytes,
    }));
    final manifestBlob = await _postJson(
      'git/blobs',
      token: token,
      body: <String, Object?>{
        'content': base64Encode(manifestBytes),
        'encoding': 'base64',
      },
    );
    final manifestSha = manifestBlob['sha']?.toString().trim() ?? '';
    _requireSha(manifestSha, 'manifest blob');
    entries.add(<String, Object?>{
      'path': '.cantiere-build/manifest.json',
      'mode': '100644',
      'type': 'blob',
      'sha': manifestSha,
    });

    final createdTree = await _postJson(
      'git/trees',
      token: token,
      body: <String, Object?>{
        'base_tree': baseTreeSha,
        'tree': entries,
      },
    );
    final createdTreeSha = createdTree['sha']?.toString().trim() ?? '';
    _requireSha(createdTreeSha, 'staged tree');

    final createdCommit = await _postJson(
      'git/commits',
      token: token,
      body: <String, Object?>{
        'message': 'cantiere-build: stage $remoteId',
        'tree': createdTreeSha,
        'parents': <String>[baseCommitSha],
      },
    );
    final commitSha = createdCommit['sha']?.toString().trim() ?? '';
    _requireSha(commitSha, 'staged commit');

    final branch = 'cantiere-build/$remoteId';
    await _postJson(
      'git/refs',
      token: token,
      body: <String, Object?>{
        'ref': 'refs/heads/$branch',
        'sha': commitSha,
      },
    );

    return _StagedBuildSource(branch: branch, commitSha: commitSha);
  }

  Future<void> _dispatch({
    required String token,
    required String branch,
    required String remoteId,
  }) async {
    final response = await _client.post(
      _api('actions/workflows/${Uri.encodeComponent(_configuration.workflowFile)}/dispatches'),
      headers: _headers(token, json: true),
      body: jsonEncode(<String, Object?>{
        'ref': branch,
        'inputs': <String, String>{
          'request_id': remoteId,
          'source_root': '.cantiere-build/source',
          'target': 'android',
        },
      }),
    );
    if (response.statusCode == 204) return;
    throw StateError(
      _httpFailure('Unable to start private Android build', response.statusCode),
    );
  }

  Future<int> _waitForRun({
    required String token,
    required String branch,
    required String remoteId,
    required String stagedCommit,
    required DateTime deadline,
    required String requestId,
  }) async {
    while (_now().toUtc().isBefore(deadline)) {
      _throwIfCancelled(requestId);
      final response = await _client.get(
        _api(
          'actions/workflows/${Uri.encodeComponent(_configuration.workflowFile)}/runs',
          <String, String>{
            'event': 'workflow_dispatch',
            'branch': branch,
            'per_page': '20',
          },
        ),
        headers: _headers(token),
      );
      if (response.statusCode != 200) {
        throw StateError(
          _httpFailure('Unable to locate private Android build', response.statusCode),
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['workflow_runs'] is! List) {
        throw const FormatException('GitHub workflow list is invalid.');
      }
      for (final raw in decoded['workflow_runs'] as List) {
        if (raw is! Map) continue;
        final title = raw['display_title']?.toString() ?? '';
        final headSha = raw['head_sha']?.toString() ?? '';
        final id = raw['id'];
        if (title.contains('[$remoteId]') &&
            headSha == stagedCommit &&
            id is num) {
          return id.toInt();
        }
      }
      await _delay(pollInterval);
    }
    throw TimeoutException('GitHub did not start the private Android build in time.');
  }

  Future<void> _waitForCompletion({
    required String token,
    required int runId,
    required DateTime deadline,
    required String requestId,
  }) async {
    while (_now().toUtc().isBefore(deadline)) {
      _throwIfCancelled(requestId);
      final run = await _getJson('actions/runs/$runId', token: token);
      if (run['status'] == 'completed') {
        if (run['conclusion'] == 'success') return;
        final conclusion = run['conclusion']?.toString() ?? 'unknown';
        final failure = await _diagnoseFailedRun(
          token: token,
          runId: runId,
          conclusion: conclusion,
        );
        throw failure;
      }
      await _delay(pollInterval);
    }
    throw TimeoutException('Private Android build did not finish in time.');
  }

  Future<_WorkshopRemoteBuildFailure> _diagnoseFailedRun({
    required String token,
    required int runId,
    required String conclusion,
  }) async {
    String? failedStep;
    int? failedJobId;

    try {
      final response = await _client.get(
        _api('actions/runs/$runId/jobs', const <String, String>{
          'per_page': '20',
        }),
        headers: _headers(token),
      );
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['jobs'] is List) {
          for (final rawJob in decoded['jobs'] as List) {
            if (rawJob is! Map || rawJob['conclusion'] != 'failure') continue;
            final id = rawJob['id'];
            if (id is num) failedJobId = id.toInt();
            final steps = rawJob['steps'];
            if (steps is List) {
              for (final rawStep in steps) {
                if (rawStep is! Map || rawStep['conclusion'] != 'failure') {
                  continue;
                }
                failedStep = rawStep['name']?.toString().trim();
                break;
              }
            }
            break;
          }
        }
      }
    } catch (_) {
      // Diagnostics are best effort. Failure classification below remains
      // conservative if GitHub does not expose jobs/logs.
    }

    var diagnostics = '';
    if (failedJobId != null) {
      try {
        final response = await _client.get(
          _api('actions/jobs/$failedJobId/logs'),
          headers: _headers(token),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          diagnostics = _boundedBuildLog(response.body);
        }
      } catch (_) {
        // Keep the failed step classification even when logs are unavailable.
      }
    }

    final code = WorkshopPrivateBuildFailureClassifier.codeForStep(failedStep);
    final stepLabel =
        failedStep == null || failedStep.isEmpty ? 'unknown step' : failedStep;
    return _WorkshopRemoteBuildFailure(
      code: code,
      message:
          'Private Android build completed with $conclusion at $stepLabel.',
      diagnostics: diagnostics,
    );
  }

  static String _boundedBuildLog(String value, {int maxChars = 6000}) {
    final normalized = value.replaceAll('\u0000', '').trim();
    if (normalized.length <= maxChars) return normalized;
    return '[... remote build log truncated ...]\n'
        '${normalized.substring(normalized.length - maxChars)}';
  }

  Future<_VerifiedRemoteArtifact> _downloadAndVerifyArtifact({
    required String token,
    required int runId,
    required String remoteId,
    required String expectedSourceCommit,
  }) async {
    final artifactsResponse = await _client.get(
      _api('actions/runs/$runId/artifacts'),
      headers: _headers(token),
    );
    if (artifactsResponse.statusCode != 200) {
      throw StateError(
        _httpFailure('Unable to list private Android artifacts', artifactsResponse.statusCode),
      );
    }
    final decoded = jsonDecode(artifactsResponse.body);
    if (decoded is! Map || decoded['artifacts'] is! List) {
      throw const FormatException('GitHub artifact list is invalid.');
    }

    int? artifactId;
    final expectedName = 'cantiere-android-$remoteId';
    for (final raw in decoded['artifacts'] as List) {
      if (raw is! Map || raw['name'] != expectedName || raw['expired'] == true) {
        continue;
      }
      final id = raw['id'];
      if (id is num) {
        artifactId = id.toInt();
        break;
      }
    }
    if (artifactId == null) {
      throw StateError('Verified private Android artifact was not found.');
    }

    final archiveResponse = await _client.get(
      _api('actions/artifacts/$artifactId/zip'),
      headers: _headers(token),
    );
    if (archiveResponse.statusCode != 200) {
      throw StateError(
        _httpFailure('Unable to download private Android artifact', archiveResponse.statusCode),
      );
    }

    final archive = ZipDecoder().decodeBytes(archiveResponse.bodyBytes);
    List<int>? apk;
    Map<String, dynamic>? manifest;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final content = file.content;
      if (content is! List<int>) continue;
      if (file.name.endsWith('app-release.apk')) {
        apk = List<int>.from(content);
      } else if (file.name.endsWith('build-manifest.json')) {
        final value = jsonDecode(utf8.decode(content));
        if (value is Map) manifest = Map<String, dynamic>.from(value);
      }
    }
    if (apk == null || apk.isEmpty || manifest == null) {
      throw const FormatException('Private Android artifact is incomplete.');
    }

    if (manifest['request_id'] != remoteId ||
        manifest['target'] != 'android' ||
        manifest['source_commit'] != expectedSourceCommit ||
        manifest['apk'] != 'app-release.apk') {
      throw const FormatException('Private Android artifact provenance does not match the build request.');
    }

    final expectedBytes = manifest['apk_bytes'];
    final expectedHash = manifest['apk_sha256']?.toString().toLowerCase();
    final actualHash = sha256.convert(apk).toString();
    if (expectedBytes is! int ||
        expectedBytes != apk.length ||
        expectedHash == null ||
        expectedHash != actualHash) {
      throw const FormatException('Private Android artifact hash/size verification failed.');
    }

    final validation = manifest['validation'];
    if (validation is! Map ||
        validation['format'] != 'passed' ||
        validation['analyze'] != 'passed' ||
        validation['build'] != 'passed') {
      throw const FormatException('Private Android artifact validation manifest is not fully verified.');
    }

    return _VerifiedRemoteArtifact(apkBytes: apk);
  }

  Future<File> _materializeArtifact({
    required WorkshopBuildRequest request,
    required String remoteId,
    required List<int> bytes,
  }) async {
    final root = Directory(
      p.join(request.projectPath, '.cantiere_artifacts', remoteId),
    );
    await root.create(recursive: true);
    final file = File(p.join(root.path, 'app-release.apk'));
    await file.writeAsBytes(bytes, flush: true);
    if (!await file.exists() || await file.length() != bytes.length) {
      throw StateError('Verified APK could not be materialized locally.');
    }
    return file;
  }

  Future<void> _deleteBranch({required String token, required String branch}) async {
    final response = await _client.delete(
      _api('git/refs/heads/$branch'),
      headers: _headers(token),
    );
    if (response.statusCode == 204 || response.statusCode == 404) return;
    throw StateError('Temporary Cantiere build branch could not be deleted.');
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String token,
  }) async {
    final response = await _client.get(_api(path), headers: _headers(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_httpFailure('GitHub build API request failed', response.statusCode));
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('GitHub build API returned invalid JSON.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required String token,
    required Map<String, Object?> body,
  }) async {
    final response = await _client.post(
      _api(path),
      headers: _headers(token, json: true),
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_httpFailure('GitHub build API mutation failed', response.statusCode));
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('GitHub build API mutation returned invalid JSON.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, String> _headers(String token, {bool json = false}) => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-cantiere-build/1',
        if (json) 'Content-Type': 'application/json',
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

  void _throwIfCancelled(String requestId) {
    if (_cancelled.contains(requestId)) throw const _WorkshopRemoteBuildCancelled();
  }

  WorkshopBuildResult _failure(
    WorkshopBuildRequest request,
    DateTime startedAt,
    String message,
    String code, {
    String stderr = '',
    int? exitCode,
  }) {
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: startedAt,
      finishedAt: _now().toUtc(),
      message: message,
      stderr: stderr,
      exitCode: exitCode,
      errors: <String>[code],
    );
  }

  static String _remoteRequestId(String requestId) {
    final digest = sha256.convert(utf8.encode(requestId)).toString();
    return 'b-${digest.substring(0, 24)}';
  }

  static String _httpFailure(String operation, int statusCode) {
    if (statusCode == 401) return '$operation: GitHub authorization expired.';
    if (statusCode == 403) {
      return '$operation: GitHub permission, Actions quota, or rate limit denied the request.';
    }
    if (statusCode == 404) {
      return '$operation: private build repository/workflow is unavailable to this authorization.';
    }
    return '$operation (HTTP $statusCode).';
  }

  static String _boundedError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return text.length <= 500 ? text : '${text.substring(0, 500)}…';
  }

  static void _requireSha(String value, String label) {
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(value)) {
      throw FormatException('GitHub $label SHA is invalid.');
    }
  }

  static void _validateConfiguration(
    WorkshopPrivateGitHubBuildConfiguration configuration,
  ) {
    final repository = configuration.repository.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw ArgumentError.value(repository, 'repository', 'Invalid GitHub repository.');
    }
    if (configuration.workflowFile.trim().isEmpty ||
        configuration.baseBranch.trim().isEmpty) {
      throw ArgumentError('GitHub build workflow/base branch cannot be empty.');
    }
  }
}

/// Maps the failed private CI step to a safe build-failure class.
///
/// Only failures caused by generated project content are eligible for the
/// bounded Cantiere repair loop. Toolchain/security/artifact infrastructure
/// remains non-repairable by the model.
abstract final class WorkshopPrivateBuildFailureClassifier {
  static String codeForStep(String? rawStep) {
    final step = rawStep?.trim() ?? '';
    switch (step) {
      case 'Resolve dependencies':
        return 'remote_dependency_resolution_failed';
      case 'Validate generated project':
        return 'remote_validation_failed';
      case 'Build Android APK':
        return 'remote_project_build_failed';
      default:
        return 'remote_infrastructure_failed';
    }
  }
}

final class _StagedBuildSource {
  const _StagedBuildSource({required this.branch, required this.commitSha});

  final String branch;
  final String commitSha;
}

final class _VerifiedRemoteArtifact {
  const _VerifiedRemoteArtifact({required this.apkBytes});

  final List<int> apkBytes;
}

final class _WorkshopRemoteBuildFailure implements Exception {
  const _WorkshopRemoteBuildFailure({
    required this.code,
    required this.message,
    required this.diagnostics,
  });

  final String code;
  final String message;
  final String diagnostics;

  @override
  String toString() => message;
}

final class _WorkshopRemoteBuildCancelled implements Exception {
  const _WorkshopRemoteBuildCancelled();
}
