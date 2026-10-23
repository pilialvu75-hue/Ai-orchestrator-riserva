import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_github_config.dart';
import 'package:http/http.dart' as http;

final class ModuleLabRunStatus {
  const ModuleLabRunStatus({
    required this.id,
    required this.status,
    required this.conclusion,
    required this.createdAt,
  });

  final int id;
  final String status;
  final String? conclusion;
  final DateTime createdAt;

  bool get running => status != 'completed';
}

typedef ModuleLabAccessTokenProvider = Future<String> Function();

final class ModuleLabGitHubActionsSource {
  ModuleLabGitHubActionsSource({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    http.Client? client,
    ModuleLibraryGitHubConfigStore? configStore,
    WorkshopLibraryGitHubAuthClient? authClient,
    ModuleLabAccessTokenProvider? accessTokenProvider,
    Duration requestTimeout = const Duration(seconds: 20),
  })  : _credentialStore = credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _client = client ?? http.Client(),
        _configStore = configStore ?? ModuleLibraryGitHubConfigStore(),
        _authClient = authClient ?? WorkshopLibraryGitHubAuthClient(),
        _accessTokenProvider = accessTokenProvider,
        _requestTimeout = requestTimeout;

  static const _researcherRepository =
      'pilialvu75-hue/AI-Orchestrator-Module-Researcher';
  static const _researcherWorkflow = 'autonomous-seeding.yml';

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final http.Client _client;
  final ModuleLibraryGitHubConfigStore _configStore;
  final WorkshopLibraryGitHubAuthClient _authClient;
  final ModuleLabAccessTokenProvider? _accessTokenProvider;
  final Duration _requestTimeout;

  // Shared by Lab source instances in this isolate to prevent rotating the
  // same GitHub App refresh token more than once concurrently.
  static Future<WorkshopGitHubUserCredential>? _pendingRefresh;

  Future<String> _token() async {
    final injected = _accessTokenProvider;
    if (injected != null) {
      final token = (await injected()).trim();
      if (token.isEmpty) throw StateError('Autorizzazione GitHub assente.');
      return token;
    }
    final credential = await _credentialStore.load();
    if (credential == null) {
      throw StateError('Autorizzazione GitHub assente o scaduta.');
    }
    if (!credential.isExpired) return credential.accessToken;
    final refreshToken = credential.refreshToken?.trim();
    final clientId = await _configStore.loadClientId();
    if (refreshToken == null || refreshToken.isEmpty || clientId == null) {
      throw StateError('Autorizzazione GitHub assente o scaduta.');
    }
    try {
      final pending = _pendingRefresh;
      if (pending != null) {
        final refreshed = await pending;
        return refreshed.accessToken;
      }
      final operation = _refreshAndSave(
        clientId: clientId,
        refreshToken: refreshToken,
      );
      _pendingRefresh = operation;
      try {
        return (await operation).accessToken;
      } finally {
        if (identical(_pendingRefresh, operation)) _pendingRefresh = null;
      }
    } catch (_) {
      // A separate source may have completed the rotation already.
      final current = await _credentialStore.load();
      if (current != null &&
          !current.isExpired &&
          current.accessToken != credential.accessToken) {
        return current.accessToken;
      }
      throw StateError('Autorizzazione GitHub assente o scaduta.');
    }
  }

  Future<WorkshopGitHubUserCredential> _refreshAndSave({
    required String clientId,
    required String refreshToken,
  }) async {
    final refreshed = await _authClient.refresh(
      clientId: clientId,
      refreshToken: refreshToken,
    );
    await _credentialStore.save(refreshed);
    return refreshed;
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-module-lab/1.0',
      };

  Uri _api(String path, [Map<String, String>? query]) => Uri.https(
        'api.github.com',
        '/repos/$_researcherRepository/$path',
        query,
      );

  Future<ModuleLabRunStatus?> latestResearcherRun() async {
    final token = await _token();
    final response = await _client.get(
      _api(
        'actions/workflows/$_researcherWorkflow/runs',
        <String, String>{'per_page': '1'},
      ),
      headers: _headers(token),
    ).timeout(_requestTimeout, onTimeout: () =>
        throw StateError('GitHub non risponde alla lettura del Lab entro 20 secondi. Riprova.'));

    if (response.statusCode != 200) {
      _throwGitHubError(response.statusCode, 'lettura stato Researcher');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['workflow_runs'] is! List) {
      throw const FormatException('Stato Researcher non valido.');
    }
    final runs = decoded['workflow_runs'] as List;
    if (runs.isEmpty || runs.first is! Map) return null;
    final raw = runs.first as Map;
    final id = raw['id'];
    final createdAt = DateTime.tryParse(raw['created_at']?.toString() ?? '');
    if (id is! num || createdAt == null) {
      throw const FormatException('Run Researcher non valido.');
    }
    return ModuleLabRunStatus(
      id: id.toInt(),
      status: raw['status']?.toString() ?? 'unknown',
      conclusion: raw['conclusion']?.toString(),
      createdAt: createdAt,
    );
  }

  Future<void> dispatchResearcher() async {
    final token = await _token();
    final latest = await latestResearcherRun();
    if (latest?.running ?? false) {
      throw StateError('Un ciclo Researcher è già in esecuzione.');
    }
    final response = await _client.post(
      _api('actions/workflows/$_researcherWorkflow/dispatches'),
      headers: <String, String>{
        ..._headers(token),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object?>{'ref': 'main'}),
    ).timeout(_requestTimeout, onTimeout: () =>
        throw StateError('Avvio Researcher senza risposta GitHub entro 20 secondi. Controlla lo stato prima di riprovare.'));

    if (response.statusCode != 204) {
      _throwGitHubError(response.statusCode, 'avvio manuale Researcher');
    }
  }

  Never _throwGitHubError(int statusCode, String operation) {
    if (statusCode == 401) {
      throw StateError('Autorizzazione GitHub scaduta durante $operation.');
    }
    if (statusCode == 403 || statusCode == 404) {
      throw StateError(
        'Il Lab richiede accesso GitHub Actions al repository Researcher '
        '($operation, HTTP $statusCode).',
      );
    }
    throw StateError('$operation fallito (HTTP $statusCode).');
  }
}
