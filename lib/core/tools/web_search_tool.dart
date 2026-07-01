import 'dart:async';
import 'dart:convert';
import 'dart:io'; // Obbligatorio per HttpException

import 'package:http/http.dart' as http;
import 'package:ai_orchestrator/core/tools/tool.dart';

/// Interfaccia astratta per la gestione della cache di ricerca.
/// Garantisce la portabilità futura su storage persistenti (Isar/Hive) su Desktop/Raspberry.
abstract class SearchCache {
  Future<ToolResult?> get(String query);
  Future<void> put(String query, ToolResult result);
  Future<void> clear();
}

/// Implementazione in memoria predefinita della cache.
class InMemorySearchCache implements SearchCache {
  final _storage = <String, ToolResult>{};

  @override
  Future<ToolResult?> get(String query) async => _storage[query];

  @override
  Future<void> put(String query, ToolResult result) async => _storage[query] = result;

  @override
  Future<void> clear() async => _storage.clear();
}

class WebSearchTool implements Tool {
  WebSearchTool({
    http.Client? client,
    SearchCache? cache,
    this.maxResults = 5,
    this.timeout = const Duration(seconds: 5),
  })  : _client = client ?? http.Client(),
        _cache = cache ?? InMemorySearchCache();

  final http.Client _client;
  final SearchCache _cache;
  final int maxResults;
  final Duration timeout;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Web Search';

  @override
  String get description =>
      'Recupera contesti informativi aggiornati da DuckDuckGo HTML e restituisce '
      'un riepilogo compatto e citabile per l\'inferenza locale.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final query = (params['query'] as String?)?.trim() ?? '';
    final requestedLimit = (params['limit'] as num?)?.toInt() ?? maxResults;
    final limit = requestedLimit.clamp(1, 8);

    if (query.isEmpty) {
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'Il parametro "query" non può essere vuoto.',
      );
    }

    // 1. Controllo della Cache
    final cachedResult = await _cache.get(query);
    if (cachedResult != null) {
      return cachedResult;
    }

    try {
      // Utilizzo dell'endpoint HTML pubblico e leggero per risultati reali ed estesi
      final uri = Uri.https('html.duckduckgo.com', '/html/', <String, String>{'q': query});
      
      final response = await _client.get(uri).timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('La richiesta a DuckDuckGo ha superato il timeout di ${timeout.inSeconds}s.');
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Server HTTP ha risposto con codice ${response.statusCode}');
      }

      final results = _parseDefensiveHtml(response.body);

      if (results.isEmpty) {
        return ToolResult(
          toolId: id,
          output: 'Nessun risultato trovato sul web per "$query".',
          success: false,
          error: 'Nessun risultato estratto dal markup.',
        );
      }

      final limited = results.take(limit);
      final buffer = StringBuffer()
        ..writeln('Query: $query')
        ..writeln('Top web results:');
      
      var index = 1;
      for (final result in limited) {
        buffer
          ..writeln('$index. ${result.title}')
          ..writeln('   URL: ${result.url}')
          ..writeln('   Snippet: ${result.snippet}')
          ..writeln();
        index++;
      }

      final toolResult = ToolResult(
        toolId: id,
        output: buffer.toString().trimRight(),
        success: true,
      );

      // 2. Salvataggio in Cache
      await _cache.put(query, toolResult);
      return toolResult;

    } on TimeoutException catch (e) {
      return ToolResult(toolId: id, output: '', success: false, error: 'Timeout ricerca: ${e.message}');
    } on HttpException catch (e) {
      return ToolResult(toolId: id, output: '', success: false, error: 'Errore di rete HTTP: ${e.message}');
    } catch (e) {
      return ToolResult(toolId: id, output: '', success: false, error: 'Ricerca web fallita: $e');
    }
  }

  /// Parser HTML difensivo basato su blocchi logici sequenziali.
  /// Evita RegExp uniche e fragili sull'intero documento, isolando prima le classi dei risultati.
  List<_WebSearchEntry> _parseDefensiveHtml(String html) {
    final entries = <_WebSearchEntry>[];
    
    // Isola i blocchi dei risultati web per ridurre la superficie di scansione
    final resultBlockRegex = RegExp(r'<div class="[^"]*web-result[^"]*">(.*?)</div>\s*</div>', dotAll: true);
    final matches = resultBlockRegex.allMatches(html);

    final urlRegex = RegExp(r'href="([^"]+)"');
    final titleRegex = RegExp(r'class="result__url"[^>]*>(.*?)</a>', dotAll: true);
    final snippetRegex = RegExp(r'class="result__snippet"[^>]*>(.*?)</a>', dotAll: true);

    for (final match in matches) {
      final blockContent = match.group(1) ?? '';

      final urlMatch = urlRegex.firstMatch(blockContent);
      if (urlMatch == null) continue;
      
      var url = urlMatch.group(1) ?? '';
      if (url.startsWith('//')) url = 'https:$url';
      
      // Decodifica i redirect interni di DuckDuckGo se presenti
      if (url.contains('uddg=')) {
        try {
          final parts = Uri.parse(url).queryParameters;
          if (parts.containsKey('uddg')) {
            url = Uri.decodeComponent(parts['uddg']!);
          }
        } catch (_) {}
      }

      var title = titleRegex.firstMatch(blockContent)?.group(1) ?? 'Nessun titolo';
      var snippet = snippetRegex.firstMatch(blockContent)?.group(1) ?? 'Nessun frammento di testo.';

      title = _cleanHtmlTags(title);
      snippet = _cleanHtmlTags(snippet);

      if (url.isNotEmpty && !url.contains('duckduckgo.com/g.x')) {
        entries.add(_WebSearchEntry(title: title, url: url, snippet: snippet));
      }
    }

    return entries;
  }

  String _cleanHtmlTags(String text) {
    return text
        .replaceAll(RegExp(r'<[^>]*>'), '') // Rimuove i tag HTML residuali
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _WebSearchEntry {
  const _WebSearchEntry({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}
