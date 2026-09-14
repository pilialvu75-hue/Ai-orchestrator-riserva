import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_github_config.dart';
import 'package:ai_orchestrator/features/module_library/data/module_research_diagnostics_source.dart';
import 'package:ai_orchestrator/features/module_library/data/module_research_status_source.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_capability_status.dart';
import 'package:http/http.dart' as http;

final class ModuleLibraryStatusRepository {
  ModuleLibraryStatusRepository({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    ModuleLibraryGitHubConfigStore? configStore,
    WorkshopLibraryGitHubAuthClient? authClient,
    http.Client? client,
    ModuleResearchStatusSource? researchSource,
  })  : _credentialStore = credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _configStore = configStore ?? ModuleLibraryGitHubConfigStore(),
        _authClient = authClient ?? WorkshopLibraryGitHubAuthClient(),
        _client = client ?? http.Client(),
        _researchSource =
            researchSource ?? GitHubDiagnosticsResearchStatusSource();

  static const String _repository =
      'pilialvu75-hue/AI-Orchestrator-Module-Library';

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final ModuleLibraryGitHubConfigStore _configStore;
  final WorkshopLibraryGitHubAuthClient _authClient;
  final http.Client _client;
  final ModuleResearchStatusSource _researchSource;

  Future<List<ModuleCapabilityStatus>> load() async {
    final credential = await _usableCredential();

    final needs = await _readJson(
      'catalog/needs.json',
      credential.accessToken,
    );
    final catalog = await _readJson(
      'catalog/index.json',
      credential.accessToken,
    );

    Map<String, Object?>? research;
    try {
      research = await _researchSource.load();
    } catch (_) {
      research = null;
    }

    return ModuleCapabilityStatusProjector.project(
      needsJson: needs,
      catalogJson: catalog,
      researcherJson: research,
    );
  }

  Future<WorkshopGitHubUserCredential> _usableCredential() async {
    final credential = await _credentialStore.load();
    if (credential == null) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }
    if (!credential.isExpired) return credential;

    final refreshToken = credential.refreshToken?.trim();
    final clientId = await _configStore.loadClientId();
    if (refreshToken == null || refreshToken.isEmpty || clientId == null) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }

    try {
      final refreshed = await _authClient.refresh(
        clientId: clientId,
        refreshToken: refreshToken,
      );
      await _credentialStore.save(refreshed);
      return refreshed;
    } catch (_) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }
  }

  Future<Map<String, Object?>> _readJson(
    String path,
    String token,
  ) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse(
      'https://api.github.com/repos/$_repository/contents/$encodedPath?ref=main',
    );
    final response = await _client.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-module-dashboard/1',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Lettura Module Library fallita (HTTP ${response.statusCode}).',
      );
    }

    final metadata = jsonDecode(response.body);
    if (metadata is! Map) {
      throw const FormatException('Risposta GitHub Module Library non valida.');
    }
    final encoded = metadata['content']?.toString().replaceAll('\n', '') ?? '';
    if (encoded.isEmpty) {
      throw FormatException('Contenuto Module Library mancante: $path.');
    }
    final decoded = jsonDecode(utf8.decode(base64Decode(encoded)));
    if (decoded is! Map) {
      throw FormatException('JSON Module Library non valido: $path.');
    }
    return Map<String, Object?>.from(decoded);
  }
}
