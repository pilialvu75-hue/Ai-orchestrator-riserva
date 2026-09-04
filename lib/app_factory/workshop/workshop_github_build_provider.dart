import 'dart:async';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';

/// Configurazione di un builder GitHub Actions.
///
/// Il provider non contiene credenziali hard-coded.
/// Il token deve essere fornito dall'infrastruttura di autenticazione
/// già presente nell'app o da un adapter sicuro.
final class WorkshopGitHubBuildConfiguration {
  const WorkshopGitHubBuildConfiguration({
    required this.owner,
    required this.repository,
    required this.workflowFile,
    this.ref = 'main',
  });

  final String owner;
  final String repository;
  final String workflowFile;
  final String ref;

  String get repositoryFullName =>
      '$owner/$repository';
}

/// Astrazione HTTP minima.
///
/// Evita di legare il Build Lab a un particolare package HTTP.
/// L'implementazione concreta verrà collegata all'infrastruttura
/// di rete/autenticazione dell'app.
abstract interface class WorkshopGitHubHttpClient {
  Future<WorkshopGitHubHttpResponse> get(
    Uri uri, {
    Map<String, String>? headers,
  });

  Future<WorkshopGitHubHttpResponse> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  });
}

final class WorkshopGitHubHttpResponse {
  const WorkshopGitHubHttpResponse({
    required this.statusCode,
    this.body = '',
  });

  final int statusCode;
  final String body;

  bool get isSuccess =>
      statusCode >= 200 && statusCode < 300;
}

/// Provider remoto per GitHub Actions.
///
/// Responsabilità:
/// - verificare che GitHub Actions sia configurato;
/// - avviare il workflow;
/// - restituire un riferimento al job remoto;
/// - non eseguire direttamente la build sul dispositivo.
///
/// Il provider è volutamente privo di dipendenze HTTP concrete.
final class WorkshopGitHubBuildProvider
    implements WorkshopBuildProvider {
  WorkshopGitHubBuildProvider({
    required WorkshopGitHubBuildConfiguration configuration,
    required WorkshopGitHubHttpClient client,
    required String accessToken,
  })  : _configuration = configuration,
        _client = client,
        _accessToken = accessToken;

  final WorkshopGitHubBuildConfiguration _configuration;
  final WorkshopGitHubHttpClient _client;
  final String _accessToken;

  final Set<String> _cancelledRequests = <String>{};

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.remote;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/'
        '${_configuration.repositoryFullName}/actions/workflows/'
        '${Uri.encodeComponent(_configuration.workflowFile)}',
      );

      final response = await _client.get(
        uri,
        headers: _headers,
      );

      if (!response.isSuccess) {
        return WorkshopToolchainInfo(
          target: target,
          status: WorkshopToolchainStatus.unavailable,
          executionMode: executionMode,
          message:
              'GitHub Actions workflow is not available '
              '(HTTP ${response.statusCode}).',
        );
      }

      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.available,
        executionMode: executionMode,
        name: 'GitHub Actions',
        message:
            'Remote GitHub Actions builder is available.',
      );
    } catch (error) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode: executionMode,
        name: 'GitHub Actions',
        message: error.toString(),
      );
    }
  }

  @override
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    final startedAt = DateTime.now();

    if (_cancelledRequests.contains(request.id)) {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.cancelled,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        message: 'Remote build was cancelled.',
      );
    }

    final workflowUri = Uri.parse(
      'https://api.github.com/repos/'
      '${_configuration.repositoryFullName}/actions/workflows/'
      '${Uri.encodeComponent(_configuration.workflowFile)}/dispatches',
    );

    final body = <String, dynamic>{
      'ref': _configuration.ref,
      'inputs': <String, String>{
        'project_id': request.projectId,
        'project_path': request.projectPath,
        'target': request.target.name,
        'build_request_id': request.id,
      },
    };

    try {
      final response = await _client.post(
        workflowUri,
        headers: _headers,
        body: body,
      );

      if (!response.isSuccess) {
        return WorkshopBuildResult(
          requestId: request.id,
          target: request.target,
          status: WorkshopBuildStatus.failed,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          message:
              'GitHub Actions workflow dispatch failed.',
          stderr: response.body,
          errors: <String>[
            'github_workflow_dispatch_failed',
            'http_${response.statusCode}',
          ],
        );
      }

      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.running,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        message:
            'Remote build started on GitHub Actions.',
      );
    } catch (error) {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        message:
            'Unable to start GitHub Actions build.',
        stderr: error.toString(),
        errors: <String>[
          'github_network_error',
        ],
      );
    }
  }

  @override
  Future<void> cancel(
    String requestId,
  ) async {
    _cancelledRequests.add(requestId);
  }

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $_accessToken',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      };
}
