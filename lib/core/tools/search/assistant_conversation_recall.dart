import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

/// Exact recall of a user-declared name in this conversation, never a model
/// guess or a global profile. Other questions retain normal inference.
abstract final class AssistantConversationRecall {
  static String? answer(String prompt, List<ChatTurn> context) {
    final question = prompt.toLowerCase().replaceAll(RegExp(r'[?!.,]'), '').trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (!RegExp(r'^(?:come mi chiamo|qual(?:e)? [èée] il mio nome|ricordi il mio nome)$').hasMatch(question)) {
      return null;
    }
    final explicit = RegExp(
      r"^(?:ciao[\s,;.!]*)?(?:mi chiamo|il mio nome [èée])\s+([\p{L}][\p{L}'’\-]*)(?:[.,;!]|\s*$)",
      caseSensitive: false, unicode: true,
    );
    final introduction = RegExp(
      r"^(?:[Cc]iao[\s,;.!]*)?[Ii]o sono\s+([\p{Lu}][\p{L}'’\-]*)(?:[.,;!]|\s*$)", unicode: true,
    );
    for (final turn in context.reversed) {
      if (turn.role != ChatRole.user || turn.excludeFromContext) continue;
      final matches = [...explicit.allMatches(turn.content), ...introduction.allMatches(turn.content)]
        ..sort((a, b) => a.start.compareTo(b.start));
      if (matches.isNotEmpty) return 'Ti chiami ${matches.last.group(1)}.';
    }
    return null;
  }
}
