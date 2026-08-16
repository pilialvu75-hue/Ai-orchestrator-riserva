import 'dart:async';
import 'dart:convert';

import 'workshop_build_lab.dart';

/// Stato osservato di un workflow GitHub Actions.
enum WorkshopGitHubRunStatus {
  unknown,
  queued,
  inProgress,
  completed,
}

/// Conclusione di un workflow GitHub Actions.
enum WorkshopGitHubRunConclusion {
  unknown,
  success,
  failure,
  cancelled,
  timedOut,
  neutral,
  skipped,
  actionRequired,
}

/// Snapshot normalizzato di un workflow GitHub Actions.
final class WorkshopGitHubRun {
  const WorkshopGitHubRun({
    required this.id,
    required this.status,
    required this.conclusion,
    required this.htmlUrl,
    this.name,
    this.headBranch,
    this.headSha,
    this.runNumber,
    this.createdAt,
    this.updatedAt,
  });

  final int id;

  final WorkshopGitHubRunStatus status;
  final WorkshopGitHubRunConclusion conclusion;

  final String htmlUrl;

  final String? name;
  final String? headBranch;
  final String? headSha;

  final int? runNumber;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isQueued =>
      status == WorkshopGitHubRunStatus.queued;

  bool get isRunning =>
      status == WorkshopGitHubRunStatus.inProgress;

  bool get isCompleted =>
      status == WorkshopGitHubRunStatus.completed;

  bool get succeeded =>
      isCompleted &&
      conclusion == WorkshopGitHubRunConclusion.success;

  bool get failed =>
      isCompleted &&
      conclusion == WorkshopGitHubRunConclusion.failure;

  bool get cancelled =>
      isCompleted &&
      conclusion == WorkshopGitHubRunConclusion.cancelled;

  bool get timedOut =>
      isCompleted &&
      conclusion == WorkshopGitHubRunConclusion.timedOut;
}

/// Artifact prodotto da GitHub Actions.
final class WorkshopGitHubArtifact {
  const WorkshopGitHubArtifact({
    required this.id,
    required this.name,
    required this.archiveDownloadUrl,
    required this.sizeInBytes,
    required this.expired,
    this.createdAt,
    this.expiresAt,
  });

  final int id;
  final String name;

  final String archiveDownloadUrl;
  final int sizeInBytes;

  final bool expired;

  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get isDownloadable =>
      !expired &&
      archiveDownloadUrl.trim().isNotEmpty &&
      sizeInBytes > 0;
}

/// Risultato completo del monitoraggio.
final class WorkshopGitHubBuildMonitorResult {
  const WorkshopGitHubBuildMonitorResult({
    required this.requestId,
    required this.target,
    required this.run,
    this.artifacts = const <WorkshopGitHubArtifact>[],
    this.message,
  });

  final String requestId;
  final WorkshopBuildTarget target;

  final WorkshopGitHubRun run;

  final List<WorkshopGitHubArtifact> artifacts;

  final String? message;

  bool get buildSucceeded => run.succeeded;

  bool get artifactAvailable =>
      artifacts.any(
        (artifact) => artifact.isDownloadable,
      );
}

/// Client HTTP astratto.
///
/// Il monitor non dipende da package HTTP specifici.
abstract interface class WorkshopGitHubMonitorHttpClient {
  Future<WorkshopGitHubMonitorHttpResponse> get(
    Uri uri, {
    Map<String, String>? headers,
  });
}

final class WorkshopGitHubMonitorHttpResponse {
  const WorkshopGitHubMonitorHttpResponse({
    required this.statusCode,
    this.body = '',
  });

  final int statusCode;
  final String body;

  bool get isSuccess =>
      statusCode >= 200 && statusCode < 300;
}

/// Configurazione del monitor GitHub.
final class WorkshopGitHubBuildMonitorConfiguration {
  const WorkshopGitHubBuildMonitorConfiguration({
    required this.owner,
    required this.repository,
    required this.workflowFile,
    this.apiBaseUrl = 'https://api.github.com',
  });

  final String owner;
  final String repository;
  final String workflowFile;

  final String apiBaseUrl;

  String get repositoryFullName =>
      '$owner/$repository';
}

/// Monitor del workflow remoto.
///
/// Responsabilità:
/// - osservare un workflow già avviato;
/// - normalizzare gli stati GitHub;
/// - attendere la conclusione;
/// - recuperare gli artifact;
/// - trasformare il risultato in un modello utilizzabile dal Build Lab.
///
/// Non avvia workflow e non modifica il repository.
final class WorkshopGitHubBuildMonitor {
  WorkshopGitHubBuildMonitor({
    required WorkshopGitHubBuildMonitorConfiguration configuration,
    required WorkshopGitHubMonitorHttpClient client,
    required String accessToken,
    this.pollInterval = const Duration(seconds: 10),
  })  : _configuration = configuration,
        _client = client,
        _accessToken = accessToken;

  final WorkshopGitHubBuildMonitorConfiguration _configuration;
  final WorkshopGitHubMonitorHttpClient _client;
  final String _accessToken;

  final Duration pollInterval;

  final Map<String, bool> _cancelledRequests =
      <String, bool>{};

  bool _disposed = false;

  /// Recupera un workflow specifico.
  Future<WorkshopGitHubRun?> getRun(
    int runId,
  ) async {
    _ensureAvailable();

    final uri = Uri.parse(
      '${_configuration.apiBaseUrl}/repos/'
      '${_configuration.repositoryFullName}/actions/runs/$runId',
    );

    final response = await _client.get(
      uri,
      headers: _headers,
    );

    if (!response.isSuccess) {
      if (response.statusCode == 404) {
        return null;
      }

      throw WorkshopGitHubMonitorException(
        'Unable to retrieve GitHub Actions run.',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }

    return _decodeRun(response.body);
  }

  /// Recupera gli artifact di un workflow.
  Future<List<WorkshopGitHubArtifact>> getArtifacts(
    int runId,
  ) async {
    _ensureAvailable();

    final uri = Uri.parse(
      '${_configuration.apiBaseUrl}/repos/'
      '${_configuration.repositoryFullName}/actions/runs/'
      '$runId/artifacts',
    );

    final response = await _client.get(
      uri,
      headers: _headers,
    );

    if (!response.isSuccess) {
      throw WorkshopGitHubMonitorException(
        'Unable to retrieve GitHub Actions artifacts.',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }

    return _decodeArtifacts(response.body);
  }

  /// Monitora un workflow fino alla conclusione.
  ///
  /// Non blocca la UI: restituisce una Future e può essere eseguito
  /// dal WorkshopBackgroundService.
  Future<WorkshopGitHubBuildMonitorResult> waitForCompletion({
    required String requestId,
    required WorkshopBuildTarget target,
    required int runId,
    Duration? timeout,
  }) async {
    _ensureAvailable();

    final deadline = timeout == null
        ? null
        : DateTime.now().add(timeout);

    while (true) {
      _ensureAvailable();

      if (_cancelledRequests[requestId] == true) {
        throw WorkshopGitHubMonitorCancelledException(
          requestId,
        );
      }

      final run = await getRun(runId);

      if (run == null) {
        throw WorkshopGitHubMonitorException(
          'GitHub Actions run $runId was not found.',
        );
      }

      if (run.isCompleted) {
        final artifacts = run.succeeded
            ? await getArtifacts(run.id)
            : const <WorkshopGitHubArtifact>[];

        return WorkshopGitHubBuildMonitorResult(
          requestId: requestId,
          target: target,
          run: run,
          artifacts: artifacts,
          message: _completionMessage(run, artifacts),
        );
      }

      if (deadline != null &&
          DateTime.now().isAfter(deadline)) {
        throw WorkshopGitHubMonitorTimeoutException(
          requestId,
          runId,
        );
      }

      await Future<void>.delayed(pollInterval);
    }
  }

  /// Cancella solamente o monitoraggio locale.
  ///
  /// Non cancella il workflow GitHub: questa distinzione è intenzionale.
  /// La cancellazione reale del workflow richiederà una successiva
  /// API esplicita con permessi Actions write.
  Future<void> cancelMonitoring(
    String requestId,
  ) async {
    _ensureAvailable();

    _cancelledRequests[requestId] = true;
  }

  /// Cerca l'ultimo workflow associato al commit.
  ///
  /// Utile quando il dispatch non restituisce direttamente il run ID.
  Future<WorkshopGitHubRun?> findLatestRunForCommit(
    String commitSha,
  ) async {
    _ensureAvailable();

    final uri = Uri.parse(
      '${_configuration.apiBaseUrl}/repos/'
      '${_configuration.repositoryFullName}/actions/runs'
      '?head_sha=${Uri.encodeQueryComponent(commitSha)}'
      '&per_page=20',
    );

    final response = await _client.get(
      uri,
      headers: _headers,
    );

    if (!response.isSuccess) {
      throw WorkshopGitHubMonitorException(
        'Unable to find GitHub Actions runs for commit.',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map) {
      return null;
    }

    final workflowRuns = decoded['workflow_runs'];

    if (workflowRuns is! List) {
      return null;
    }

    WorkshopGitHubRun? latest;

    for (final item in workflowRuns) {
      if (item is! Map) {
        continue;
      }

      final run = _decodeRunObject(item);

      if (run == null) {
        continue;
      }

      if (run.name != null &&
          run.name!.trim() ==
              _workflowDisplayName) {
        if (latest == null) {
          latest = run;
          continue;
        }

        final latestCreated = latest.createdAt;
        final currentCreated = run.createdAt;

        if (latestCreated == null ||
            (currentCreated != null &&
                currentCreated.isAfter(latestCreated))) {
          latest = run;
        }
      }
    }

    return latest;
  }

  WorkshopGitHubRun _decodeRun(
    String body,
  ) {
    final decoded = jsonDecode(body);

    if (decoded is! Map) {
      throw const WorkshopGitHubMonitorException(
        'Invalid GitHub Actions run response.',
      );
    }

    final run = _decodeRunObject(decoded);

    if (run == null) {
      throw const WorkshopGitHubMonitorException(
        'GitHub Actions run response is missing a valid id.',
      );
    }

    return run;
  }

  WorkshopGitHubRun? _decodeRunObject(
    Map<dynamic, dynamic> value,
  ) {
    final id = _toInt(value['id']);

    if (id == null) {
      return null;
    }

    final status = _decodeStatus(
      value['status'],
    );

    final conclusion = _decodeConclusion(
      value['conclusion'],
    );

    final htmlUrl =
        value['html_url'] is String
            ? value['html_url'] as String
            : '';

    return WorkshopGitHubRun(
      id: id,
      status: status,
      conclusion: conclusion,
      htmlUrl: htmlUrl,
      name: _nullableString(value['name']),
      headBranch:
          _nullableString(value['head_branch']),
      headSha:
          _nullableString(value['head_sha']),
      runNumber:
          _toInt(value['run_number']),
      createdAt:
          _parseDate(value['created_at']),
      updatedAt:
          _parseDate(value['updated_at']),
    );
  }

  List<WorkshopGitHubArtifact> _decodeArtifacts(
    String body,
  ) {
    final decoded = jsonDecode(body);

    if (decoded is! Map) {
      return const <WorkshopGitHubArtifact>[];
    }

    final rawArtifacts = decoded['artifacts'];

    if (rawArtifacts is! List) {
      return const <WorkshopGitHubArtifact>[];
    }

    final artifacts =
        <WorkshopGitHubArtifact>[];

    for (final item in rawArtifacts) {
      if (item is! Map) {
        continue;
      }

      final id = _toInt(item['id']);
      final name = _nullableString(item['name']);

      if (id == null || name == null) {
        continue;
      }

      final downloadUrl =
          _nullableString(
                item['archive_download_url'],
              ) ??
              '';

      artifacts.add(
        WorkshopGitHubArtifact(
          id: id,
          name: name,
          archiveDownloadUrl: downloadUrl,
          sizeInBytes:
              _toInt(item['size_in_bytes']) ?? 0,
          expired:
              item['expired'] == true,
          createdAt:
              _parseDate(item['created_at']),
          expiresAt:
              _parseDate(item['expires_at']),
        ),
      );
    }

    return List.unmodifiable(artifacts);
  }

  WorkshopGitHubRunStatus _decodeStatus(
    Object? value,
  ) {
    switch (value) {
      case 'queued':
        return WorkshopGitHubRunStatus.queued;

      case 'in_progress':
        return WorkshopGitHubRunStatus.inProgress;

      case 'completed':
        return WorkshopGitHubRunStatus.completed;

      default:
        return WorkshopGitHubRunStatus.unknown;
    }
  }

  WorkshopGitHubRunConclusion _decodeConclusion(
    Object? value,
  ) {
    switch (value) {
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

  String _completionMessage(
    WorkshopGitHubRun run,
    List<WorkshopGitHubArtifact> artifacts,
  ) {
    if (run.succeeded) {
      if (artifacts.isEmpty) {
        return 'GitHub build succeeded, but no artifact is available yet.';
      }

      return 'GitHub build succeeded. '
          '${artifacts.length} artifact(s) available for review.';
    }

    if (run.cancelled) {
      return 'GitHub build was cancelled.';
    }

    if (run.timedOut) {
      return 'GitHub build timed out.';
    }

    if (run.failed) {
      return 'GitHub build failed.';
    }

    return 'GitHub workflow completed.';
  }

  String get _workflowDisplayName =>
      _configuration.workflowFile;

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $_accessToken',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  String? _nullableString(
    Object? value,
  ) {
    return value is String ? value : null;
  }

  int? _toInt(
    Object? value,
  ) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      return int.tryParse(value);
    }

    return null;
  }

  DateTime? _parseDate(
    Object? value,
  ) {
    if (value is! String) {
      return null;
    }

    return DateTime.tryParse(value);
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopGitHubBuildMonitor has been disposed.',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;
    _cancelledRequests.clear();
  }
}

/// Errore generico del monitor GitHub.
final class WorkshopGitHubMonitorException
    implements Exception {
  const WorkshopGitHubMonitorException(
    this.message, {
    this.statusCode,
    this.responseBody,
  });

  final String message;
  final int? statusCode;
  final String? responseBody;

  @override
  String toString() {
    final buffer = StringBuffer(message);

    if (statusCode != null) {
      buffer.write(' HTTP $statusCode.');
    }

    return buffer.toString();
  }
}

/// Il monitor è stato cancellato dal Cantiere.
final class WorkshopGitHubMonitorCancelledException
    implements Exception {
  const WorkshopGitHubMonitorCancelledException(
    this.requestId,
  );

  final String requestId;

  @override
  String toString() =>
      'GitHub build monitoring cancelled for $requestId.';
}

/// Timeout del monitor.
///
/// Non implica necessariamente che la build GitHub sia fallita.
/// Il workflow potrebbe essere ancora in esecuzione.
final class WorkshopGitHubMonitorTimeoutException
    implements Exception {
  const WorkshopGitHubMonitorTimeoutException(
    this.requestId,
    this.runId,
  );

  final String requestId;
  final int runId;

  @override
  String toString() =>
      'Timeout while monitoring GitHub Actions run $runId '
      'for request $requestId.';
}
