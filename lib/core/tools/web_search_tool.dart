import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Modello unificato dei risultati restituiti dal tool di ricerca.
class ToolResult {
  final bool success;
  final String output;
  final String? errorMessage;

  ToolResult({
    required this.success,
    required this.output,
    this.errorMessage,
  });
}

/// Modello atomico per un singolo risultato grezzo estratto.
class SearchResult {
  final String title;
  final String url;
  final String snippet;
  final double score;

  SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.score = 0.0,
  });

  SearchResult copyWithScore(double newScore) {
    return SearchResult(
      title: title,
      url: url,
      snippet: snippet,
      score: newScore,
    );
  }
}

/// Entry di cache accoppiata alla marcatura temporale per il TTL.
class CacheEntry {
  final ToolResult result;
  final DateTime createdAt;

  CacheEntry(this.result, this.createdAt);
}

/// Contratto astratto per la cache di ricerca (Pronto per Hive/Isar).
abstract class SearchCache {
  ToolResult? get(String query);
  void set(String query, ToolResult result);
  void clear();
}

/// Contratto astratto per l'indipendenza dai motori di ricerca (Provider Independence).
abstract class SearchProvider {
  Future<List<SearchResult>> search(String query);
}

/// Implementazione della cache in-memory con validazione temporale rigida.
class InMemorySearchCache implements SearchCache {
  final Duration ttl;
  final Map<String, CacheEntry> _cache = {};

  InMemorySearchCache({this.ttl = const Duration(minutes: 10)});

  @override
  ToolResult? get(String query) {
    final entry = _cache[query];
    if (entry == null) {
      debugPrint('[FORENSIC][SearchCache] MISS -> Query: "$query"');
      return null;
    }
    if (DateTime.now().difference(entry.createdAt) > ttl) {
      debugPrint('[FORENSIC][SearchCache] EXPIRED -> Rimozione entry per query: "$query"');
      _cache.remove(query);
      return null;
    }
    debugPrint('[FORENSIC][SearchCache] HIT -> Cache valida recuperata per query: "$query"');
    return entry.result;
  }

  @override
  void set(String query, ToolResult result) {
    debugPrint('[FORENSIC][SearchCache] SET -> Scrittura entry in cache per query: "$query"');
    _cache[query] = CacheEntry(result, DateTime.now());
  }

  @override
  void clear() {
    debugPrint('[FORENSIC][SearchCache] CLEAR -> Svuotamento completo della cache.');
    _cache.clear();
  }
}

/// Parser HTML deterministico a basso livello: rimozione totale di espressioni regolari.
class DuckDuckGoHtmlParser {
  List<SearchResult> parse(String html) {
    debugPrint('[FORENSIC][HtmlParser] Analisi strutturale avviata. String size: ${html.length}');
    final List<SearchResult> results = [];
    int index = 0;
    
    while (true) {
      int matchIndex = html.indexOf('class="links_main', index);
      if (matchIndex == -1) {
        matchIndex = html.indexOf('class="result', index);
      }
      if (matchIndex == -1) {
        matchIndex = html.indexOf('class="web-result', index);
      }
      if (matchIndex == -1) break;
      
      int nextMatch = html.indexOf('class="result', matchIndex + 20);
      if (nextMatch == -1) nextMatch = html.indexOf('class="web-result', matchIndex + 20);
      if (nextMatch == -1) nextMatch = html.length;
      
      String block = html.substring(matchIndex, nextMatch);
      index = nextMatch;
      
      int hrefIndex = block.indexOf('href="');
      if (hrefIndex == -1) continue;
      int hrefEnd = block.indexOf('"', hrefIndex + 6);
      if (hrefEnd == -1) continue;
      String rawUrl = block.substring(hrefIndex + 6, hrefEnd);
      
      String url = _cleanUrl(rawUrl);
      if (url.contains('duckduckgo.com/y.js') || url.isEmpty) continue;
      
      int titleHint = block.indexOf('class="result__snippet"');
      int anchorStart = block.indexOf('<a ');
      String title = '';
      if (anchorStart != -1 && (titleHint == -1 || anchorStart < titleHint)) {
        int anchorTextStart = block.indexOf('>', anchorStart);
        int anchorTextEnd = block.indexOf('</a>', anchorTextStart);
        if (anchorTextStart != -1 && anchorTextEnd != -1) {
          title = _stripHtmlTags(block.substring(anchorTextStart + 1, anchorTextEnd));
        }
      }
      
      String snippet = '';
      int snippetStart = block.indexOf('class="result__snippet"');
      if (snippetStart != -1) {
        int tagClose = block.indexOf('>', snippetStart);
        int divClose = block.indexOf('</div>', tagClose);
        if (tagClose != -1 && divClose != -1) {
          snippet = _stripHtmlTags(block.substring(tagClose + 1, divClose));
        }
      }
      
      if (title.isNotEmpty) {
        results.add(SearchResult(
          title: title.trim(),
          url: url.trim(),
          snippet: snippet.trim(),
        ));
      }
    }
    
    debugPrint('[FORENSIC][HtmlParser] Parsing completato. Risultati validi estratti: ${results.length}');
    return results;
  }
  
  String _cleanUrl(String rawUrl) {
    int uddgPos = rawUrl.indexOf('uddg=');
    if (uddgPos != -1) {
      int endPos = rawUrl.indexOf('&', uddgPos);
      String encoded = endPos == -1 ? rawUrl.substring(uddgPos + 5) : rawUrl.substring(uddgPos + 5, endPos);
      try {
        return Uri.decodeComponent(encoded);
      } catch (_) {
        return rawUrl;
      }
    }
    return rawUrl;
  }
  
  String _stripHtmlTags(String html) {
    final buffer = StringBuffer();
    bool inTag = false;
    for (int i = 0; i < html.length; i++) {
      final char = html[i];
      if (char == '<') {
        inTag = true;
      } else if (char == '>') {
        inTag = false;
      } else if (!inTag) {
        buffer.write(char);
      }
    }
    return buffer.toString()
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
}

/// Implementazione del provider specifico per DuckDuckGo. Isolato dal tool principale.
class DuckDuckGoProvider implements SearchProvider {
  final http.Client client;
  final DuckDuckGoHtmlParser parser;

  DuckDuckGoProvider({required this.client, required this.parser});

  @override
  Future<List<SearchResult>> search(String query) async {
    debugPrint('[FORENSIC][DuckDuckGoProvider] Esecuzione richiesta di rete per: "$query"');
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final url = Uri.parse('https://html.duckduckgo.com/html/?q=$encodedQuery');
      
      final response = await client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      });

      if (response.statusCode != 200) {
        debugPrint('[FORENSIC][DuckDuckGoProvider] Status code di rete anomalo: ${response.statusCode}');
        return [];
      }

      return parser.parse(response.body);
    } catch (e) {
      debugPrint('[FORENSIC][DuckDuckGoProvider] Eccezione di rete intercettata: $e');
      return [];
    }
  }
}

/// Tool finale di orchestrazione. Dipende unicamente dalle astrazioni SearchProvider e SearchCache.
class WebSearchTool {
  final SearchProvider provider;
  final SearchCache cache;

  WebSearchTool({required this.provider, required this.cache});

  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final query = params['query']?.toString() ?? '';
    debugPrint('[FORENSIC][WebSearchTool] Richiesta esecuzione per query: "$query"');

    if (query.trim().isEmpty) {
      return ToolResult(success: false, output: '', errorMessage: 'Query vuota rilevata.');
    }

    // 1. Risoluzione della Cache con validazione TTL interna
    final cachedData = cache.get(query);
    if (cachedData != null) {
      return cachedData;
    }

    // 2. Acquisizione dei dati strutturati dal provider iniettato
    final rawResults = await provider.search(query);
    if (rawResults.isEmpty) {
      final emptyResult = ToolResult(success: true, output: 'Nessun risultato rilevante trovato su internet.');
      cache.set(query, emptyResult);
      return emptyResult;
    }

    // 3. Deduplica e calcolo del Ranking / Text Scoring
    final Map<String, SearchResult> uniqueResults = {};
    for (int i = 0; i < rawResults.length; i++) {
      final item = rawResults[i];
      if (uniqueResults.containsKey(item.url)) continue;

      double positionWeight = (rawResults.length - i).toDouble();
      double textWeight = _calculateTextRelevance(item, query);
      double totalScore = positionWeight + textWeight;

      uniqueResults[item.url] = item.copyWithScore(totalScore);
    }

    final rankedList = uniqueResults.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    // 4. Formattazione dell'output strutturato (il wrapping XML viene demandato all'Orchestrator)
    final buffer = StringBuffer();
    for (final res in rankedList) {
      buffer.writeln('Title: ${res.title}');
      buffer.writeln('URL: ${res.url}');
      buffer.writeln('Score: ${res.score.toStringAsFixed(1)}');
      buffer.writeln('Snippet: ${res.snippet}');
      buffer.writeln('---');
    }

    final finalResult = ToolResult(success: true, output: buffer.toString());
    cache.set(query, finalResult);

    return finalResult;
  }

  double _calculateTextRelevance(SearchResult res, String query) {
    double score = 0.0;
    final cleanQuery = query.toLowerCase();
    final cleanTitle = res.title.toLowerCase();
    final cleanSnippet = res.snippet.toLowerCase();

    final keywords = cleanQuery.split(' ')..removeWhere((word) => word.trim().length <= 2);
    for (final word in keywords) {
      if (cleanTitle.contains(word)) score += 5.0;
      if (cleanSnippet.contains(word)) score += 2.0;
    }
    return score;
  }
}
