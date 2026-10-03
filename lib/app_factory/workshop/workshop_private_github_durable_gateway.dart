import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'durable/workshop_durable_github_actions_coordinator.dart';
import 'durable/workshop_durable_orchestrator.dart';
import 'workshop_build_lab.dart';
import 'workshop_build_source_snapshot.dart';
import 'workshop_github_build_monitor.dart';
import 'workshop_private_github_build_provider.dart';

/// One-shot GitHub Actions gateway for the Durable Orchestrator.
///
/// Unlike [WorkshopPrivateGitHubBuildProvider.build], this adapter never polls.
/// It stages and dispatches once, then lets the persisted durable coordinator
/// rediscover and observe the workflow in later reconciliation passes.
///
/// The historical polling provider remains available while this migration ring
/// is validated in production. No second project/execution lifecycle is owned
/// here; this class only implements the external GitHub boundary.
final class WorkshopPrivateGitHubDurableGateway
    implements WorkshopDurableGitHubActionsGateway {
  WorkshopPrivateGitHubDurableGateway({
    required WorkshopPrivateGitHubBuildConfiguration configuration,
    required WorkshopBuildAccessTokenProvider accessTokenProvider,
    http.Client? client,
    WorkshopBuildSourceSnapshotter snapshotter =
        const WorkshopBuildSourceSnapshotter(),
  })  : _configuration = configuration,
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client(),
        _snapshotter = snapshotter {
    _validateConfiguration(configuration);
  }

  final WorkshopPrivateGitHubBuildConfiguration _configuration;
  final WorkshopBuildAccessTokenProvider _accessTokenProvider;
  final http.Client _client;
  final WorkshopBuildSourceSnapshotter _snapshotter;

  @override
  Future<WorkshopDurableGitHubDispatchOutcome> dispatch({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    if (request.target != WorkshopBuildTarget.android) {
      return const WorkshopDurableGitHubDispatchOutcome(
        disposition: WorkshopDurableGitHubDispatchDisposition.rejected,
        failureClass: WorkshopDurableFailureClass.policyBlocked,
        message: 'Durable private GitHub build currently supports Android only.',
      );
    }

    final remoteId = _remoteRequestId(correlationId);
    final projectName =
        WorkshopGeneratedAppIdentity.projectNameFor(request.projectId);
    final applicationId =
        WorkshopGeneratedAppIdentity.applicationIdFor(request.projectId);
    final displayName =
        WorkshopGeneratedAppIdentity.displayNameFor(request.appDisplayName);

    late final String token;
    late final _DurableStagedBuildSource staged;
    try {
      token = await _token();
      await _requirePrivateRepository(token);
      final snapshot = await _snapshotter.capture(request.projectPath);
      final sourceBoundaryError =
          WorkshopAndroidBuildSourceBoundary.validate(snapshot);
      if (sourceBoundaryError != null) {
        throw WorkshopDurableGitHubGatewayException(
          sourceBoundaryError,
          failureClass: WorkshopDurableFailureClass.codeError,
          definitive: true,
        );
      }
      staged = await _stageSnapshot(
        token: token,
        snapshot: snapshot,
        request: request,
        remoteId: remoteId,
        projectName: projectName,
        applicationId: applicationId,
        displayName: displayName,
      );
    } on WorkshopDurableGitHubGatewayException {
      rethrow;
    } on TimeoutException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: true,
      );
    } on http.ClientException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: true,
      );
    } on SocketException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.networkError,
        definitive: true,
      );
    } catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        _boundedError(error),
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: true,
      );
    }

    try {
      final response = await _client.post(
        _api(
          'actions/workflows/'
          '${Uri.encodeComponent(_configuration.workflowFile)}/dispatches',
        ),
        headers: _headers(token, json: true),
        body: jsonEncode(<String, Object?>{
          'ref': staged.branch,
          'inputs': <String, String>{
            'request_id': remoteId,
            'source_root': '.cantiere-build/source',
            'project_name': projectName,
            'display_name': displayName,
            'target': 'android',
          },
        }),
      );
      if (response.statusCode == 204) {
        return WorkshopDurableGitHubDispatchOutcome.accepted;
      }
      if (response.statusCode >= 500) {
        return WorkshopDurableGitHubDispatchOutcome.ambiguous;
      }
      return WorkshopDurableGitHubDispatchOutcome(
        disposition: WorkshopDurableGitHubDispatchDisposition.rejected,
        failureClass: _failureClassForStatus(response.statusCode),
        message: _httpFailure(
          'Unable to start durable private Android build',
          response.statusCode,
        ),
      );
    } on TimeoutException {
      // The server may have accepted workflow_dispatch before the transport
      // timed out. The persisted correlation must be reconciled before any
      // caller is allowed to dispatch again.
      return WorkshopDurableGitHubDispatchOutcome.ambiguous;
    } on http.ClientException {
      return WorkshopDurableGitHubDispatchOutcome.ambiguous;
    } on SocketException {
      return WorkshopDurableGitHubDispatchOutcome.ambiguous;
    } catch (_) {
      return WorkshopDurableGitHubDispatchOutcome.ambiguous;
    }
  }

  @override
  Future<WorkshopGitHubRun?> discoverRun({
    required WorkshopBuildRequest request,
    required String correlationId,
  }) async {
    if (request.target != WorkshopBuildTarget.android) return null;

    final token = await _tokenForObservation();
    final remoteId = _remoteRequestId(correlationId);
    final branch = 'cantiere-build/$remoteId';

    final refResponse = await _observeGet(
      'git/ref/heads/$branch',
      token: token,
    );
    if (refResponse.statusCode == 404) return null;
    _requireObservationSuccess(
      refResponse,
      'Unable to inspect durable private build branch',
    );

    final refJson = _decodeObject(refResponse.body, 'GitHub branch ref');
    final object = refJson['object'];
    if (object is! Map || object['sha'] is! String) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub durable build branch is missing its commit SHA.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }
    final stagedCommit = (object['sha'] as String).trim();
    _requireSha(stagedCommit, 'durable staged commit');

    final runsResponse = await _observeGet(
      'actions/workflows/'
      '${Uri.encodeComponent(_configuration.workflowFile)}/runs',
      token: token,
      query: <String, String>{
        'event': 'workflow_dispatch',
        'branch': branch,
        'per_page': '50',
      },
    );
    _requireObservationSuccess(
      runsResponse,
      'Unable to discover durable private Android build',
    );

    final decoded = _decodeObject(runsResponse.body, 'GitHub workflow list');
    final rawRuns = decoded['workflow_runs'];
    if (rawRuns is! List) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub durable workflow list is invalid.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }

    for (final raw in rawRuns) {
      if (raw is! Map) continue;
      final value = Map<String, dynamic>.from(raw);
      final title = value['display_title']?.toString() ?? '';
      final headSha = value['head_sha']?.toString().trim() ?? '';
      final id = value['id'];
      if (id is num &&
          title.contains('[$remoteId]') &&
          headSha == stagedCommit) {
        return _decodeRun(value);
      }
    }
    return null;
  }

  @override
  Future<WorkshopGitHubRun?> getRun(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final token = await _tokenForObservation();
    final response = await _observeGet('actions/runs/$runId', token: token);
    if (response.statusCode == 404) return null;
    _requireObservationSuccess(response, 'Unable to observe GitHub Actions run');
    return _decodeRun(_decodeObject(response.body, 'GitHub Actions run'));
  }

  @override
  Future<List<WorkshopGitHubArtifact>> getArtifacts(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final token = await _tokenForObservation();
    final response = await _observeGet(
      'actions/runs/$runId/artifacts',
      token: token,
      query: const <String, String>{'per_page': '100'},
    );
    _requireObservationSuccess(
      response,
      'Unable to observe GitHub Actions artifacts',
    );
    final decoded = _decodeObject(response.body, 'GitHub artifact list');
    final rawArtifacts = decoded['artifacts'];
    if (rawArtifacts is! List) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub durable artifact list is invalid.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }

    final result = <WorkshopGitHubArtifact>[];
    for (final raw in rawArtifacts) {
      if (raw is! Map) continue;
      final value = Map<String, dynamic>.from(raw);
      final id = value['id'];
      if (id is! num) continue;
      result.add(
        WorkshopGitHubArtifact(
          id: id.toInt(),
          name: value['name']?.toString() ?? '',
          archiveDownloadUrl:
              value['archive_download_url']?.toString() ?? '',
          sizeInBytes: value['size_in_bytes'] is num
              ? (value['size_in_bytes'] as num).toInt()
              : 0,
          expired: value['expired'] == true,
          createdAt: _optionalDate(value['created_at']),
          expiresAt: _optionalDate(value['expires_at']),
        ),
      );
    }
    return List<WorkshopGitHubArtifact>.unmodifiable(result);
  }

  Future<_DurableStagedBuildSource> _stageSnapshot({
    required String token,
    required WorkshopBuildSourceSnapshot snapshot,
    required WorkshopBuildRequest request,
    required String remoteId,
    required String projectName,
    required String applicationId,
    required String displayName,
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

    final baseCommit =
        await _getJson('git/commits/$baseCommitSha', token: token);
    final tree = baseCommit['tree'];
    if (tree is! Map || tree['sha'] is! String) {
      throw const FormatException('GitHub base commit is missing its tree SHA.');
    }
    final baseTreeSha = (tree['sha'] as String).trim();
    _requireSha(baseTreeSha, 'base tree');

    final entries = <Map<String, Object?>>[];
    for (final file in snapshot.files) {
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
      'project_name': projectName,
      'display_name': displayName,
      'application_id': applicationId,
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

    return _DurableStagedBuildSource(branch: branch, commitSha: commitSha);
  }

  Future<void> _requirePrivateRepository(String token) async {
    final repo = await _getJson('', token: token);
    if (_configuration.requirePrivateRepository && repo['private'] != true) {
      throw const WorkshopDurableGitHubGatewayException(
        'Refusing to stage Cantiere project source in a public repository.',
        failureClass: WorkshopDurableFailureClass.policyBlocked,
        definitive: true,
      );
    }
  }

  Future<String> _token() async {
    final token = (await _accessTokenProvider()).trim();
    if (token.isEmpty) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub build authorization is missing or expired.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: true,
      );
    }
    return token;
  }

  Future<String> _tokenForObservation() async {
    try {
      return await _token();
    } on WorkshopDurableGitHubGatewayException catch (error) {
      throw WorkshopDurableGitHubGatewayException(
        error.message,
        failureClass: error.failureClass,
        definitive: false,
      );
    }
  }

  Future<http.Response> _observeGet(
    String path, {
    required String token,
    Map<String, String>? query,
  }) async {
    try {
      return await _client.get(
        _api(path, query),
        headers: _headers(token),
      );
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

  void _requireObservationSuccess(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw WorkshopDurableGitHubGatewayException(
      _httpFailure(operation, response.statusCode),
      failureClass: _failureClassForStatus(response.statusCode),
      definitive: false,
    );
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String token,
  }) async {
    final response = await _client.get(_api(path), headers: _headers(token));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _httpFailure('GitHub durable build API request failed', response.statusCode),
      );
    }
    return _decodeObject(response.body, 'GitHub durable build API response');
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
      throw StateError(
        _httpFailure('GitHub durable build API mutation failed', response.statusCode),
      );
    }
    return _decodeObject(response.body, 'GitHub durable build API mutation');
  }

  Map<String, String> _headers(String token, {bool json = false}) =>
      <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-cantiere-durable-build/1',
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

  static WorkshopGitHubRun _decodeRun(Map<String, dynamic> value) {
    final id = value['id'];
    if (id is! num) {
      throw const WorkshopDurableGitHubGatewayException(
        'GitHub Actions run is missing its id.',
        failureClass: WorkshopDurableFailureClass.providerUnavailable,
        definitive: false,
      );
    }
    return WorkshopGitHubRun(
      id: id.toInt(),
      status: _runStatus(value['status']),
      conclusion: _runConclusion(value['conclusion']),
      htmlUrl: value['html_url']?.toString() ?? '',
      name: value['name']?.toString(),
      headBranch: value['head_branch']?.toString(),
      headSha: value['head_sha']?.toString(),
      runNumber: value['run_number'] is num
          ? (value['run_number'] as num).toInt()
          : null,
      createdAt: _optionalDate(value['created_at']),
      updatedAt: _optionalDate(value['updated_at']),
    );
  }

  static WorkshopGitHubRunStatus _runStatus(Object? raw) {
    switch (raw?.toString()) {
      case 'queued':
      case 'pending':
      case 'waiting':
      case 'requested':
        return WorkshopGitHubRunStatus.queued;
      case 'in_progress':
        return WorkshopGitHubRunStatus.inProgress;
      case 'completed':
        return WorkshopGitHubRunStatus.completed;
      default:
        return WorkshopGitHubRunStatus.unknown;
    }
  }

  static WorkshopGitHubRunConclusion _runConclusion(Object? raw) {
    switch (raw?.toString()) {
      case 'success':
        return WorkshopGitHubRunConclusion.success;
      case 'failure':
        return WorkshopGitHubRunConclusion.failure;
      case 'cancelled':
        return WorkshopGitHubRunConclusion.cancelled;
      case 'timed_out':
        return WorkshopGitHubRunConclusion.timedOut;
      case 'neutral':
        return WorkshopGitHubRunConclusion.neutral;
      case 'skipped':
        return WorkshopGitHubRunConclusion.skipped;
      case 'action_required':
        return WorkshopGitHubRunConclusion.actionRequired;
      default:
        return WorkshopGitHubRunConclusion.unknown;
    }
  }

  static WorkshopDurableFailureClass _failureClassForStatus(int statusCode) {
    if (statusCode == 429) return WorkshopDurableFailureClass.rateLimit;
    if (statusCode >= 500) {
      return WorkshopDurableFailureClass.providerUnavailable;
    }
    if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
      return WorkshopDurableFailureClass.providerUnavailable;
    }
    return WorkshopDurableFailureClass.unknown;
  }

  static Map<String, dynamic> _decodeObject(String body, String label) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Converted to the closed gateway exception below.
    }
    throw WorkshopDurableGitHubGatewayException(
      '$label returned invalid JSON.',
      failureClass: WorkshopDurableFailureClass.providerUnavailable,
      definitive: false,
    );
  }

  static DateTime? _optionalDate(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text)?.toUtc();
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

  static String _httpFailure(String operation, int statusCode) {
    if (statusCode == 401) return '$operation: GitHub authorization expired.';
    if (statusCode == 403) {
      return '$operation: GitHub permission, Actions quota, or rate limit denied.';
    }
    if (statusCode == 404) return '$operation: GitHub resource unavailable.';
    if (statusCode == 429) return '$operation: GitHub rate limit exceeded.';
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

final class _DurableStagedBuildSource {
  const _DurableStagedBuildSource({
    required this.branch,
    required this.commitSha,
  });

  final String branch;
  final String commitSha;
}
