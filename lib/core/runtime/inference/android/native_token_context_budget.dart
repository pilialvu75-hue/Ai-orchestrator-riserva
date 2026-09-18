import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

class NativeTokenContextBudgetResult {
  const NativeTokenContextBudgetResult({
    required this.contextTurns,
    required this.promptTokens,
    required this.trimmedTurns,
    required this.fitsRequestedBudget,
  });

  final List<ChatTurn> contextTurns;
  final int promptTokens;
  final int trimmedTurns;
  final bool fitsRequestedBudget;
}

/// Selects the largest recent conversational suffix that fits a model-token
/// prompt budget.
///
/// The caller owns prompt composition and token counting. Android production
/// supplies the loaded GGUF tokenizer through `llb_session_token_count`, while
/// unit tests can use deterministic fakes.
///
/// Candidate boundaries start only at user turns (or at an empty history), so
/// trimming never leaves an assistant response orphaned at the beginning of
/// the visible conversation. Binary search keeps exact tokenization calls
/// logarithmic even with a large history.
abstract final class NativeTokenContextBudget {
  static NativeTokenContextBudgetResult fit({
    required List<ChatTurn> contextTurns,
    required int maxPromptTokens,
    required String Function(List<ChatTurn> contextTurns) composePrompt,
    required int Function(String prompt) countTokens,
  }) {
    final normalized = contextTurns
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

    final starts = <int>[
      for (var index = 0; index < normalized.length; index++)
        if (normalized[index].role == ChatRole.user) index,
      normalized.length,
    ];

    // No usable user boundary means history cannot be safely injected.
    if (starts.length == 1) {
      final prompt = composePrompt(const <ChatTurn>[]);
      final tokens = countTokens(prompt);
      return NativeTokenContextBudgetResult(
        contextTurns: const <ChatTurn>[],
        promptTokens: tokens,
        trimmedTurns: contextTurns.length,
        fitsRequestedBudget: tokens <= maxPromptTokens,
      );
    }

    final tokenCounts = <int, int>{};

    int countAt(int boundaryPosition) {
      return tokenCounts.putIfAbsent(boundaryPosition, () {
        final start = starts[boundaryPosition];
        final candidate = start >= normalized.length
            ? const <ChatTurn>[]
            : normalized.sublist(start);
        return countTokens(composePrompt(candidate));
      });
    }

    // Keep the whole normalized history when it already fits.
    final firstTokens = countAt(0);
    if (firstTokens <= maxPromptTokens) {
      return NativeTokenContextBudgetResult(
        contextTurns: List<ChatTurn>.unmodifiable(
          normalized.sublist(starts[0]),
        ),
        promptTokens: firstTokens,
        trimmedTurns: contextTurns.length - normalized.length + starts[0],
        fitsRequestedBudget: true,
      );
    }

    // If even system + current user message do not fit the requested headroom,
    // return empty history. The native hard guard remains authoritative and can
    // clamp generation or fail explicitly when the prompt itself is too large.
    final emptyPosition = starts.length - 1;
    final emptyTokens = countAt(emptyPosition);
    if (emptyTokens > maxPromptTokens) {
      return NativeTokenContextBudgetResult(
        contextTurns: const <ChatTurn>[],
        promptTokens: emptyTokens,
        trimmedTurns: contextTurns.length,
        fitsRequestedBudget: false,
      );
    }

    // Find the earliest user boundary whose composed prompt fits. Removing
    // older turns is monotonic with respect to prompt token count.
    var low = 1;
    var high = emptyPosition;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (countAt(mid) <= maxPromptTokens) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }

    final selectedStart = starts[low];
    final selected = selectedStart >= normalized.length
        ? const <ChatTurn>[]
        : normalized.sublist(selectedStart);
    final selectedTokens = countAt(low);

    return NativeTokenContextBudgetResult(
      contextTurns: List<ChatTurn>.unmodifiable(selected),
      promptTokens: selectedTokens,
      trimmedTurns:
          contextTurns.length - normalized.length + selectedStart,
      fitsRequestedBudget: true,
    );
  }
}
