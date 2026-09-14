import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_capability_status.dart';
import 'package:http/http.dart' as http;

abstract interface class ModuleResearchStatusSource {
  Future<Map<String, Object?>?> load();
}

final class ModuleLibraryStatusRepository {
  ModuleLibraryStatusRepository({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    http.Client? client,
    ModuleResearchStatusSource? researchSource,
  })  : _credentialStore = credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _client = client ?? http.Client(),
        _researchSource = researchSource;

  static const String _repository =
      'pilialvu75-hue/AI-Orchestrator-Module-Library';

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final http.Client _client;
  final ModuleResearchStatusSource? _researchSource;

  Future<List<ModuleCapabilityStatus>> load() async {
    final credential = await _credentialStore.load();
    if (credential == null || credential.isExpired) {
      throw StateError(
        'Autorizzazione GitHub per Module Library assente o scaduta.',
      );
    }

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
      research = await _researchSource?.load();
    } catch (_) {
      research = null;
    }

    return ModuleCapabilityStatusProjector.project(
      needsJson: needs,
      catalogJson: catalog,
      researcherJson: research,
    );
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
