import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

class NativeTokenContextSelection {
  const NativeTokenContextSelection({
    required this.context,
    required this.prompt,
    required this.promptTokens,
    required this.maxPromptTokens,
    required this.droppedTurns,
    required this.usedExactBudget,
  });

  final List<ChatTurn> context;
  final String prompt;
  final int promptTokens;
  final int maxPromptTokens;
  final int droppedTurns;
  final bool usedExactBudget;

  bool get wasTrimmed => droppedTurns > 0;
}

/// Selects the largest recent conversational suffix that fits an exact
/// model-token budget.
///
/// The selector never truncates individual messages. Candidate suffixes start
/// on user turns so an assistant response is never injected without the user
/// message it answers. The current user prompt and system prompt are owned by
/// the caller's [composePrompt] callback and therefore are never dropped here.
abstract final class NativeTokenContextBudget {
  static NativeTokenContextSelection select({
    required List<ChatTurn> context,
    required String Function(List<ChatTurn> context) composePrompt,
    required int Function(String prompt) countTokens,
    required int maxPromptTokens,
  }) {
    if (maxPromptTokens <= 0) {
      final prompt = composePrompt(const <ChatTurn>[]);
      return NativeTokenContextSelection(
        context: const <ChatTurn>[],
        prompt: prompt,
        promptTokens: countTokens(prompt),
        maxPromptTokens: maxPromptTokens,
        droppedTurns: context.length,
        usedExactBudget: true,
      );
    }

    final normalized = context
        .where(
          (turn) =>
              !turn.excludeFromContext &&
              turn.role != ChatRole.system &&
              turn.content.trim().isNotEmpty,
        )
        .map(
          (turn) => turn.copyWith(content: turn.content.trim()),
        )
        .toList(growable: false);

    final candidateStarts = <int>[];
    for (var index = 0; index < normalized.length; index++) {
      if (normalized[index].role == ChatRole.user) {
        candidateStarts.add(index);
      }
    }
    // Empty context is always the final fallback and preserves system/current
    // user prompt through the caller-owned composer.
    candidateStarts.add(normalized.length);

    final cache = <int, ({String prompt, int tokens})>{};

    ({String prompt, int tokens}) evaluate(int startIndex) {
      final cached = cache[startIndex];
      if (cached != null) return cached;

      final candidate = startIndex >= normalized.length
          ? const <ChatTurn>[]
          : normalized.sublist(startIndex);
      final prompt = composePrompt(candidate);
      final result = (prompt: prompt, tokens: countTokens(prompt));
      cache[startIndex] = result;
      return result;
    }

    // Binary-search the earliest fitting user boundary. Prompt size is
    // monotonic for suffixes because every removed turn removes non-empty
    // serialized content/template framing.
    var low = 0;
    var high = candidateStarts.length - 1;
    var bestPosition = candidateStarts.length - 1;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final startIndex = candidateStarts[mid];
      final result = evaluate(startIndex);

      if (result.tokens <= maxPromptTokens) {
        bestPosition = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    final bestStart = candidateStarts[bestPosition];
    final best = evaluate(bestStart);
    final selectedContext = bestStart >= normalized.length
        ? const <ChatTurn>[]
        : List<ChatTurn>.unmodifiable(normalized.sublist(bestStart));

    return NativeTokenContextSelection(
      context: selectedContext,
      prompt: best.prompt,
      promptTokens: best.tokens,
      maxPromptTokens: maxPromptTokens,
      droppedTurns: normalized.length - selectedContext.length,
      usedExactBudget: true,
    );
  }
}
