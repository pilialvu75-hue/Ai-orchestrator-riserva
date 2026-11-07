import 'dart:convert';

import 'package:http/http.dart' as http;

/// Read-only GitHub intake inventory. TESTED entries are never certified or reusable.
final class ModuleLibraryIntakeSource {
  ModuleLibraryIntakeSource({http.Client? client}) : _client = client ?? http.Client();

  static const _repo = 'pilialvu75-hue/AI-Orchestrator-Module-Library';
  final http.Client _client;

  Future<List<ModuleLibraryIntakeEntry>> load({required String token}) async {
    final treeUri = Uri.parse(
      'https://api.github.com/repos/$_repo/git/trees/main?recursive=1',
    );
    final treeResponse = await _client.get(treeUri, headers: _headers(token));
    if (treeResponse.statusCode != 200) {
      throw StateError('Inventario moduli in valutazione: HTTP ${treeResponse.statusCode}');
    }
    final tree = jsonDecode(treeResponse.body) as Map<String, dynamic>;
    if (tree['truncated'] == true) {
      throw const FormatException('Inventario GitHub incompleto: impossibile mostrare un conteggio affidabile.');
    }
    final paths = (tree['tree'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((item) => item['path']?.toString() ?? '')
        .where((path) => path.startsWith('intake/') && path.endsWith('/manifest.json'))
        .toList()..sort();
    final entries = <ModuleLibraryIntakeEntry>[];
    for (final path in paths) {
      final uri = Uri.parse('https://api.github.com/repos/$_repo/contents/${path.split('/').map(Uri.encodeComponent).join('/')}?ref=main');
      final response = await _client.get(uri, headers: _headers(token));
      if (response.statusCode != 200) {
        throw StateError('Impossibile leggere il manifest di $path: HTTP ${response.statusCode}');
      }
      final metadata = jsonDecode(response.body) as Map<String, dynamic>;
      final raw = (metadata['content'] as String).replaceAll('\n', '');
      final manifest = jsonDecode(utf8.decode(base64Decode(raw))) as Map<String, dynamic>;
      final status = manifest['status']?.toString().toLowerCase() ?? 'unknown';
      if (status == 'certified') continue; // Only the official catalog can certify.
      entries.add(ModuleLibraryIntakeEntry(
        id: manifest['id']?.toString() ?? path,
        name: manifest['name']?.toString() ?? path,
        status: status,
      ));
    }
    return List.unmodifiable(entries);
  }

  Map<String, String> _headers(String token) => {
    'Accept': 'application/vnd.github+json',
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'aivexus-module-intake-dashboard/1',
  };
}

final class ModuleLibraryIntakeEntry {
  const ModuleLibraryIntakeEntry({required this.id, required this.name, required this.status});
  final String id;
  final String name;
  final String status;
}
