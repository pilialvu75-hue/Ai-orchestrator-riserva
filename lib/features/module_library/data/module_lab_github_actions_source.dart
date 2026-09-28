import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
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
    required WorkshopLibraryGitHubCredentialStore credentialStore,
    http.Client? client,
    ModuleLabAccessTokenProvider? accessTokenProvider,
  })  : _credentialStore = credentialStore,
        _client = client ?? http.Client(),
        _accessTokenProvider = accessTokenProvider;

  static const _researcherRepository =
      'pilialvu75-hue/AI-Orchestrator-Module-Researcher';
  static const _researcherWorkflow = 'autonomous-seeding.yml';

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final http.Client _client;
  final ModuleLabAccessTokenProvider? _accessTokenProvider;

  Future<String> _token() async {
    final injected = _accessTokenProvider;
    if (injected != null) {
      final token = (await injected()).trim();
      if (token.isEmpty) throw StateError('Autorizzazione GitHub assente.');
      return token;
    }
    final credential = await _credentialStore.load();
    if (credential == null || credential.isExpired) {
      throw StateError('Autorizzazione GitHub assente o scaduta.');
    }
    return credential.accessToken;
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
    );
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
    );
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
