import 'dart:math' as math;

import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

class NativeTokenContextBudgetResult {
  const NativeTokenContextBudgetResult({
    required this.context,
    required this.promptTokens,
    required this.promptBudgetTokens,
    required this.availableGenerationTokens,
    required this.trimmedTurns,
  });

  final List<ChatTurn> context;
  final int promptTokens;
  final int promptBudgetTokens;
  final int availableGenerationTokens;
  final int trimmedTurns;

  bool get fitsRequestedGeneration => promptTokens <= promptBudgetTokens;
}

/// Selects the largest coherent recent conversation context that fits the
/// native model window while reserving the requested generation headroom.
///
/// The selector is tokenizer-agnostic: production passes llama.cpp's exact
/// RuntimeSession token counter, while unit tests can provide a deterministic
/// fake. No text is truncated. Capacity is recovered only by dropping complete
/// older turns, and a selected context never begins with an assistant turn.
abstract final class NativeTokenContextBudget {
  static NativeTokenContextBudgetResult select({
    required List<ChatTurn> context,
    required String Function(List<ChatTurn> context) renderPrompt,
    required int Function(String prompt) countTokens,
    required int nCtx,
    required int requestedGenerationTokens,
    required int safetyMargin,
  }) {
    if (nCtx <= 0) {
      throw ArgumentError.value(nCtx, 'nCtx', 'must be > 0');
    }
    if (requestedGenerationTokens < 0) {
      throw ArgumentError.value(
        requestedGenerationTokens,
        'requestedGenerationTokens',
        'must be >= 0',
      );
    }
    if (safetyMargin < 0) {
      throw ArgumentError.value(
        safetyMargin,
        'safetyMargin',
        'must be >= 0',
      );
    }

    final promptBudgetTokens = math.max(
      0,
      nCtx - requestedGenerationTokens - safetyMargin,
    );

    final starts = _coherentStartIndexes(context);

    NativeTokenContextBudgetResult evaluate(int start) {
      final selected = start >= context.length
          ? const <ChatTurn>[]
          : List<ChatTurn>.unmodifiable(context.sublist(start));
      final rendered = renderPrompt(selected);
      final promptTokens = countTokens(rendered);
      if (promptTokens < 0) {
        throw StateError('Tokenizer returned a negative prompt token count.');
      }
      return NativeTokenContextBudgetResult(
        context: selected,
        promptTokens: promptTokens,
        promptBudgetTokens: promptBudgetTokens,
        availableGenerationTokens: math.max(
          0,
          nCtx - promptTokens - safetyMargin,
        ),
        trimmedTurns: start,
      );
    }

    // The first candidate is the fullest coherent context. If it already fits,
    // avoid any further tokenizer calls.
    final first = evaluate(starts.first);
    if (first.fitsRequestedGeneration || starts.length == 1) {
      return first;
    }

    // Prompt size is monotonic when an older prefix is removed. Binary-search
    // the earliest coherent start that fits so we retain the maximum history.
    var low = 1;
    var high = starts.length - 1;
    NativeTokenContextBudgetResult? best;

    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      final candidate = evaluate(starts[middle]);

      if (candidate.fitsRequestedGeneration) {
        best = candidate;
        high = middle - 1;
      } else {
        low = middle + 1;
      }
    }

    // Even system + current user prompt may consume more than the preferred
    // prompt budget. Return the no-history candidate rather than truncating the
    // user's message; the native hard guard can then reduce generation capacity
    // or fail explicitly if the prompt itself exceeds nCtx.
    return best ?? evaluate(starts.last);
  }

  static List<int> _coherentStartIndexes(List<ChatTurn> context) {
    if (context.isEmpty) return const <int>[0];

    final starts = <int>[];
    for (var index = 0; index < context.length; index++) {
      if (context[index].role == ChatRole.user) {
        starts.add(index);
      }
    }

    // No user turn means all history would be orphaned assistant/system data.
    if (starts.isEmpty) {
      return <int>[context.length];
    }

    // Empty history is always the final fallback candidate.
    if (starts.last != context.length) {
      starts.add(context.length);
    }
    return starts;
  }
}
