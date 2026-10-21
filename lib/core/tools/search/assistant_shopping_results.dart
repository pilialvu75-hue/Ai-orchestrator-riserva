import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/core/tools/search/product_page_evidence.dart';

/// Presents search evidence without inventing product attributes or prices.
/// Never treats an old assistant claim as a verified offer.
abstract final class AssistantShoppingResults {
  static bool isShoppingRequest(String input) =>
      AssistantWebSearchPolicy.shouldSearch(input) &&
      RegExp(r'\b(?:offert[ae]|offera|scont[oi]|promozion[ei]|deals?|offers?)\b',
          caseSensitive: false).hasMatch(input);

  static String? query(String input, List<ChatTurn> context) {
    if (isShoppingRequest(input)) return input;
    if (!RegExp(r'^\s*(?:il\s+)?(?:link|collegamento|url)(?:\s+(?:al sito|del sito|all.offerta|al prodotto|dell.offerta))?\s*[?!.]*\s*$',
        caseSensitive: false).hasMatch(input)) return null;
    // A link follow-up refers only to the nearest user request; crossing an
    // unrelated topic would select a different offer without permission.
    for (final turn in context.reversed) {
      if (turn.role == ChatRole.user && !turn.excludeFromContext) {
        return isShoppingRequest(turn.content) ? turn.content : null;
      }
    }
    return null;
  }

  static String render(ToolResult result, {required bool followUp}) {
    final raw = result.metadata['results'];
    final pages = <String>[];
    if (result.success && raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final title = item['title'];
        final link = item['url'];
        if (title is! String || link is! String) continue;
        final uri = Uri.tryParse(link.trim());
        if (uri == null || !['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty || uri.userInfo.isNotEmpty) continue;
        final snippet = item['snippet'];
        final summary = snippet is String ? snippet.replaceAll(RegExp(r'\s+'), ' ').trim() : '';
        final excerpt = summary.length > 240 ? '${summary.substring(0, 240)}…' : summary;
        pages.add('${title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim()}\n'
            '${excerpt.isEmpty ? '' : 'Estratto della ricerca, da verificare: $excerpt\n'}${uri.toString()}');
        if (pages.length == 3) break;
      }
    }
    if (pages.isEmpty) {
      return 'Non ho trovato collegamenti verificabili per questa ricerca. '
          'Non posso confermare un prodotto, un prezzo o un’offerta.';
    }
    final prefix = followUp
        ? 'Non posso confermare l’offerta descritta nella risposta precedente. Ecco le pagine restituite dalla ricerca:'
        : 'Ecco le pagine restituite dalla ricerca. Verifica prezzo, configurazione e disponibilità aprendo i collegamenti:';
    return '$prefix\n\n${pages.join('\n\n')}';
  }

  static Future<String> answer(ToolResult result, {required bool followUp}) async {
    final raw = result.metadata['results'];
    if (result.success && raw is List) {
      final urls = raw.whereType<Map>().map((item) => item['url'])
          .whereType<String>().take(3).toList();
      final products = (await Future.wait(urls.map((url) => ProductPageEvidence.read(url))))
          .whereType<String>().toList();
      if (products.isNotEmpty) {
        return 'Dati letti dalle pagine prodotto; prezzi e disponibilità possono cambiare. '
            'Il confronto è limitato alle informazioni effettivamente pubblicate:\n\n${products.join('\n\n')}';
      }
    }
    return render(result, followUp: followUp);
  }
}
