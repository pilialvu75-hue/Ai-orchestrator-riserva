import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

/// Presents search evidence without inventing product attributes or prices.
/// Never treats an old assistant claim as a verified offer.
abstract final class AssistantShoppingResults {
  static bool isShoppingRequest(String input) =>
      AssistantWebSearchPolicy.shouldSearch(input) &&
      RegExp(r'\b(?:offert[ae]|offera|scont[oi]|promozion[ei]|deals?|offers?)\b',
          caseSensitive: false).hasMatch(input);

  static String? query(String input, List<ChatTurn> context) {
    if (_isGenericOfferFollowUp(input)) return _contextualOfferQuery(context);
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

  /// Generic "best offer" is ambiguous: it may describe a film title.
  static bool _isGenericOfferFollowUp(String input) {
    final value = input.toLowerCase().replaceAll('’', "'")
        .replaceAll(RegExp(r'[.!?]+$'), '').trim();
    return RegExp(
      r"^(?:trovami|trova|cercami|cerca|find|search|cherche|trouve)\s+"
      r"(?:(?:l'|un'|la |il |un |una |the |une )?)"
      r"(?:migliore |best |meilleure )?"
      r"(?:offerta|offerte|offer|offers|offre|offres)"
      r"(?:\s+(?:migliore|migliori|best|meilleure))?$",
      caseSensitive: false,
    ).hasMatch(value);
  }

  /// Only the user's earlier purchase request in this session is evidence.
  /// Assistant claims and unrelated/new topics must never become a Web query.
  static String? _contextualOfferQuery(List<ChatTurn> context) {
    String? clarification;
    var seenUsers = 0;
    for (final turn in context.reversed) {
      if (turn.role != ChatRole.user) continue;
      if (turn.excludeFromContext) return null;
      if (++seenUsers > 6) return null;
      final message = turn.content.trim();
      if (message.isEmpty || message.length > 350 ||
          message.contains('\n') || message.contains('\r')) return null;
      if (_isOriginalShoppingTopic(message)) {
        return clarification == null ? message : '$message $clarification';
      }
      if (RegExp(r'\b(?:frutta|frutto|fruit|fruits|verdura|légume)\b',
          caseSensitive: false).hasMatch(message) &&
          message.length <= 90) {
        clarification ??= message;
        continue;
      }
      if (RegExp(r'^(?:capito|ok|okay|s[iì]|si esatto|yes|oui|'
          r'cerca (?:su |in )?internet|cerca sul web|'
          r'cerca online|search the web)[.! ]*$',
          caseSensitive: false).hasMatch(message)) continue;
      return null;
    }
    return null;
  }

  static bool _isOriginalShoppingTopic(String input) {
    final value = input.toLowerCase();
    final commerce = RegExp(
      r'\b(?:comprare|acquistare|buy|acheter|compro|compra|'
      r'cercare|cerco|trova|trovami|find|cherche|prezzi|prix)\b',
    ).hasMatch(value);
    final offers = RegExp(
      r'\b(?:offert[ae]|scont[oi]|promozion[ei]|'
      r'deals?|offers?|promotion|promotions?|soldes?)\b',
    ).hasMatch(value);
    return commerce && offers && !_isGenericOfferFollowUp(input);
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
        pages.add('${title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim()}\n${uri.toString()}');
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
}
