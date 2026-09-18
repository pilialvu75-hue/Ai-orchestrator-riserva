import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_github_config.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_curator_advice.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

typedef ModuleCuratorAccessTokenProvider = Future<String> Function();
typedef ModuleCuratorDelay = Future<void> Function(Duration duration);
typedef ModuleCuratorNow = DateTime Function();
typedef ModuleCuratorRequestIdFactory = String Function();

final class ModuleCuratorGitHubActionsSource {
  ModuleCuratorGitHubActionsSource({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    ModuleLibraryGitHubConfigStore? configStore,
    WorkshopLibraryGitHubAuthClient? authClient,
    http.Client? client,
    ModuleCuratorAccessTokenProvider? accessTokenProvider,
    ModuleCuratorDelay? delay,
    ModuleCuratorNow? now,
    ModuleCuratorRequestIdFactory? requestIdFactory,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(minutes: 4),
  })  : _credentialStore =
            credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _configStore = configStore ?? ModuleLibraryGitHubConfigStore(),
        _authClient = authClient ?? WorkshopLibraryGitHubAuthClient(),
        _client = client ?? http.Client(),
        _accessTokenProvider = accessTokenProvider,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now,
        _requestIdFactory = requestIdFactory ?? const Uuid().v4;

  static const String _repository =
      'pilialvu75-hue/AI-Orchestrator-Module-Library';
  static const String _workflow = 'run-curator-gemini.yml';
  static const String _artifactName = 'library-curator-gemini-result';

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final ModuleLibraryGitHubConfigStore _configStore;
  final WorkshopLibraryGitHubAuthClient _authClient;
  final http.Client _client;
  final ModuleCuratorAccessTokenProvider? _accessTokenProvider;
  final ModuleCuratorDelay _delay;
  final ModuleCuratorNow _now;
  final ModuleCuratorRequestIdFactory _requestIdFactory;
  final Duration pollInterval;
  final Duration timeout;

  Future<ModuleCuratorResult> run({
    required ModuleCuratorTask task,
    String? capabilityId,
  }) async {
    if (task == ModuleCuratorTask.rankCandidates &&
        (capabilityId == null || capabilityId.trim().isEmpty)) {
      throw ArgumentError.value(
        capabilityId,
        'capabilityId',
        'Il ranking Curator richiede una capability.',
      );
    }

    final token = await _accessToken();
    final requestId = _requestIdFactory();
    if (requestId.trim().isEmpty || requestId.contains(']')) {
      throw const FormatException('ID richiesta Curator non valido.');
    }

    await _dispatch(
      token: token,
      task: task,
      capabilityId: capabilityId,
      requestId: requestId,
    );

    final deadline = _now().add(timeout);
    final runId = await _waitForRun(
      token: token,
      requestId: requestId,
      deadline: deadline,
    );
    await _waitForCompletion(
      token: token,
      runId: runId,
      deadline: deadline,
    );
    return _downloadResult(token: token, runId: runId);
  }

  Future<String> _accessToken() async {
    final injected = _accessTokenProvider;
    if (injected != null) {
      final token = (await injected()).trim();
      if (token.isEmpty) {
        throw StateError('Autorizzazione GitHub per Module Library assente.');
      }
      return token;
    }

    var credential = await _credentialStore.load();
    if (credential == null) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }
    if (!credential.isExpired) return credential.accessToken;

    final refreshToken = credential.refreshToken?.trim();
    final clientId = await _configStore.loadClientId();
    if (refreshToken == null || refreshToken.isEmpty || clientId == null) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }
    try {
      credential = await _authClient.refresh(
        clientId: clientId,
        refreshToken: refreshToken,
      );
      await _credentialStore.save(credential);
      return credential.accessToken;
    } catch (_) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-module-curator/1.5',
      };

  Uri _api(String path, [Map<String, String>? query]) => Uri.https(
        'api.github.com',
        '/repos/$_repository/$path',
        query,
      );

  Future<void> _dispatch({
    required String token,
    required ModuleCuratorTask task,
    required String? capabilityId,
    required String requestId,
  }) async {
    final response = await _client.post(
      _api('actions/workflows/$_workflow/dispatches'),
      headers: <String, String>{
        ..._headers(token),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'ref': 'main',
        'inputs': <String, String>{
          'task': task.apiValue,
          'capability': capabilityId?.trim() ?? '',
          'model': 'gemini-3.6-flash',
          'client_request_id': requestId,
        },
      }),
    );
    if (response.statusCode == 204) return;
    _throwGitHubError(response.statusCode, operation: 'avvio Curator');
  }

  Future<int> _waitForRun({
    required String token,
    required String requestId,
    required DateTime deadline,
  }) async {
    while (_now().isBefore(deadline)) {
      final response = await _client.get(
        _api(
          'actions/workflows/$_workflow/runs',
          <String, String>{
            'event': 'workflow_dispatch',
            'branch': 'main',
            'per_page': '30',
          },
        ),
        headers: _headers(token),
      );
      if (response.statusCode != 200) {
        _throwGitHubError(
          response.statusCode,
          operation: 'ricerca esecuzione Curator',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['workflow_runs'] is! List) {
        throw const FormatException('Elenco workflow Curator non valido.');
      }
      for (final raw in decoded['workflow_runs'] as List) {
        if (raw is! Map) continue;
        final title = raw['display_title']?.toString() ?? '';
        final id = raw['id'];
        if (title.contains('[$requestId]') && id is num) {
          return id.toInt();
        }
      }
      await _delay(pollInterval);
    }
    throw TimeoutException(
      'GitHub non ha avviato il Curator entro il tempo previsto.',
    );
  }

  Future<void> _waitForCompletion({
    required String token,
    required int runId,
    required DateTime deadline,
  }) async {
    while (_now().isBefore(deadline)) {
      final response = await _client.get(
        _api('actions/runs/$runId'),
        headers: _headers(token),
      );
      if (response.statusCode != 200) {
        _throwGitHubError(
          response.statusCode,
          operation: 'controllo esecuzione Curator',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('Stato workflow Curator non valido.');
      }
      if (decoded['status'] == 'completed') {
        if (decoded['conclusion'] == 'success') return;
        final conclusion = decoded['conclusion']?.toString() ?? 'unknown';
        throw StateError(
          'Esecuzione Curator non riuscita su GitHub Actions '
          '(run #$runId, esito: $conclusion). '
          'La chiave Gemini, i limiti del provider, la rete o il workflow '
          'possono essere la causa; consulta i log del run per il dettaglio.',
        );
      }
      await _delay(pollInterval);
    }
    throw TimeoutException(
      'Il Curator non ha terminato entro il tempo previsto.',
    );
  }

  Future<ModuleCuratorResult> _downloadResult({
    required String token,
    required int runId,
  }) async {
    final listResponse = await _client.get(
      _api('actions/runs/$runId/artifacts'),
      headers: _headers(token),
    );
    if (listResponse.statusCode != 200) {
      _throwGitHubError(
        listResponse.statusCode,
        operation: 'lettura risultato Curator',
      );
    }
    final decoded = jsonDecode(listResponse.body);
    if (decoded is! Map || decoded['artifacts'] is! List) {
      throw const FormatException('Elenco artifact Curator non valido.');
    }

    int? artifactId;
    for (final raw in decoded['artifacts'] as List) {
      if (raw is! Map || raw['name'] != _artifactName) continue;
      final id = raw['id'];
      if (id is num) {
        artifactId = id.toInt();
        break;
      }
    }
    if (artifactId == null) {
      throw StateError('Risultato verificato del Curator non trovato.');
    }

    final archiveResponse = await _client.get(
      _api('actions/artifacts/$artifactId/zip'),
      headers: _headers(token),
    );
    if (archiveResponse.statusCode != 200) {
      _throwGitHubError(
        archiveResponse.statusCode,
        operation: 'download risultato Curator',
      );
    }

    final archive = ZipDecoder().decodeBytes(archiveResponse.bodyBytes);
    ArchiveFile? resultFile;
    for (final file in archive.files) {
      if (file.isFile && file.name.endsWith('library-curator-result.json')) {
        resultFile = file;
        break;
      }
    }
    if (resultFile == null) {
      throw const FormatException('JSON risultato Curator assente dall\'artifact.');
    }

    final content = resultFile.content;
    if (content is! List<int>) {
      throw const FormatException('Contenuto artifact Curator non leggibile.');
    }
    final resultJson = jsonDecode(utf8.decode(content));
    if (resultJson is! Map) {
      throw const FormatException('JSON risultato Curator non valido.');
    }
    return ModuleCuratorResult.fromJson(
      Map<String, Object?>.from(resultJson),
    );
  }

  Never _throwGitHubError(int statusCode, {required String operation}) {
    if (statusCode == 401) {
      throw StateError(
        'Autorizzazione GitHub scaduta durante $operation. Riconnetti la Library.',
      );
    }
    if (statusCode == 403 || statusCode == 404) {
      throw StateError(
        'Il Curator AI richiede il permesso GitHub Actions: Read and write '
        'sulla Module Library ($operation, HTTP $statusCode).',
      );
    }
    throw StateError('$operation fallito (HTTP $statusCode).');
  }
}
